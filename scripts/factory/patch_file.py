"""Parse and apply one git patch as data. Nothing here runs a program.

    parse(data) -> [Change]              or Rejected
    check_paths(changes, tree)           or Rejected; tree is {path: (mode, sha)}
    apply(change, base) -> bytes | None  or Rejected; None means deleted
    changed_lines(changes) -> int        added plus removed, without GENERATED

The grammar is the part of `git diff` the factory needs; anything else is
rejected. Results are checked against the blob ids in the patch, so a patch for
another version of a file, or one cut short inside a file, is rejected. Only
printable ASCII paths are accepted, so no Unicode spelling can stand for another
path. Messages are fixed codes that never contain patch text.
"""

import hashlib
import re
import unicodedata
from dataclasses import dataclass, field

MAX_BYTES = 8 * 1024 * 1024
# Only files whose content CI regenerates and compares belong here.
GENERATED = frozenset(
    {"hask-redis-mux/lib/cluster/Database/Redis/Cluster/Internal/CommandMetadata.hs"}
)
REGULAR = ("100644", "100755")

_PATH = re.compile(r"[A-Za-z0-9._+@-]+(/[A-Za-z0-9._+@-]+)*")
_INDEX = re.compile(r"index ([0-9a-f]{7,40})\.\.([0-9a-f]{7,40})(?: ([0-9]{6}))?")
_HUNK = re.compile(
    r"@@ -([0-9]{1,7})(?:,([0-9]{1,7}))? \+([0-9]{1,7})(?:,([0-9]{1,7}))? @@(?: .*)?", re.S
)
_SIMILARITY = re.compile(r"[0-9]{1,3}%")


class Rejected(Exception):
    """The patch is not publishable. The message is a fixed code."""


@dataclass
class Hunk:
    old_start: int
    old_count: int
    new_start: int
    new_count: int
    # (marker, text with its newline); markers are " ", "-", "+".
    lines: list = field(default_factory=list)


@dataclass
class Change:
    old: str | None  # None when the file is created
    new: str | None  # None when the file is deleted
    old_blob: str | None = None  # None only for a rename without edits
    new_blob: str | None = None
    hunks: list = field(default_factory=list)

    def added(self):
        return [text for hunk in self.hunks for mark, text in hunk.lines if mark == "+"]


def blob_id(content):
    return hashlib.sha1(b"blob %d\0" % len(content) + content).hexdigest()


def hidden(text):
    """Whether text holds characters a reviewer would not see."""
    for character in text:
        if character in "\n\t":
            continue
        if unicodedata.category(character) in ("Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp"):
            return True
        if "\ufe00" <= character <= "\ufe0f" or "\U000e0100" <= character <= "\U000e01ef":
            return True
        # Letters that render as nothing.
        if character in "\u034f\u115f\u1160\u17b4\u17b5\u3164\uffa0":
            return True
    return False


def parse(data):
    if not data:
        raise Rejected("patch-empty")
    if len(data) > MAX_BYTES:
        raise Rejected("patch-too-large-to-read")
    if b"\0" in data:
        raise Rejected("patch-binary")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise Rejected("patch-not-utf8") from None
    if not text.endswith("\n"):
        raise Rejected("patch-truncated")
    return _Parser(text.split("\n")[:-1]).files()


class _Parser:
    def __init__(self, lines):
        self.lines = lines
        self.position = 0

    def peek(self):
        return self.lines[self.position] if self.position < len(self.lines) else None

    def take(self):
        line = self.peek()
        if line is None:
            raise Rejected("patch-truncated")
        self.position += 1
        return line

    def take_prefix(self, prefix):
        line = self.peek()
        if line is None or not line.startswith(prefix):
            return None
        self.position += 1
        return line[len(prefix) :]

    def files(self):
        changes = []
        while self.peek() is not None:
            changes.append(self.file())
        touched = [path for c in changes for path in {c.old, c.new} if path is not None]
        if len({path.casefold() for path in touched}) != len(touched):
            raise Rejected("patch-path-repeated")
        return changes

    def file(self):
        header = self.take_prefix("diff --git ")
        if header is None:
            raise Rejected("patch-malformed")
        old, new = _header_paths(header)
        change = Change(old, new)
        renamed = False
        similarity = None
        if (self.peek() or "").startswith(("old mode ", "new mode ")):
            raise Rejected("patch-mode-change")
        if (created := self.take_prefix("new file mode ")) is not None:
            if created != "100644":
                raise Rejected("patch-file-mode")
            change.old = None
        elif (deleted := self.take_prefix("deleted file mode ")) is not None:
            if deleted not in REGULAR:
                raise Rejected("patch-file-mode")
            change.new = None
        elif (similarity := self.take_prefix("similarity index ")) is not None:
            if not _SIMILARITY.fullmatch(similarity):
                raise Rejected("patch-malformed")
            renamed = True
            if (
                self.take_prefix("rename from ") != old
                or self.take_prefix("rename to ") != new
                or old == new
            ):
                raise Rejected("patch-malformed")
        if not renamed and old != new:
            raise Rejected("patch-malformed")

        if (self.peek() or "").startswith("index "):
            match = _INDEX.fullmatch(self.take())
            if not match:
                raise Rejected("patch-malformed")
            change.old_blob, change.new_blob, mode = match.groups()
            if mode is not None and mode not in REGULAR:
                raise Rejected("patch-file-mode")
        elif similarity != "100%":
            raise Rejected("patch-malformed")

        line = self.peek() or ""
        if line == "GIT binary patch" or line.startswith("Binary files "):
            raise Rejected("patch-binary")
        if line.startswith("--- "):
            if change.old_blob is None:
                raise Rejected("patch-malformed")
            if self.take_prefix("--- ") != (f"a/{old}" if change.old else "/dev/null"):
                raise Rejected("patch-malformed")
            if self.take_prefix("+++ ") != (f"b/{new}" if change.new else "/dev/null"):
                raise Rejected("patch-malformed")
            while (self.peek() or "").startswith("@@"):
                change.hunks.append(self.hunk())
            if not change.hunks:
                raise Rejected("patch-truncated")
        elif change.old is not None and change.new is not None and not renamed:
            raise Rejected("patch-malformed")
        return change

    def hunk(self):
        match = _HUNK.fullmatch(self.take())
        if not match:
            raise Rejected("patch-malformed")
        hunk = Hunk(*(1 if group is None else int(group) for group in match.groups()))
        old, new = hunk.old_count, hunk.new_count
        if not old and not new:
            raise Rejected("patch-malformed")
        while old or new:
            line = self.take()
            mark = line[:1]
            if mark not in ("-", "+", " "):
                raise Rejected("patch-malformed")
            old -= mark != "+"
            new -= mark != "-"
            if old < 0 or new < 0:
                raise Rejected("patch-malformed")
            text = line[1:] + "\n"
            if mark == "+" and hidden(text):
                raise Rejected("patch-hidden-characters")
            if (self.peek() or "").startswith("\\"):
                if self.take() != "\\ No newline at end of file":
                    raise Rejected("patch-malformed")
                text = text[:-1]
            hunk.lines.append((mark, text))
        return hunk


