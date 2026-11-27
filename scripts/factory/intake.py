"""Choose the next ticket the factory may work (docs/factory.md, Intake).

Pure decisions: no network, no clock, and no agent. Anything missing, malformed,
or ambiguous makes a ticket ineligible. Interface:

    next_step(tickets, assessments=()) -> dict
        Always has action, routes, and skipped. action is one of:
          "none"    nothing to do.
          "assess"  run the sandboxed assessor on `source` (untrusted data), then
                    call again with {"ticket", "source_digest": digest,
                    "output": <raw agent text>} added to assessments.
          "work"    give the implementer `brief`, and nothing else from GitHub.
                    Pass work_digest to verify through a trusted job output.
        assess and work also have ticket, origin, priority, and digest. routes are
        the tickets whose ready-for-agent must become ready-for-human. skipped
        holds fixed reason codes. Neither ever contains ticket text.

        The assessor returns only this JSON. kind is one of SELF_APPROVED_KINDS,
        or another word when none fits. brief is required for an outside ticket
        and forbidden otherwise; anything invalid goes to ready-for-human:
          {"kind": "", "human_reviewed_classes": [...],
           "contradicted_adrs": ["0002"],
           "brief": {"title": "", "problem": "", "acceptance": [""]}}
        Brief fields are single lines of plain ASCII in the assessor's own words.
    verify(ticket, assessment, work_digest)
        Refused unless a fresh copy of the ticket, with the assessment it was
        worked under, still gives exactly the selected work: text, labels,
        priority, kind, and brief. Publishing calls this immediately before
        writing.
    factory_triage_label(kind, title, text), render_factory_ticket(kind, text)
        The triage state and body for a ticket the factory files.
    check_new_ticket_labels(kind, title, text, labels)
        Refused unless the publisher may create that ticket with those labels.
        FACTORY_LABEL and render_factory_ticket's body are both required, in the
        same request.
    check_label_change(ticket, add=(), remove=())
        Refused unless the publisher may make that change to a fresh ticket.
    render_factory_comment(text)
        Every comment the factory posts must come from this.

What a labeling event proves: that the maintainer's account, not another account
or a GitHub App or Actions token, applied the label. The factory's fine-grained
token acts as that same account (ADR 0004), so the event cannot tell the
maintainer from the factory. That gap is closed only by agents holding no token
and by the publisher calling the checks above before every label write. For the
same reason "maintainer" means only a ticket from that account with no factory
evidence: no mark in its body, no FACTORY_LABEL, and none in its label history.
Comments are not evidence, so a failed run's comment leaves a ticket retryable.
A ticket transferred or converted from a discussion is outside. A factory
ticket with none of these is indistinguishable from the maintainer's, so the
publisher must always set both the marker and the label, in the create request.
Every origin gets the same kind and class rules and assessment. Maintainer tickets
come first and skip the sensitive-text screen and the filters on factory text.
Comments never reach the implementer, since the account cannot prove who wrote
one. render_factory_comment's mark only keeps them out of the rewriter's input.

What remains possible:
- A brief is written by an agent that read outside text. Its structure, the copy
  check, and the word screens make passing instructions on harder, not
  impossible: a paraphrase gets through. The sandbox (no token, limited network) and
  the merge classifier (#187) are what limit the damage.
- The sensitive-text screen is a word list. #187 decides from the actual change.
- GitHub may record no comment_deleted event. A deletion between approval and
  selection then goes unnoticed; it can only remove text. After selection the
  digest catches it.
- GraphQL cannot list converted_from_discussion, so REST omitting it goes unnoticed.
  The text is then still frozen at approval like any other.
- An event that both REST and GraphQL omit goes unnoticed.
- Blockers named only in comments are not read. Use a native dependency or the body.
- A factory ticket whose publisher marked it in no way skips the screen and the
  filters, and is ordered first.
- A native blocker that the token cannot see is refused only when the summary
  counts or the event history reveal it.
"""

import hashlib
import json
import re
import sys
import unicodedata
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from github_issue_status import TRIAGE_STATE_LABELS

# Numeric ids survive a login rename; a freed login can be taken by someone else.
MAINTAINER_ID = 6529408
READY = "ready-for-agent"
HUMAN = "ready-for-human"
APPROVED_LABEL = "factory-approved"
FACTORY_LABEL = "factory-filed"
PRIORITIES = ("priority:p0", "priority:p1", "priority:p2", "priority:p3")

