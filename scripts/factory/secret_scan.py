"""Recognize secret-like strings, including simply encoded or split ones.

    found(text, known=None) -> bool
        known(sha) tells whether a full commit id is a real one and so no secret.

A screen, not a proof: an agent that wants to disguise a value can always find
an encoding this does not undo. Agents hold no secret to leak (ADR 0004); this
is a second line of defense. Not recognized, among others: values encrypted,
compressed, or combined with a key; base85 broken across lines; encodings nested
more than twice or after a line of prose; a value whose pieces are far apart;
passwords that look like words; and hexadecimal shorter than 32 digits.
A full commit id looks like a token, so the caller says which are real.
"""

import base64
import codecs
import math
import re
import unicodedata
from collections import Counter

import commit_id

# No word boundaries: a secret glued to other text is still a secret.
KNOWN = re.compile(
    r"gh[pousr]_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|glpat-[A-Za-z0-9_-]{16}"
    r"|sk-ant-[A-Za-z0-9_-]{8}|sk-(?:proj-)?[A-Za-z0-9]{32}"
    r"|(?:AKIA|ASIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30}|ya29\.[0-9A-Za-z_-]{20}"
    r"|xox[abeoprs]-[A-Za-z0-9-]{10}|hooks\.slack\.com/services/|npm_[A-Za-z0-9]{30}"
    r"|eyJ[A-Za-z0-9_-]{8,400}\.eyJ[A-Za-z0-9_-]{8}"
    r"|BEGIN[A-Z ]{0,20}PRIVATE KEY|AccountKey=[A-Za-z0-9+/]{20}"
)
# The same after the characters that join string pieces have been removed.
GLUED = re.compile(
    r"gh[pousr]_[A-Za-z0-9]{20}|github_pat_[A-Za-z0-9_]{20}|skant[a-z]{2,4}[0-9]{2}[A-Za-z0-9_]{12}"
    r"|(?:AKIA|ASIA)[0-9A-Z]{16}|glpat[A-Za-z0-9_]{16}|BEGIN[A-Z]{0,12}PRIVATEKEY"
)
GLUE = re.compile(r"[\s\"'`+<>\\,&|.;:()\[\]{}$#*-]+")
URL_PASSWORD = re.compile(
    r"[a-z][a-z0-9+.-]{1,20}://[^\s/:@\"']{0,64}:([^\s/@\"'<>{}$]{8,200})@", re.I
)
PLACEHOLDER = re.compile(
    r"(?:my|your|test|example|redis|user|pass(?:word)?|secret|[._*-])+[0-9]{0,3}", re.I
)
ASSIGNMENT = re.compile(
    r"(?:passw(?:or)?d|passphrase|secret|token|credential|(?:api|access|private)[_-]?key)"
    r"[\w-]{0,30}[\"']?\s{0,5}(?:=|:|<-|=>)\s{0,5}[\"']([^\"'\s]{16,200})[\"']",
    re.I,
)
AUTHORIZATION = re.compile(
    r"authorization[\"']?\s{0,5}[:=,]\s{0,5}[\"']?(?:bearer|basic)\s{1,5}[A-Za-z0-9+/=._-]{16}", re.I
)
RUN = re.compile(r"[A-Za-z0-9_+-]{20,}")
BASE64 = re.compile(r"[A-Za-z0-9+/_-]{16,}")
BASE32 = re.compile(r"[A-Z2-7]{24,}")
HEX = re.compile(r"[0-9A-Fa-f]{20,}")
# Digests and commit ids look like this too, but so do tokens.
LONG_HEX = re.compile(r"(?<![0-9A-Za-z])(?:0x)?([0-9a-f]{32,}|[0-9A-F]{32,})(?![0-9A-Za-z])")
COMMIT = re.compile(rf"(?<![0-9A-Za-z]){commit_id.PATTERN}(?![0-9A-Za-z])")
BASE85 = re.compile(r"[0-9A-Za-z!#$%&()*+;<=>?@^_`{|}~-]{25,}")
ASCII85 = re.compile(r"[!-u]{25,}")
NUMBERS = re.compile(r"(?:(?:0x[0-9A-Fa-f]{2}|[0-9]{1,3})[\s,;]{1,4}){9,}(?:0x[0-9A-Fa-f]{2}|[0-9]{1,3})")
NUMBER = re.compile(r"0x[0-9A-Fa-f]{2}|[0-9]{1,3}")
ESCAPE = re.compile(
    r"\\[xu]0{0,2}([0-9A-Fa-f]{2})|%([0-9A-Fa-f]{2})|&#x0{0,4}([0-9A-Fa-f]{2});"
    r"|\\([0-9]{2,3})(?:\\&)?|&#0{0,4}([0-9]{2,3});"
)


