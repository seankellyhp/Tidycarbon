"""Provider-side inference impacts for tidycarbon, estimated with EcoLogits.

Called from R through reticulate (see R/provider.R). Adapted from the `/carbon`
Claude Code skill (scripts/provider_impacts.py and scripts/tokens.py).

CodeCarbon measures the electricity this machine drew; it cannot see what a
hosted model's inference cost, because that ran in the provider's datacenter.
EcoLogits models it (https://ecologits.ai/latest/methodology/llm_inference/):

    energy per request  ~  f(active parameters, output tokens, batch size)
    impacts             =  energy x grid intensity  +  embodied share of the
                           server for the duration of the generation

1. Only output tokens and latency enter the model. Input and cache tokens do
   not appear in its formulas at all.
2. Latency is an upper bound, not a driver: EcoLogits takes
   min(latency, modelled generation time), so an unknown latency is passed as
   infinity and a too-long one changes nothing.
3. Every figure is a range whenever the provider does not publish its model's
   architecture. A provider that does publish gets a scalar; both are returned
   here as a (min, max) pair, equal for a scalar.

Estimation is per request, never on token totals: the model is non-linear in
model, output length and latency, so one calculation over the totals is a
different (and wrong) number from the sum of per-request calculations.

Nothing here is a measurement of a provider's infrastructure, and nothing here
may be added to the CodeCarbon figures: different scopes, different methods.

All public functions take and return plain lists / dicts of columns so that
reticulate converts them without pandas.
"""

from __future__ import annotations

import json
import logging
import math
import re
from datetime import datetime, timezone

from ecologits.log import logger as _ecologits_logger
from ecologits.model_repository import models as _registry
from ecologits.tracers.utils import PROVIDER_CONFIG_MAP, llm_impacts
from ecologits.utils.range_value import RangeValue

# EcoLogits warns the first time it meets an unregistered model or an
# unreleased architecture. Both are normal here and both are reported in the
# `resolution` column, so keep them off the R console.
_ecologits_logger.setLevel(logging.ERROR)

try:
    from importlib.metadata import version as _version

    VERSION = _version("ecologits")
except Exception:  # pragma: no cover
    VERSION = "?"

PROVIDERS = {
    "anthropic": "anthropic",
    "claude": "anthropic",
    "openai": "openai",
    "azure": "openai",
    "mistral": "mistralai",
    "mistralai": "mistralai",
    "cohere": "cohere",
    "google": "google_genai",
    "google_genai": "google_genai",
    "gemini": "google_genai",
    "huggingface": "huggingface_hub",
    "huggingface_hub": "huggingface_hub",
}

IMPACTS = ("energy", "gwp", "adpe", "pe", "wcf")


# --------------------------------------------------------------------------- #
# model resolution
# --------------------------------------------------------------------------- #


def split_model(raw: str) -> tuple[str, str]:
    """(EcoLogits provider, bare model name) from whatever a client recorded.

    Harnesses and routers each qualify a model differently, and the qualifier is
    not always the provider that actually served it, so scan every segment and
    take the last one EcoLogits recognises:

        claude-opus-5                               Claude Code
        anthropic/claude-sonnet-4-5                 pi
        openrouter/anthropic/claude-sonnet-4-5      a router in front of it
        us.anthropic.claude-opus-4-1-20250805-v1:0  Bedrock

    A dotted name is only split when one of its segments is a known provider,
    so a model whose own name contains a dot (`gpt-3.5-turbo`) survives intact.
    """
    s = (raw or "").strip()
    prefix: list[str] = []
    if "/" in s:
        *head, s = s.split("/")
        prefix += head
    if "." in s:
        head, _, tail = s.rpartition(".")
        segments = head.split(".")
        if any(seg in PROVIDERS for seg in segments):
            prefix += segments
            s = tail
    s = re.sub(r"-v\d+(:\d+)?$", "", s)
    provider = next((PROVIDERS[seg] for seg in reversed(prefix) if seg in PROVIDERS), "")
    if not provider and s.startswith("claude"):
        provider = "anthropic"
    return provider, s