def _header_paths(header):
    # Quoted paths never match, so there is nothing to unescape.
    names = header.split(" ")
    if len(names) != 2 or not names[0].startswith("a/") or not names[1].startswith("b/"):
        raise Rejected("patch-path")
    for name in names:
        check_path(name[2:])
    return names[0][2:], names[1][2:]


def check_path(path):
    if len(path) > 400 or not _PATH.fullmatch(path):
        raise Rejected("patch-path")
    parts = path.casefold().split("/")
    for part in parts:
        if part.endswith(".") or len(part) > 200 or part in (".git", ".gitmodules"):
            raise Rejected("patch-path")
    for parent, child in zip(parts, parts[1:]):
        if parent == ".github" and child in ("workflows", "actions"):
            raise Rejected("patch-workflow")
    if parts[-1] in ("action.yml", "action.yaml"):
        raise Rejected("patch-workflow")


def check_paths(changes, tree):
    """Reject changes that do not fit the base tree, or only differ by case."""
    result = dict(tree)
    added = set()
    for change in changes:
        if change.old is not None:
            if change.old not in tree:
                raise Rejected("patch-stale")
            if tree[change.old][0] not in REGULAR:
                raise Rejected("patch-file-mode")
            if change.old != change.new:
                del result[change.old]
    for change in changes:
        if change.new is not None and change.new != change.old:
            if change.new in tree:
                raise Rejected("patch-stale")
            result[change.new] = None
            added.add(change.new)
    names = {}
    for path in result:
        parts = path.split("/")
        for depth in range(1, len(parts) + 1):
            name = "/".join(parts[:depth])
            names.setdefault(name.casefold(), set()).add((name, depth == len(parts)))
    for path in added:
        parts = path.casefold().split("/")
        for depth in range(1, len(parts) + 1):
            if len(names["/".join(parts[:depth])]) != 1:
                raise Rejected("patch-path-collision")


def apply(change, base):
    """The new content. `base` is the current content, or None when created."""
    if change.old_blob is not None:
        _match(change.old_blob, base)
    if base is not None and b"\0" in base:
        raise Rejected("patch-binary")
    # Split on newlines only; other line separators are content.
    old = [] if base is None else re.findall(rb"[^\n]*\n|[^\n]+\Z", base)
    result, position = [], 0
    for hunk in change.hunks:
        start = hunk.old_start - 1 if hunk.old_count else hunk.old_start
        if start < position or start > len(old):
            raise Rejected("patch-stale")
        result += old[position:start]
        position = start
        if len(result) != (hunk.new_start - 1 if hunk.new_count else hunk.new_start):
            raise Rejected("patch-malformed")
        for mark, text in hunk.lines:
            line = text.encode("utf-8")
            if mark != "+":
                if position >= len(old) or old[position] != line:
                    raise Rejected("patch-stale")
                position += 1
            if mark != "-":
                result.append(line)
    result += old[position:]
    if any(not line.endswith(b"\n") for line in result[:-1]):
        raise Rejected("patch-malformed")
    content = b"".join(result)
    if change.new is None:
        if content:
            raise Rejected("patch-malformed")
        _match(change.new_blob, None)
        return None
    if change.new_blob is not None:
        _match(change.new_blob, content)
    if change.old == change.new and content == base:
        raise Rejected("patch-empty")
    return content


def _match(abbreviated, content):
    full = "0" * 40 if content is None else blob_id(content)
    if not full.startswith(abbreviated):
        raise Rejected("patch-stale")


def changed_lines(changes):
    total = 0
    for change in changes:
        # A rename into or out of a generated path is not exempt.
        if {change.old, change.new} - {None} <= GENERATED:
            continue
        total += sum(mark != " " for hunk in change.hunks for mark, _ in hunk.lines)
    return total