HUMAN_REVIEWED_CLASSES = frozenset(
    {
        "breaking-api",
        "authentication-tls-credentials",
        "new-dependencies",
        "factory-controls",
        "releases",
    }
)
SELF_APPROVED_KINDS = frozenset(
    {
        "bug-fix",
        "tests",
        "docs",
        "behavior-preserving-refactor",
        "backward-compatible-api",
        "small-feature",
    }
)
# factory-approved and factory-paused are never here, nor removable.
DESCRIPTIVE_LABELS = frozenset(
    {
        *PRIORITIES,
        "type:bug",
        "type:correctness",
        "type:performance",
        "type:docs",
        "type:testing",
        "type:maintenance",
        "type:security",
    }
)

MARKER = re.compile(r"<!-- factory-ticket:v1 kind=([a-z-]+) -->")
COMMENT_MARKER = "<!-- factory-comment:v1 -->"
BLOCKER_MENTION = re.compile(
    r"\bblocked[\W_]{0,3}by\b|\bblockers?\b|\b(needs?|requires?|after)\W{0,3}(?=#\d)"
)
# Ordinary prose unless the line also names an issue, or ends in a list.
POSSIBLE_BLOCKER_MENTION = re.compile(
    r"\b(blocked[\W_]{0,3}on|depend(s|ing|ent)?[\W_]{0,3}(on|upon)"
    r"|wait(s|ing)?[\W_]{0,3}(on|for)|prerequisites?)\b"
)
ISSUE_HINT = re.compile(r"#\d|/(issues|pull)/|\b(gh-|issue |pr |pull request )\d")
# Refused in a sentence that also names an issue.
ORDERING = re.compile(
    r"\b(after|before|once|until|unless|when|first|prior|pending|await\w*|merg\w+"
    r"|land(s|ed|ing)?|follow\w*)\b"
)
REFERENCE = re.compile(r"(?<![\w/])#(\d{1,9})\b")
REPRODUCTION =re.compile(r"^#+ *Reproduction *$(.*?)(?=^#|\Z)", re.I | re.M | re.S)

# For factory and outside tickets. The merge classifier, not this, is what stops a
# human-reviewed change from merging.
HUMAN_REVIEWED_TEXT = re.compile(
    r"\b(auth|authenticat\w*|authoriz\w*|\w*tls|ssl|certificates?|credentials?"
    r"|handshakes?|peer verif\w+|hostname verif\w+|passw\w*|secrets?"
    r"|(access|github|api) tokens?"
    r"|(?<!non[- ])breaking|backwards?[- ]incompatible"
    r"|dependenc(y|ies)|build[- ]depends|cabal|(lower|upper|version) bounds?"
    r"|workflows?|makefile|hooks?|githooks|claude\.?( )?md|agents?\.?( )?md|adrs?|factory"
    r"|releas\w+ (notes|process|workflow|proposal|version)"
    r"|(cut|make|publish|new) (a |new )*release|hackage|version bump)\b"
    r"|\.github/|\bscripts/|docs/(adr|agents)|\.claude\b"
)
# ASCII only, so no homoglyphs; no markup, shell, URL, mention, or path characters.
BRIEF_CHARACTERS = re.compile(r"[A-Za-z0-9 .,;:'\"()_+=*%!?-]+")
# A dotted name must look like a Haskell module, as in System.IO.hFlush, or a number.
DOTTED_NAME = re.compile(r"[\w-]+(?:\.[\w-]+)+")
MODULE_NAME = re.compile(r"[A-Z]\w*(\.[A-Z]\w*)*\.\w+|\d+(\.\d+)+")
UNSAFE_BRIEF_TEXT = re.compile(
    r"factory[- ]?(approved|filed|paused)|\b(curl|wget|nc|netcat|bash|sh)\b"
    r"|\bhttps?\b|\bwww\b"
    r"|\b(ignore|disregard|forget|override|bypass|do not follow|don't follow)\b.{0,40}"
    r"\b(instructions?|rules?|prompts?|polic(y|ies)|guid\w+|above|previous|earlier)\b"
    r"|\byou are (now|an?)\b|\b(system|developer) (prompt|message)\b"
    r"|\benvironment variables?\b",
)
# The only use of "/" in factory text: a path to repository content.
REPOSITORY_PATH = re.compile(
    r"\b(?:app|bench|docs|hask-redis-mux|test)(?:/[A-Za-z0-9_-]+)+"
    r"(?:\.(?:hs|md|json))?(?::\d+(?:-\d+)?)?(?![\w/.]\w|/)"
)
CONFUSABLES = {
    ord(source): target
    for source, target in zip(
        "\u0430\u0432\u0441\u0501\u0435\u04bb\u043d\u0456\u0458\u043a\u04cf\u043c"
        "\u043e\u0440\u051b\u0433\u0455\u0442\u0443\u051d\u0445"
        "\u03b1\u03b2\u03b5\u03b7\u03b9\u03ba\u03bd\u03bf\u03c1\u03c4\u03c5\u03c7"
        "\u03b3\u03bc\u03c9\u0131\u0142\u00f8\u0111\u0251\u0261",
        "abcdehhijklmopqrstywx" "abenikvoptuxyuw" "ilodag",
        strict=True,
    )
}