def normalize(hint: str, raw_model: str) -> tuple[str, str]:
    """split_model(), falling back to a client-supplied provider hint.

    The hint is what the R client calls its provider ("Anthropic",
    "Google/Gemini", "OpenAI"); the model string wins when it names one.
    """
    provider, bare = split_model(raw_model)
    if not provider and hint:
        for seg in re.split(r"[/\s:_-]+", hint.lower()):
            if seg in PROVIDERS:
                provider = PROVIDERS[seg]
                break
        else:
            if hint.lower() in PROVIDERS:
                provider = PROVIDERS[hint.lower()]
    return provider, bare


def version_key(name: str) -> tuple[str, tuple[int, ...]] | None:
    """('claude-opus', (4, 1)) for 'claude-opus-4-1-20250805'.

    The trailing 8-digit date stamp is not part of the version; anything
    non-numeric ends it.
    """
    parts = name.split("-")
    if len(parts) < 3:
        return None
    ver: list[int] = []
    for p in parts[2:]:
        if p.isdigit() and len(p) != 8:
            ver.append(int(p))
        else:
            break
    if not ver:
        return None
    return "-".join(parts[:2]), tuple(ver)


def _registered(provider: str) -> list[str]:
    return [m.name for m in _registry.list_models() if m.provider.value == provider]


def resolve(provider: str, name: str) -> tuple[str, str | None, str]:
    """(provider, registry model to compute with, how we got there).

    Clients run models newer than any EcoLogits release knows about, so an
    exact-match-only policy would report nothing for many real calls. Instead
    fall back to the nearest registered model of the same family - the closest
    published architecture. It is an assumption, so it is named in the
    `resolution` column of every row it affects.
    """
    if not provider:
        # A bare model name ("gpt-4o") still resolves, as long as exactly one
        # provider in the registry claims that name.
        owners = {m.provider.value for m in _registry.list_models() if m.name == name}
        if len(owners) != 1:
            return "", None, "no provider"
        provider = owners.pop()
        return provider, name, f"exact, provider inferred as {provider}"
    if _registry.find_model(provider=provider, model_name=name) is not None:
        return provider, name, "exact"

    key = version_key(name)
    if key is None:
        return provider, None, "unregistered"
    stem, want = key
    family = []
    for cand in _registered(provider):
        ck = version_key(cand)
        if ck and ck[0] == stem:
            family.append((ck[1], cand))
    if not family:
        return provider, None, "unregistered"
    family.sort()
    below = [c for c in family if c[0] <= want]
    _, cand = below[-1] if below else family[0]
    return provider, cand, f"proxy: nearest registered {stem.split('-')[-1]}"


# --------------------------------------------------------------------------- #
# estimation - one request at a time
# --------------------------------------------------------------------------- #


def _missing(x) -> bool:
    return x is None or (isinstance(x, float) and math.isnan(x))


def _bounds(impact) -> tuple[float, float]:
    if impact is None:
        return math.nan, math.nan
    v = impact.value
    if isinstance(v, RangeValue):
        return float(v.min), float(v.max)
    return float(v), float(v)


