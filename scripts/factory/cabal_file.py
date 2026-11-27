"""Minimal strict reader for the .cabal files in this repository."""

import re
from collections import namedtuple


class CabalError(Exception):
    pass


Library = namedtuple("Library", "name source_dirs exposed reexported other")

STANZA = re.compile(
    r"^(common|library|executable|test-suite|benchmark|flag|source-repository|foreign-library|"
    r"custom-setup)(?:\s+(\S+))?$",
    re.IGNORECASE,
)
# Fields that decide which modules exist and where their source is.
LAYOUT_FIELDS = (
    "exposed-modules", "reexported-modules", "other-modules", "hs-source-dirs", "import", "signatures",
    "virtual-modules",
)
FIELD = re.compile(r"^([A-Za-z][A-Za-z0-9-]*)\s*:(.*)$")
CONDITION = re.compile(r"^(if|elif|else)\b.*$", re.IGNORECASE)


def parse(text):
    """Return {stanza: {(conditions..., field): value}}; "" is the package itself."""
    stanzas = {"": {}}
    stanza, conditions, field, field_indent = "", [], None, 0
    if any(not char.isprintable() and char != "\n" for char in text):
        raise CabalError("control characters are not supported")
    for number, raw in enumerate(text.split("\n"), 1):
        if not raw.strip() or raw.lstrip().startswith("--"):
            continue
        if "\t" in raw or raw.strip()[0] in "{}":
            raise CabalError(f"line {number}: unsupported layout")
        line, indent = raw.strip(), len(raw) - len(raw.lstrip())
        if field is not None and indent > field_indent:
            stanzas[stanza][field] += " " + line
            continue
        field = None
        while conditions and indent <= conditions[-1][0]:
            conditions.pop()
        match = STANZA.match(line)
        if indent == 0 and match:
            stanza = " ".join(part for part in (match[1].lower(), match[2]) if part)
            if stanza in stanzas:
                raise CabalError(f"line {number}: duplicate stanza {stanza}")
            stanzas[stanza], conditions = {}, []
            continue
        if CONDITION.match(line) and not FIELD.match(line):
            if "{" in line:
                raise CabalError(f"line {number}: unsupported layout")
            conditions.append((indent, " ".join(line.split())))
            continue
        match = FIELD.match(line)
        if not match or (indent == 0 and stanza):
            raise CabalError(f"line {number}: cannot parse {line!r}")
        field = (*(text for _, text in conditions), match[1].lower())
        if field in stanzas[stanza]:
            raise CabalError(f"line {number}: duplicate field {match[1]}")
        stanzas[stanza][field] = match[2].strip()
        field_indent = indent
    return stanzas


def words(value):
    return [word for word in re.split(r"[\s,]+", value) if word]


def dependencies(value):
    """Return {package: constraint} for a build-depends style value."""
    result = {}
    if "{" in value or "}" in value:
        raise CabalError("unsupported dependency syntax")
    for part in value.split(","):
        part = " ".join(part.split())
        if not part:
            continue
        match = re.match(r"^([A-Za-z0-9-]+(?::[A-Za-z0-9-]+)?)\s*(.*)$", part)
        if not match:
            raise CabalError(f"cannot parse dependency {part!r}")
        result[match[1]] = (result.get(match[1], "") + " " + match[2]).strip()
    return result


def libraries(stanzas):
    result = []
    for stanza in stanzas:
        if stanza.split()[0:1] != ["library"]:
            continue
        values, imported = {}, [stanza]
        for name in imported:
            if name not in stanzas:
                raise CabalError(f"missing {name}")
            for key, value in stanzas[name].items():
                if len(key) > 1 and key[-1] in LAYOUT_FIELDS:
                    raise CabalError(f"{name}: conditional {key[-1]}")
                values.setdefault(key[-1], []).extend(words(value))
                if key[-1] == "import":
                    imported.extend(f"common {item}" for item in words(value))
                    if len(imported) > 50:
                        raise CabalError("too many common stanzas")
        if values.get("signatures") or values.get("virtual-modules"):
            raise CabalError("unsupported library fields")
        reexported = values.get("reexported-modules", [])
        if "as" in reexported or any(":" in name for name in reexported):
            raise CabalError("renamed or qualified reexported-modules are not supported")
        result.append(
            Library(
                stanza,
                tuple(values.get("hs-source-dirs") or ["."]),
                tuple(values.get("exposed-modules", [])),
                tuple(reexported),
                tuple(values.get("other-modules", [])),
            )
        )
    return result
