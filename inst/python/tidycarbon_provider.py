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
   architecture or its datacenter's PUE / WUE. EcoLogits returns a scalar
   otherwise; both are returned here as a (min, max) pair, equal for a scalar.
4. Which models exist is EcoLogits' call. The model name goes to its registry
   as recorded; one it has not registered is reported as its
   `model-not-registered` error, never approximated by another model.

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
from datetime import datetime, timezone

from ecologits.log import logger as _ecologits_logger
from ecologits.tracers.utils import PROVIDER_CONFIG_MAP, llm_impacts
from ecologits.utils.range_value import RangeValue

# EcoLogits warns the first time it meets an unregistered model or an
# unreleased architecture. Both are normal here and both are reported per
# request, in the `error` and `warnings` columns, so keep them off the R console.
_ecologits_logger.setLevel(logging.ERROR)

try:
    from importlib.metadata import version as _version

    VERSION = _version("ecologits")
except Exception:  # pragma: no cover
    VERSION = "?"

# What a client calls its provider -> the EcoLogits provider id. EcoLogits
# normally knows the provider from the SDK it instruments; here the R client
# only has a display name ("Google/Gemini"), so this lookup is the one piece of
# translation the wrapper has to own.
PROVIDERS = {
    "anthropic": "anthropic",
    "claude": "anthropic",
    "openai": "openai",
    "azure": "openai",
    "azure/openai": "openai",
    "mistral": "mistralai",
    "mistralai": "mistralai",
    "cohere": "cohere",
    "google": "google_genai",
    "google/gemini": "google_genai",
    "google_genai": "google_genai",
    "gemini": "google_genai",
    "huggingface": "huggingface_hub",
    "hugging face": "huggingface_hub",
    "huggingface_hub": "huggingface_hub",
}

IMPACTS = ("energy", "gwp", "adpe", "pe", "wcf")


def provider_id(name: str) -> str:
    """EcoLogits provider id for a client's provider name, or ""."""
    return PROVIDERS.get((name or "").strip().lower(), "")


def split_model(provider: str, model: str) -> tuple[str, str]:
    """(EcoLogits provider, model name) to look up, with no guessing.

    The model name is passed to EcoLogits exactly as the client recorded it:
    whether it is registered is EcoLogits' decision, not ours. The one
    exception is OpenRouter, which is not a provider itself and writes the
    provider into the model id - `openai/gpt-4o`. Other routers are left
    alone: how they spell a model id is not something to guess at.
    """
    if (provider or "").strip().lower() == "openrouter":
        head, sep, tail = model.partition("/")
        if sep and provider_id(head):
            return provider_id(head), tail
        return "", model
    return provider_id(provider), model


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
    pe MJ, wcf L. A request EcoLogits returns an error for (a model or zone it
    has not registered) comes back with modelled = False, NaN impacts and the
    EcoLogits error code in `error`. `warnings` holds its warning codes.
    """
    zone = zone or None
    cols: dict[str, list] = {
        "provider": [],
        "modelled": [],
        "error": [],
        "warnings": [],
        "grid_zone": [],
    }
    for name in IMPACTS:
        cols[f"{name}_min"] = []
        cols[f"{name}_max"] = []

    for hint, raw, out, lat in zip(providers, models, output_tokens, latencies):
        provider, model = split_model(hint or "", raw or "")
        impacts = None
        if _missing(out):
            # Not an EcoLogits code: it has no notion of a missing count.
            error = "missing-output-tokens"
        else:
            # None/NaN -> infinity, i.e. "do not cap the modelled generation
            # time". Latency can only ever shrink the estimate.
            impacts = llm_impacts(
                provider=provider,
                model_name=model,
                output_token_count=int(out),
                request_latency=math.inf if _missing(lat) else float(lat),
                electricity_mix_zone=zone,
            )
            error = ",".join(e.code for e in impacts.errors) if impacts.has_errors else ""
        ok = impacts is not None and not error
        cfg = PROVIDER_CONFIG_MAP.get(provider)
        cols["provider"].append(provider or hint or "")
        cols["modelled"].append(ok)
        cols["error"].append(error)
        cols["warnings"].append(",".join(w.code for w in impacts.warnings) if ok and impacts.has_warnings else "")
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
    message or tool result that triggered the request to the message's last
    line - an approximation, but EcoLogits only uses it as an upper bound. That
    trigger is the nearest ancestor on the `parentUuid` chain that is itself a
    message: Claude Code threads bookkeeping records (attachments) into the
    chain, some written as the response arrives. Subagent (isSidechain) rows
    are counted.

    `start` / `end` are ISO-8601 strings bounding the window; None is open.
    """
    lo = _parse_ts(start) if start else None
    hi = _parse_ts(end) if end else None
    ts_by_uuid: dict[str, datetime] = {}
    parent_by_uuid: dict[str, str] = {}
    is_message: set[str] = set()
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
            if uuid:
                parent_by_uuid[uuid] = rec.get("parentUuid") or ""
                if isinstance(msg, dict):
                    is_message.add(uuid)
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
                "provider": "anthropic",
                "model": msg.get("model") or "unknown",
                "input_tokens": int(usage.get("input_tokens") or 0),
                "cache_read": int(usage.get("cache_read_input_tokens") or 0),
                "cache_write": int(usage.get("cache_creation_input_tokens") or 0),
                "output_tokens": int(usage.get("output_tokens") or 0),
                "latency_s": None,
                "sidechain": bool(rec.get("isSidechain")),
            }
            trigger = rec.get("parentUuid") or ""
            while trigger and trigger not in is_message:
                trigger = parent_by_uuid.get(trigger, "")
            sent = ts_by_uuid.get(trigger)
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