def estimate(providers: list, models: list, output_tokens: list, latencies: list, zone: str | None = None) -> dict:
    """One EcoLogits computation per request; returns a dict of columns.

    Impacts are in EcoLogits' units: energy kWh, gwp kgCO2eq, adpe kgSbeq,
    pe MJ, wcf L. A request that cannot be matched to a registered model, or
    has no output token count, comes back with modelled = False and NaN impacts.
    """
    zone = zone or None
    cols: dict[str, list] = {
        "provider": [],
        "resolved_model": [],
        "resolution": [],
        "modelled": [],
        "grid_zone": [],
    }
    for name in IMPACTS:
        cols[f"{name}_min"] = []
        cols[f"{name}_max"] = []

    for hint, raw, out, lat in zip(providers, models, output_tokens, latencies):
        provider, bare = normalize(hint or "", raw or "")
        provider, resolved, how = resolve(provider, bare)
        impacts = None
        if resolved and _missing(out):
            how = "no output token count"
        elif resolved:
            # None/NaN -> infinity, i.e. "do not cap the modelled generation
            # time". Latency can only ever shrink the estimate.
            impacts = llm_impacts(
                provider=provider,
                model_name=resolved,
                output_token_count=int(out),
                request_latency=math.inf if _missing(lat) else float(lat),
                electricity_mix_zone=zone,
            )
            if impacts is not None and impacts.has_errors:
                how = f"{how}; ecologits error"
                impacts = None
        ok = impacts is not None
        cfg = PROVIDER_CONFIG_MAP.get(provider)
        cols["provider"].append(provider)
        cols["resolved_model"].append(resolved or "")
        cols["resolution"].append(how)
        cols["modelled"].append(ok)
        cols["grid_zone"].append(zone or (cfg.datacenter_location if cfg else "") if ok else "")
        for name in IMPACTS:
            lo, hi = _bounds(getattr(impacts, name, None)) if ok else (math.nan, math.nan)
            cols[f"{name}_min"].append(lo)
            cols[f"{name}_max"].append(hi)
    return cols


# --------------------------------------------------------------------------- #
# Claude Code transcript reader
# --------------------------------------------------------------------------- #


def _parse_ts(value) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)
    except ValueError:
        return None


def read_claude_code(path: str, start: str | None = None, end: str | None = None) -> dict:
    """Billed requests from a Claude Code session transcript, as columns.

    A completed assistant message is written once per content block, each line
    carrying the same `message.id` and the same final `usage`, so only the
    first line of each id contributes usage. Latency is the span from the
    `parentUuid` record (the message or tool result that triggered the
    request) to the message's last line - an approximation, but EcoLogits only
    uses it as an upper bound. Subagent (isSidechain) rows are counted.

    `start` / `end` are ISO-8601 strings bounding the window; None is open.
    """
    lo = _parse_ts(start) if start else None
    hi = _parse_ts(end) if end else None
    ts_by_uuid: dict[str, datetime] = {}
    calls: dict[str, dict] = {}
    sent_by_mid: dict[str, datetime] = {}
    order: list[str] = []

    with open(path, errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            ts = _parse_ts(rec.get("timestamp"))
            uuid = rec.get("uuid")
            if uuid and ts is not None:
                ts_by_uuid[uuid] = ts
            msg = rec.get("message")
            if not isinstance(msg, dict):
                continue
            usage = msg.get("usage")
            if not isinstance(usage, dict) or ts is None:
                continue
            if (lo and ts < lo) or (hi and ts > hi):
                continue
            mid = msg.get("id") or rec.get("requestId") or ""

            prior = calls.get(mid)
            if prior is not None:
                sent = sent_by_mid.get(mid)
                if sent is not None:
                    prior["latency_s"] = max(prior["latency_s"] or 0.0, (ts - sent).total_seconds())
                continue

            call = {
                "ts": ts.isoformat(),
                "provider": "",
                "model": msg.get("model") or "unknown",
                "input_tokens": int(usage.get("input_tokens") or 0),
                "cache_read": int(usage.get("cache_read_input_tokens") or 0),
                "cache_write": int(usage.get("cache_creation_input_tokens") or 0),
                "output_tokens": int(usage.get("output_tokens") or 0),
                "latency_s": None,
                "sidechain": bool(rec.get("isSidechain")),
            }
            sent = ts_by_uuid.get(rec.get("parentUuid") or "")
            if sent is not None and ts > sent:
                call["latency_s"] = (ts - sent).total_seconds()
                sent_by_mid[mid] = sent
            calls[mid] = call
            order.append(mid)

    keys = ("ts", "provider", "model", "input_tokens", "cache_read", "cache_write", "output_tokens", "latency_s", "sidechain")
    cols = {k: [] for k in keys}
    for mid in order:
        for k in keys:
            v = calls[mid][k]
            cols[k].append(math.nan if (k == "latency_s" and v is None) else v)
    return cols
