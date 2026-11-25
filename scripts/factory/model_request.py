"""Allowlist for what the agent may send to the model API.

The agent can reach the model proxy with any HTTP client, so requests are
checked, not trusted. Server-side tools, MCP servers, remote sources and file
references would let Anthropic's servers fetch or run things for the agent,
outside the sandbox. Anything not listed here is refused.

The lists match the requests Claude Code 2.1.325 was observed to send with
CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1. Recheck them when that pin moves.
"""

import json
import math
import re

TOOLS = frozenset({"Bash", "Read", "Edit", "Write"})
BETAS = frozenset({
    "claude-code-20250219",
    "oauth-2025-04-20",
    "interleaved-thinking-2025-05-14",
    "effort-2025-11-24",
})  # fmt: skip
API_VERSION = "2023-06-01"
FORWARDED_HEADERS = re.compile(
    r"accept|user-agent|anthropic-version|anthropic-beta|x-app"
    r"|anthropic-dangerous-direct-browser-access|x-claude-code-session-id"
    r"|x-stainless-(?:arch|lang|os|package-version|retry-count|runtime|runtime-version|timeout)",
    re.IGNORECASE,
)
HEADER_VALUE = re.compile(r"[\x20-\x7e]{0,512}")


class Refused(Exception):
    pass


def need(condition, reason):
    if not condition:
        raise Refused(reason)


def one_of(*values):
    return lambda value: isinstance(value, str) and value in values


def record(required=None, **optional):
    """A JSON object with exactly these fields; each has a check."""
    required = required or {}
    fields = {**required, **optional}

    def check(value):
        return (
            isinstance(value, dict)
            and value.keys() <= fields.keys()
            and required.keys() <= value.keys()
            and all(fields[name](item) for name, item in value.items())
        )

    return check


def either(*checks):
    return lambda value: any(check(value) for check in checks)


def list_of(check):
    return lambda value: isinstance(value, list) and all(map(check, value))


def text(value):
    return isinstance(value, str)


def whole(value):
    return type(value) is int and value >= 0


def number(value):
    return type(value) in (int, float)


def boolean(value):
    return isinstance(value, bool)


def data(value):
    """Free-form JSON that only the client or the model interprets."""
    return isinstance(value, dict)


CACHE = record({"type": one_of("ephemeral")}, ttl=one_of("5m", "1h"))
TEXT = record({"type": one_of("text"), "text": text}, cache_control=CACHE)
INLINE = record({"type": one_of("base64", "text"), "media_type": text, "data": text})
MEDIA = record({"type": one_of("image", "document"), "source": INLINE}, cache_control=CACHE)
BLOCK = either(
    TEXT,
    MEDIA,
    record(
        {"type": one_of("tool_use"), "id": text, "name": one_of(*TOOLS), "input": data},
        cache_control=CACHE,
        caller=record({"type": one_of("direct")}),
    ),
    record(
        {"type": one_of("tool_result"), "tool_use_id": text},
        content=either(text, list_of(either(TEXT, MEDIA))),
        is_error=boolean,
        cache_control=CACHE,
    ),
    record(
        {"type": one_of("thinking"), "thinking": text, "signature": text}, cache_control=CACHE
    ),
    record({"type": one_of("redacted_thinking"), "data": text}, cache_control=CACHE),
)
MESSAGE = record(
    {"role": one_of("user", "assistant", "system"), "content": either(text, list_of(BLOCK))}
)
# A tool without `type`, or with "custom", is run by the client.
TOOL = record(
    {"name": one_of(*TOOLS), "input_schema": data},
    type=one_of("custom"),
    description=text,
    cache_control=CACHE,
)
FIELDS = {
    "model": text,
    "messages": lambda value: bool(value) and list_of(MESSAGE)(value),
    "max_tokens": whole,
    "system": either(text, list_of(TEXT)),
    "tools": list_of(TOOL),
    "tool_choice": record(
        {"type": one_of("auto", "any", "none", "tool")},
        name=one_of(*TOOLS),
        disable_parallel_tool_use=boolean,
    ),
    "metadata": record(user_id=text),
    "thinking": record(
        {"type": one_of("adaptive", "enabled", "disabled")},
        budget_tokens=whole,
        display=text,
    ),
    "output_config": record(effort=text),
    "stop_sequences": list_of(text),
    "temperature": number,
    "stream": boolean,
}


def unique(pairs):
    fields = dict(pairs)
    need(len(fields) == len(pairs), "repeated field")
    return fields


def not_json(_):
    raise Refused("not JSON")


def finite(literal):
    value = float(literal)
    need(math.isfinite(value), "number out of range")
    return value


def check_body(raw, model, counting):
    """Return the request to forward, or raise Refused.

    The result is serialized again, so upstream cannot read it differently.
    """
    try:
        body = json.loads(
            raw.decode(), object_pairs_hook=unique, parse_constant=not_json, parse_float=finite
        )
        need(isinstance(body, dict), "not an object")
        for name in {"model", "messages"} | (set() if counting else {"max_tokens"}):
            need(name in body, f"{name} is missing")
        for name, value in body.items():
            need(name in FIELDS, "unknown field")
            need(FIELDS[name](value), f"{name} is not allowed")
        need(body["model"] == model, "model is not allowed")
        return json.dumps(body, allow_nan=False).encode()
    except (ValueError, RecursionError):
        raise Refused("not JSON") from None


def check_headers(headers):
    """Return the headers to forward, or raise Refused."""
    need(not headers.defects, "malformed headers")
    names = [name.lower() for name in headers.keys()]
    need(len(set(names)) == len(names), "repeated header")
    for name, value in headers.items():
        # Folded or split lines show up as line breaks here.
        need(re.fullmatch(r"[A-Za-z0-9-]+", name), "malformed header")
        need(not re.search(r"[\r\n\0]", value), "malformed header")
    need(headers.get("content-encoding", "identity") == "identity", "encoded body")
    need(headers.get("anthropic-version", API_VERSION) == API_VERSION, "unknown API version")
    betas = {beta.strip() for beta in headers.get("anthropic-beta", "").split(",")} - {""}
    need(betas <= BETAS, "unapproved beta")
    forwarded = {}
    for name, value in headers.items():
        if FORWARDED_HEADERS.fullmatch(name):
            need(HEADER_VALUE.fullmatch(value), "malformed header")
            forwarded[name] = value
    return forwarded