class Refused(Exception):
    """The input is not permitted. The message never contains ticket text."""


class _Skip(Exception):
    pass


class _Route(Exception):
    pass


def _time(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")


def _labels(ticket):
    return {label.casefold() for label in ticket["labels"]}


def _fold(text):
    """Text with case, invisible characters, and lookalike letters undone."""
    text = "".join(
        character
        for character in unicodedata.normalize("NFKD", text)
        if unicodedata.category(character) not in ("Mn", "Me", "Cf")
    )
    return text.casefold().translate(CONFUSABLES)


def _human_reviewed(*texts):
    # Split wordLike_this so that useTLS and auth_token read as separate words.
    text = "\n".join(texts)
    split = re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ", text)
    for folded in (_fold(text), _fold(split)):
        for variant in (folded, re.sub(r"[\W_]+", " ", folded)):
            if HUMAN_REVIEWED_TEXT.search(variant):
                return True
    # A word still mixing scripts is an attempt at a lookalike.
    return any(
        re.search("[a-z]", word) and not word.isascii()
        for word in re.findall(r"[^\W\d_]+", _fold(text))
    )


def _keyword_screen_applies(origin):
    """Whether the sensitive-text screen applies to a ticket of this origin.

    The maintainer chose to exempt their own tickets. Any factory evidence makes
    the origin "factory", so only a wholly unmarked ticket is exempt.
    """
    return origin != "maintainer"


def _unsafe(text):
    folded = _fold(text)
    # Second form: undo separators other than spaces, and line breaks.
    return any(
        UNSAFE_BRIEF_TEXT.search(form)
        for form in (folded, re.sub(r"[\W_]+", " ", folded))
    )


def _unsafe_factory_text(title, text):
    """The brief's filters, for text that may carry outside content via an audit."""
    if "\n" in title or len(title) > 120 or len(text) > 8000 or _unsafe(text):
        return True
    try:
        for line in (title, *text.splitlines()):
            line = re.sub(r"^\s*(#{1,6}\s|[-*+]\s(\[[ x]\]\s)?|\d+[.)]\s)", "", line)
            line = REPOSITORY_PATH.sub("path", line)
            if line.strip():
                _brief_text(line, 1000)
    except ValueError:
        return True
    return False


def _proven_label_event(ticket, name):
    """The event that set a current label, or None if its history is unclear."""
    times = [_time(entry["created_at"]) for entry in ticket["events"]]
    if times != sorted(times):
        return None
    history = [
        entry
        for entry in ticket["events"]
        if entry["event"] in ("labeled", "unlabeled")
        and entry["label"].casefold() == name
    ]
    if any(
        entry["event"] != ("labeled", "unlabeled")[index % 2]
        for index, entry in enumerate(history)
    ):
        return None
    if not history or history[-1]["event"] != "labeled":
        return None
    if not _is_maintainer(history[-1]["actor_id"]) or history[-1]["via_app"] is not False:
        return None
    return history[-1]


def _is_maintainer(account_id):
    # A float or bool can compare equal to an integer.
    return type(account_id) is int and account_id == MAINTAINER_ID


def _only_maintainer_edited(item):
    if bool(item["last_edited_at"]) != bool(item["edits"]):
        return False
    return all(_is_maintainer(entry["editor_id"]) for entry in item["edits"])


def _origin(ticket):
    author = ticket["author_id"]
    # None is a deleted account.
    if author is not None and type(author) is not int:
        raise ValueError("author")
    if (
        not _is_maintainer(author)
        or not _only_maintainer_edited(ticket)
        or any(
            entry["event"] in ("transferred", "converted_from_discussion")
            or (entry["event"] == "renamed" and not _is_maintainer(entry["actor_id"]))
            for entry in ticket["events"]
        )
    ):
        return "outside"
    if (
        FACTORY_LABEL in _labels(ticket)
        or re.search("factory-(ticket|comment):", _fold(ticket["body"]))
        or any(
            entry["event"] in ("labeled", "unlabeled")
            and entry["label"].casefold() == FACTORY_LABEL
            for entry in ticket["events"]
        )
    ):
        return "factory"
    return "maintainer"


def _change_times(item):
    times = [entry["edited_at"] for entry in item["edits"]]
    if item["last_edited_at"]:
        times.append(item["last_edited_at"])
    return [_time(time) for time in times]


def _frozen(ticket):
    """The approval event, and the comments that existed when it happened."""
    if APPROVED_LABEL not in _labels(ticket):
        raise _Skip("not-approved")
    approval = _proven_label_event(ticket, APPROVED_LABEL)
    if approval is None or any(
        entry["event"] in ("transferred", "converted_from_discussion")
        for entry in ticket["events"]
    ):
        raise _Skip("approval-unproven")
    moment = _time(approval["created_at"])
    comments = [c for c in ticket["comments"] if _time(c["created_at"]) <= moment]
    changes = [time for item in (ticket, *comments) for time in _change_times(item)]
    changes += [_time(c["created_at"]) for c in comments]
    changes += [
        _time(entry["created_at"])
        for entry in ticket["events"]
        if entry["event"] in ("renamed", "comment_deleted")
    ]
    # GitHub times are whole seconds, so a change in the same second is ambiguous.
    if any(change >= moment for change in changes):
        raise _Skip("approval-revoked")
    return approval, comments


def _shown(character):
    if character in "\n\t":
        return True
    if "︀" <= character <= "️" or "\U000e0100" <= character <= "\U000e01ef":
        return False
    return unicodedata.category(character) not in ("Cc", "Cf", "Cs", "Co", "Cn")


def _visible(text):
    """Remove text that GitHub does not show the approving maintainer."""
    text = "".join(filter(_shown, text))
    while "<!--" in text:
        text = re.sub(r"<!--.*?(-->|\Z)", "", text, flags=re.S)
    return text


def _reference_only(line):
    """The issues a line names, or None if it says anything else."""
    line = re.sub(r"^[\s>|]*(\d+[.)]\s|[-*+]\s)?\s*(\[[ x]\])?", "", line)
    rest = re.sub(r"\b(and|none|nothing)\b", "", REFERENCE.sub("", line))
    if re.search(r"\w", rest.replace("_", "")):
        return None
    return [int(number) for number in REFERENCE.findall(line)]


def _named_blockers(text):
    """(issues named as blockers, whether every mention was understood)."""
    numbers, understood = [], True
    lines = _fold(text).splitlines()
    for index, line in enumerate(lines):
        remainder = BLOCKER_MENTION.sub("", line)
        if remainder == line:
            remainder = POSSIBLE_BLOCKER_MENTION.sub("", line)
            labelled = re.search(POSSIBLE_BLOCKER_MENTION.pattern + r"[\s*_]*:", line)
            bare = not re.search(r"[^\W_]", remainder)
            if remainder == line or not (labelled or bare or ISSUE_HINT.search(line)):
                continue
        named = _reference_only(remainder)
        if named is None:
            understood = False
            named = [int(number) for number in REFERENCE.findall(remainder)]
        else:
            # Any list continues below. A bare heading must have one.
            found = bool(named) or bool(re.search(r"[^\W_]", remainder))
            heading = not found
            previous_blank = heading
            for below in lines[index + 1 :]:
                if not below.strip():
                    previous_blank = True
                    continue
                more = _reference_only(below)
                if more is None or below.lstrip().startswith("##"):
                    listed = re.match(r"\s*([-*+]|\d+[.)])\s", below)
                    contiguous = not previous_blank and ISSUE_HINT.search(below)
                    if not found or contiguous or (
                        listed and (heading or not previous_blank)
                    ):
                        understood = False
                    break
                found, previous_blank = True, False
                named += more
            understood = understood and found
        numbers += named
    return numbers, understood and not _orders_around_an_issue(lines)


def _orders_around_an_issue(lines):
    prose = "\n".join(line for line in lines if not BLOCKER_MENTION.search(line))
    sentences = re.split(r"[.!?]\s|\n\s*\n|\n\s*(?:[-*+]|\d+[.)])\s|\n#+\s", prose)
    return any(ISSUE_HINT.search(s) and ORDERING.search(s) for s in sentences)


def blocker_numbers(text):
    """Issues in this repository that a ticket's text names as blockers."""
    return sorted(set(_named_blockers(text)[0]))


def _blocked(ticket):
    if ticket["open_blockers"] != 0:
        return True
    numbers, understood = _named_blockers(f"{ticket['title']}\n{ticket['body']}")
    states = ticket["blocker_states"]
    return not understood or any(states.get(n) != "closed" for n in numbers)


def _kind_permitted(kind, text):
    if kind not in SELF_APPROVED_KINDS:
        return False
    section = REPRODUCTION.search(text)
    return kind != "bug-fix" or bool(section and section.group(1).strip())


def _factory_kind(body):
    """The kind and text of a factory ticket; kind is None if the mark is not intact."""
    first, _, text = body.partition("\n")
    marker = MARKER.fullmatch(first.rstrip("\r"))
    if not marker or "factory-ticket:" in _fold(text):
        return None, text
    return marker.group(1), text


def factory_triage_label(kind, title, text):
    if (
        not _kind_permitted(kind, text)
        or _human_reviewed(title, text)
        or _unsafe_factory_text(title, text)
    ):
        return HUMAN
    return READY


def render_factory_ticket(kind, text):
    if not isinstance(kind, str) or not re.fullmatch(r"[a-z-]+", kind):
        raise Refused("invalid factory ticket kind")
    if "<!--" in text or "factory-ticket:" in _fold(text):
        raise Refused("factory ticket text contains a marker")
    return f"<!-- factory-ticket:v1 kind={kind} -->\n{text}"


def render_factory_comment(text):
    if "<!--" in text:
        raise Refused("factory comment text contains a marker")
    return f"{COMMENT_MARKER}\n{text}"


def _is_factory_comment(comment):
    marked = "factory-comment:" in _fold(comment["body"])
    return marked and _is_maintainer(comment["author_id"])


def check_new_ticket_labels(kind, title, text, labels):
    labels = list(labels)
    states = [label for label in labels if label in (READY, HUMAN)]
    others = set(labels) - {READY, HUMAN, FACTORY_LABEL}
    if FACTORY_LABEL not in labels or len(states) != 1 or others - DESCRIPTIVE_LABELS:
        raise Refused("publishing jobs may not create a ticket with these labels")
    render_factory_ticket(kind, text)
    if states == [READY] and (
        "type:security" in labels or factory_triage_label(kind, title, text) != READY
    ):
        raise Refused("this ticket may not be self-approved")


def check_label_change(ticket, add=(), remove=()):
    """Moving any ticket to ready-for-human is permitted; more needs FACTORY_LABEL."""
    if isinstance(add, str) or isinstance(remove, str):
        raise Refused("labels must be a list")
    add, remove = set(add), set(remove)
    if not (add <= {READY, HUMAN} | DESCRIPTIVE_LABELS and remove <= {READY, "needs-triage"}):
        raise Refused("publishing jobs may not change this label")
    try:
        labels = _labels(ticket)
        kind, text = _factory_kind(ticket["body"])
        factory = FACTORY_LABEL in labels and _origin(ticket) == "factory"
        human_owned = HUMAN in labels or any(
            entry["event"] == "labeled" and entry["label"].casefold() == HUMAN
            for entry in ticket["events"]
        )
        permitted = factory_triage_label(kind, ticket["title"], text) == READY
    except (KeyError, TypeError, ValueError, AttributeError):
        raise Refused("the ticket is incomplete") from None
    if not factory and not (add <= {HUMAN} and remove <= {READY}):
        raise Refused("only a ticket the factory filed may change this way")
    if remove and not add & {READY, HUMAN}:
        raise Refused("a triage state may only be replaced")
    if READY in add and (
        not permitted or human_owned or "type:security" in labels | add
    ):
        raise Refused("this ticket may not be self-approved")
    after = (labels - remove) | add
    if add & {READY, HUMAN} and len(after & TRIAGE_STATE_LABELS) != 1:
        raise Refused("the ticket would not have exactly one triage state")


class _Candidate:
    """An eligible ticket, reduced to what later steps need."""

    def __init__(self, ticket):
        self.number = ticket["number"]
        if ticket["is_pull_request"] is not False:
            raise _Skip("pull-request")
        if ticket["state"] != "open":
            raise _Skip("closed")
        self.origin = _origin(ticket)
        approval = None
        if self.origin == "outside":
            approval, comments = _frozen(ticket)
            comments = [c for c in comments if not _is_factory_comment(c)]
        else:
            list(ticket["comments"])
            comments = []
        labels = _labels(ticket)
        if labels & TRIAGE_STATE_LABELS != {READY}:
            raise _Skip("not-ready-for-agent")
        if _proven_label_event(ticket, READY) is None:
            raise _Skip("ready-label-unproven")
        if _blocked(ticket):
            raise _Skip("blocked")

        clean = _visible if self.origin == "outside" else str
        raw = [ticket["title"], ticket["body"], *(c["body"] for c in comments)]
        shown = [clean(text) for text in raw]
        self.source = {"title": shown[0], "body": shown[1]}
        if self.origin == "outside":
            self.source["comments"] = shown[2:]
        # Hidden text is never shown to the rewriter, but is still not copyable.
        self.raw = [*raw, *shown]
        self.body = ticket["body"]
        self.digest = hashlib.sha256(
            json.dumps(
                [
                    self.number,
                    self.origin,
                    approval and approval["id"],
                    ticket["title"],
                    ticket["body"],
                    sorted(labels),
                    [[c["id"], c["author_id"], c["body"]] for c in comments],
                ]
            ).encode("ascii")
        ).hexdigest()
        # Conflicting priorities take the less urgent one.
        priority = max(
            (rank for rank, label in enumerate(PRIORITIES) if label in labels),
            default=len(PRIORITIES),
        )
        self.priority = priority
        self.order = (
            self.origin != "maintainer",
            priority,
            _time(ticket["created_at"]),
            self.number,
        )
        self.factory_kind = None
        self.route = self._route(ticket, labels, raw)

    def _route(self, ticket, labels, raw):
        if self.origin == "factory":
            self.factory_kind, text = _factory_kind(ticket["body"])
            if not _kind_permitted(self.factory_kind, text):
                return "kind-not-permitted"
            raw = [ticket["title"], text]
        if "type:security" in labels or (
            _keyword_screen_applies(self.origin) and _human_reviewed(*raw)
        ):
            return "human-reviewed-class"
        if self.origin == "factory" and _unsafe_factory_text(*raw):
            return "unsafe-text"
        return None


def _candidate(ticket):
    try:
        return _Candidate(ticket)
    except (KeyError, TypeError, ValueError, AttributeError):
        raise _Skip("incomplete-data") from None


def _unique_keys(pairs):
    result = dict(pairs)
    if len(result) != len(pairs):
        raise ValueError("duplicate key")
    return result


def _words(text):
    return re.findall(r"[^\W_]+", _fold(text))


def _copies(brief, source_texts):
    """Whether five words in a row, or their letters, also occur in the source."""
    fields = [brief["title"], brief["problem"], *brief["acceptance"]]
    words = _words(" ".join(fields))
    letters = "".join(words)
    for text in source_texts:
        source = _words(text)
        runs = {tuple(source[i : i + 5]) for i in range(len(source) - 4)}
        if any(tuple(words[i : i + 5]) in runs for i in range(len(words) - 4)):
            return True
        # Catches the same copy with its word breaks moved.
        joined = "".join(source)
        if any(letters[i : i + 28] in joined for i in range(len(letters) - 27)):
            return True
    # Each short field may also not simply be a phrase of the source.
    return any(
        len(_words(field)) >= 3
        and any(f" {' '.join(_words(field))} " in f" {' '.join(_words(t))} " for t in source_texts)
        for field in fields
    )


def _brief_text(value, limit):
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ValueError("brief text")
    if not BRIEF_CHARACTERS.fullmatch(value):
        raise ValueError("brief text")
    if not all(MODULE_NAME.fullmatch(name) for name in DOTTED_NAME.findall(value)):
        raise ValueError("brief text")
    if _unsafe(value):
        raise ValueError("brief text")
    return value


def _parse_brief(brief):
    if not isinstance(brief, dict) or set(brief) != {"title", "problem", "acceptance"}:
        raise ValueError("brief fields")
    acceptance = brief["acceptance"]
    if not isinstance(acceptance, list) or not 1 <= len(acceptance) <= 6:
        raise ValueError("acceptance")
    return {
        "title": _brief_text(brief["title"], 80),
        "problem": _brief_text(brief["problem"], 400),
        "acceptance": [_brief_text(line, 200) for line in acceptance],
    }


def _parse_assessment(candidate, outputs):
    (output,) = outputs
    if not isinstance(output, str) or len(output) > 20000:
        raise ValueError("output")
    data = json.loads(output, object_pairs_hook=_unique_keys)
    fields = {"kind", "human_reviewed_classes", "contradicted_adrs"}
    if candidate.origin == "outside":
        fields.add("brief")
    if not isinstance(data, dict) or set(data) != fields:
        raise ValueError("fields")
    if not isinstance(data["kind"], str):
        raise ValueError("kind")
    classes, adrs = data["human_reviewed_classes"], data["contradicted_adrs"]
    if not isinstance(classes, list) or not isinstance(adrs, list):
        raise ValueError("lists")
    if not all(name in HUMAN_REVIEWED_CLASSES for name in classes):
        raise ValueError("class")
    if not all(isinstance(adr, str) and re.fullmatch("[0-9]{4}", adr) for adr in adrs):
        raise ValueError("adr")
    brief = candidate.source
    if candidate.origin == "outside":
        brief = _parse_brief(data["brief"])
        if _copies(brief, candidate.raw):
            raise ValueError("copied text")
    return data["kind"], classes, adrs, brief


def _approved_work(candidate, outputs):
    """(kind, what the implementer may see)"""
    try:
        kind, classes, adrs, brief = _parse_assessment(candidate, outputs)
    except (ValueError, TypeError, RecursionError):
        raise _Route("invalid-assessment") from None
    if classes:
        raise _Route("human-reviewed-class")
    if adrs:
        raise _Route("contradicts-adr")
    if candidate.factory_kind not in (None, kind) or not _kind_permitted(
        kind, candidate.body
    ):
        raise _Route("kind-not-permitted")
    if candidate.origin == "outside" and _human_reviewed(
        brief["title"], brief["problem"], *brief["acceptance"]
    ):
        raise _Route("human-reviewed-class")
    return kind, brief


def next_step(tickets, assessments=()):
    candidates, routes, skipped = [], [], []
    for ticket in tickets:
        try:
            candidates.append(_candidate(ticket))
        except _Skip as reason:
            skipped.append({"ticket": ticket.get("number"), "reason": str(reason)})
    step = {"action": "none", "routes": routes, "skipped": skipped}
    for candidate in sorted(candidates, key=lambda c: c.order):
        chosen = {
            **step,
            "ticket": candidate.number,
            "origin": candidate.origin,
            "priority": candidate.priority,
            "digest": candidate.digest,
        }
        outputs = [
            entry["output"]
            for entry in assessments
            if entry["ticket"] == candidate.number
            and entry["source_digest"] == candidate.digest
        ]
        try:
            if candidate.route:
                raise _Route(candidate.route)
            if not outputs:
                return {**chosen, "action": "assess", "source": candidate.source}
            kind, brief = _approved_work(candidate, outputs)
            bound = [candidate.digest, candidate.priority, kind, brief, outputs[0]]
            work_digest = hashlib.sha256(
                json.dumps(bound, sort_keys=True).encode("ascii")
            ).hexdigest()
            return {
                **chosen,
                "action": "work",
                "kind": kind,
                "brief": brief,
                "work_digest": work_digest,
            }
        except _Route as reason:
            routes.append(
                {"ticket": candidate.number, "to": HUMAN, "reason": str(reason)}
            )
    return step


def verify(ticket, assessment, work_digest):
    try:
        step = next_step([ticket], [assessment])
    except (KeyError, TypeError, AttributeError):
        raise Refused("the assessment is incomplete") from None
    if step["action"] != "work" or step["work_digest"] != work_digest:
        reasons = [entry["reason"] for entry in step["skipped"] + step["routes"]]
        raise Refused(f"work is no longer valid: {', '.join(reasons) or 'changed'}")