def found(text, known=None):
    if known:
        text = COMMIT.sub(lambda match: " " if known(match[0]) else match[0], text)
    return _found(text, 0)


def _found(text, depth):
    text = unicodedata.normalize("NFKC", text)
    if KNOWN.search(text) or AUTHORIZATION.search(text):
        return True
    if depth == 0:
        if any(not PLACEHOLDER.fullmatch(value) for value in URL_PASSWORD.findall(text)):
            return True
        if any(_varied(value) for value in ASSIGNMENT.findall(text)):
            return True
        if any(_random(value) for value in RUN.findall(text)):
            return True
        if any(len(set(value)) >= 6 for value in LONG_HEX.findall(text)):
            return True
        if any(KNOWN.search(decoded) for decoded in _base85(text)):
            return True
        glued = GLUE.sub("", text)
        for other in (glued, glued[::-1], text[::-1], codecs.encode(glued, "rot13")):
            if KNOWN.search(other) or GLUED.search(other):
                return True
        if any(_found(decoded, 1) for decoded in _decodings(glued)):
            return True
    return depth < 2 and any(_found(decoded, depth + 1) for decoded in _decodings(text))


def _varied(value):
    mixed = re.search(r"[0-9]", value) and re.search(r"[A-Za-z]", value)
    return bool(mixed) and _entropy(value) >= 3.3


def _random(value):
    """Mixed-case text with scattered digits, which identifiers rarely have."""
    switches = len(re.findall(r"(?=[A-Za-z][0-9]|[0-9][A-Za-z])", value))
    mixed = re.search("[a-z]", value) and re.search("[A-Z]", value)
    return bool(mixed) and switches >= 4 and _entropy(value) >= 3.8


def _entropy(value):
    counts = Counter(value).values()
    return -sum(count / len(value) * math.log2(count / len(value)) for count in counts)


def _decodings(text):
    """Readable decodings of parts of the text."""
    unescaped = ESCAPE.sub(_unescape, text)
    if unescaped != text:
        yield unescaped
    for match in NUMBERS.findall(text):
        values = [int(n, 16) if n.startswith("0x") else int(n) for n in NUMBER.findall(match)]
        yield "".join(map(chr, values))
    for match in HEX.findall(text):
        # The value may start at any offset inside a longer run.
        for part in (match, match[1:]):
            yield from _readable(bytes.fromhex(part[: len(part) // 2 * 2]))
    for match in BASE32.findall(text):
        for offset in range(8):
            part = match[offset:]
            yield from _readable(base64.b32decode(part + "=" * (-len(part) % 8))
                                 if len(part) % 8 in (0, 2, 4, 5, 7)
                                 else base64.b32decode(part[: len(part) // 8 * 8]))
    for match in BASE64.findall(text):
        plain = match.replace("-", "+").replace("_", "/")
        for offset in range(4):
            part = plain[offset:]
            if len(part) % 4 == 1:
                part = part[:-1]
            yield from _readable(base64.b64decode(part + "=" * (-len(part) % 4)))


def _base85(text):
    for pattern, decode in ((BASE85, base64.b85decode), (ASCII85, base64.a85decode)):
        for match in pattern.findall(text):
            for offset in range(5):
                part = match[offset:]
                # A trailing or misaligned group may overflow; the rest still counts.
                for end in range(len(part), max(len(part) - 5, 0), -1):
                    try:
                        data = decode(part[:end])
                    except ValueError:
                        continue
                    yield from _readable(data)
                    break


def _readable(data):
    # Decoding ordinary text gives noise, which holds no run this long.
    for run in re.findall(rb"[!-~]{12,}", data):
        yield run.decode("ascii")


def _unescape(match):
    hexadecimal = match[1] or match[2] or match[3]
    return chr(int(hexadecimal, 16) if hexadecimal else int(match[4] or match[5]))
