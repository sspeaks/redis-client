#!/usr/bin/env python3
"""Decide the merge class of a change from its paths and an API diff.

    classify.py --base <base branch commit> --head <head commit>

Prints JSON. Run it from a checkout of the base branch with the head commit
fetched but not checked out: the head is only ever read as git objects and is
never executed. A copy that differs from the base commit's refuses to grant
anything below the maintainer class. See docs/factory.md.

Known limits, left to review and E2E: authentication, TLS and credential
behavior in library code outside lib/client and Connector.hs is found by names
in the changed declarations, so a helper they call, or a disguised string, is
not; an app module that only passes data to a sensitive one (and neither imports
nor is imported by it) is ordinary internal code; and data derived through
dependencies, whose own behavior is not read here.

An edit to an existing test file is low risk only when every line of code stays
exactly as it was and the rest is complete new tests: `describe`/`context`
groups and `it`/`specify`/`prop` tests, each a statement after an existing test in
the same `do` block, whose bodies are only `let` bindings and pure hspec
assertions or a property. Everything else is extra evidence, including imports,
helpers, stricter assertions in an existing test, and tests that run IO. What
still passes: a new test that proves little or nothing, or that is slow; comment
and whitespace-only-line edits; and new test files, which are searched only for
names that skip, focus or exit, and which nothing runs until an existing runner
or a package description is changed (both at least extra evidence). Pure code in
a new test can also hang or exhaust memory, which fails CI rather than hiding a
failure. A new suite runs as its own process but shares files and services with
the others in CI, so it can disturb them. A new library module may have open
imports from other packages and still be a compatible addition, although these
can bring instances along. Reviewers must look for those.

Operands and properties use only allowlisted operators and names: constructors,
lambda and `let` variables, pure Prelude and QuickCheck functions, values from
known-pure modules, and functions of the same file whose signature involves no
monad. A known-pure function may still hide IO behind unsafePerformIO in code
that was already reviewed. A new test may be vacuous: it may assert only about
its own literals or lambda variables. A name that a file declares in any way
other than a plain signature, such as the types, constructors and fields of a
data declaration, is refused even when harmless. Most additions to the existing suites run IO or use
fixtures, so nearly all of them take extra evidence.
"""

import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

sys.dont_write_bytecode = True

import cabal_file  # noqa: E402
import haskell_api  # noqa: E402
from haskell_source import SourceError, chunks, depth_zero, render, tokenize  # noqa: E402

LOW, EXTRA, MAINTAINER = "low-risk", "extra-evidence", "maintainer"
ORDER = (LOW, EXTRA, MAINTAINER)

SELF = ("scripts/factory/classify.py", "scripts/factory/cabal_file.py",
        "scripts/factory/haskell_api.py", "scripts/factory/haskell_source.py")

SENSITIVE = re.compile(r"auth(?!ors?\b|oritative)|tls|credential|passw|secret|x509|certificate", re.IGNORECASE)
# Documents that may be read as instructions, or look like one that is.
INSTRUCTIONS = re.compile(
    r"(^|[/._-])(agents?|claude|gemini|copilot|codex|aider|(cursor|windsurf|cline)(_?rules)?(?=/)|"
    r"(cursor|windsurf|cline)_?rules|skills?|instructions?|prompts?|factory)([/._-]|$)"
)
PLAIN_PATH = re.compile(r"[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*")

# Code that runs, or rewrites code, while compiling.
BUILD_TIME = re.compile(
    r"\bCPP\b|TemplateHaskell|QuasiQuotes|\{-#\s*(ann|rules|include|plugin)\b", re.IGNORECASE
)
OPTIONS = re.compile(r"\{-#\s*options", re.IGNORECASE)
SAFE_OPTIONS = re.compile(r"\{-#\s*OPTIONS_GHC(\s+-(W[a-z-]*|fno-warn-[a-z-]+|O[012]?),?)+\s*#-\}")

# An app module is sensitive when it can reach one of these through imports,
# when a credential module uses it, or when it or an import has outside access. Name matching alone misses helpers.
CREDENTIAL_MODULES = {"CredentialConfig", "AppConfig", "ClusterSetup"}
# Every other app module may only import these, so it has no file, handle,
# process, environment, network or foreign access of its own.
PURE_MODULES = re.compile(
    r"Prelude|Numeric(\.\w+)?|Text\.(Read|Printf)|System\.Exit|(Data|Control)(\.\w+)+|"
    r"Database\.Redis\.(Cluster|Cluster\.SlotMapping|Cluster\.Commands|Resp|Crc16|FromResp|RedisError)"
)
IMPURE_MODULES = re.compile(r"\bIO\b|Unsafe|Internal|X509|Network|Process|Environment|TLS|Socket")
OUTSIDE_ACCESS = re.compile(
    r"foreign|\w*File\w*|h(Get|Put|Set|Close|Print|Flush)\w*|get(Contents|Line|Char)\w*|interact|readLn|readIO|"
    r"unsafe\w*|std(in|out|err)|\w*([vV]erif(y|ier)|[tT]oken|[lL]ogin|[sS]asl)\w*"
)
DISGUISED_STRING = re.compile(r"\\(\d|x|o|\^|&|\s|[A-Z])")
CONNECTION_MODULES = re.compile(
    r"Database\.Redis|Database\.Redis\.(Client|Connector|Standalone)(\..*)?|Database\.Redis\.Cluster\.Client|"
    r"Network(\..*)?|System\.(Environment|X509)(\..*)?|Data\.X509(\..*)?|Crypto(\..*)?"
)

# First match wins; patterns are matched against the lower-cased path.
PATH_RULES = [
    (re.compile(pattern), merge_class, reason)
    for pattern, merge_class, reason in (
        (r"(\.github|\.githooks|\.claude|\.agents|\.copilot|scripts)/.*", MAINTAINER, "factory control"),
        (r"(.*/)?makefile", MAINTAINER, "factory control"),
        (r"docs/(adr|agents)/.*|docs/factory\b.*", MAINTAINER, "factory control"),
        (r"docs/release-process\.md", MAINTAINER, "releases"),
        (r"hask-redis-mux/lib/client/.*|hask-redis-mux/lib/cluster/database/redis/connector\.hs",
         MAINTAINER, "authentication, TLS, credentials"),
        (r"app/(main|appconfig|clustersetup|credentialconfig|fillprocess)\.hs", MAINTAINER, "authentication, TLS, credentials"),
        (r"(test|hask-redis-mux/test)/.*\.hs", LOW, "tests"),
        (r"(bench|hask-redis-mux/bench)/.*\.hs", EXTRA, "performance evidence"),
        (r"docs/(.*/)?[^/]+\.md|\.out-of-scope/[^/]+\.md|(hask-redis-mux/)?(readme|changelog)\.md|glossary\.md",
         LOW, "docs"),
        (r"flake\.lock", EXTRA, "lockfile"),
        (r"(hask-redis-mux/hask-redis-mux|redis-client)\.cabal", LOW, "package description"),
        (r"hask-redis-mux/lib/(resp|redis-command-client)/.*\.hs|hask-redis-mux/data/[^/]+\.json",
         EXTRA, "protocol"),
        (r"hask-redis-mux/lib/cluster/.*\.hs|hask-redis-mux/lib/crc16/.*\.(hs|c)|"
         r"hask-redis-mux/data/cluster_slot_mapping\.txt|app/cluster[^/]*\.hs|app/slotmapping[^/]*\.hs",
         EXTRA, "cluster"),
        (r"app/[^/]+\.hs|hask-redis-mux/lib/redis/.*\.hs", LOW, "internal code"),
    )
]


# Ways to skip, focus, stop or reconfigure tests, in a new file.
WEAKENING = re.compile(
    r"\w*(pending|exit|unsafe)\w*|[xf](it|describe|context|specify|prop)|focus|hspecWith\w*|runSpec\w*|evalSpec|"
    r"modify(Args|Config|Max\w+)|mapSpec\w*|filter(Test|Forest)\w*|config(Focused|Skip|Dry|Filter|Fail)\w*|withArgs",
    re.IGNORECASE,
)
# The only code that may be added to an existing test file as low risk is a
# complete new block: GROUP containing blocks, or TEST made of pure assertions.
GROUP = re.compile(r'(describe|context) "[^"\\]*" \$ do')
TEST = re.compile(r'(it|specify) "[^"\\]*" \$ (do|property \$ .*|.+)|prop "[^"\\]*" \$ .+')
SIBLING = re.compile(r'(it|specify|prop|describe|context) "')
ASSERTIONS = frozenset(
    "shouldBe shouldNotBe shouldSatisfy shouldNotSatisfy shouldContain shouldNotContain shouldStartWith "
    "shouldEndWith shouldMatchList".split()
)
# Where a name in an added test may come from.
PURE_TEST_MODULES = re.compile(
    r"Data\.(Bits|Char|Either|Int|List|List\.NonEmpty|Map|Map\.Strict|IntMap|IntMap\.Strict|Maybe|Ord|Ratio|"
    r"Sequence|Set|Text|Text\.Encoding|Tuple|Vector|Word|"
    r"ByteString|ByteString\.(Char8|Lazy|Lazy\.Char8|Builder))"
)
LOCAL_PURE_MODULES = re.compile(
    r"Database\.Redis\.(Resp|Crc16|FromResp|RedisError|Cluster|Cluster\.Commands|Cluster\.SlotMapping)|"
    r"FillHelpers|SlotMappingHelpers"
)
TEST_FRAMEWORKS = ("Test.Hspec", "Test.QuickCheck", "Test.Hspec.QuickCheck")
IO_TYPE = re.compile(r"IO|Expectation|Assertion|Spec|STM|\bST\b|[mM]onad|^m$|^f$|Property|Gen")
PURE_NAMES = frozenset(
    "abs all and any asTypeOf ceiling compare concat concatMap const curry cycle div divMod drop dropWhile either "
    "elem even filter flip floor foldl foldr fromEnum fromIntegral fromInteger fromRational fst gcd head id init "
    "iterate last lcm length lines lookup map max maxBound maximum maybe min minBound minimum mod negate not "
    "notElem null odd or otherwise pred product quot quotRem realToFrac rem repeat replicate reverse round scanl "
    "show signum snd span splitAt sqrt subtract succ sum tail take takeWhile toEnum toInteger toRational truncate "
    "uncurry unlines unwords unzip words zip zip3 zipWith mempty mappend mconcat "
    # hspec and QuickCheck, which the test framework itself runs
    "property forAll arbitrary choose elements listOf listOf1 vectorOf oneof counterexample conjoin disjoin "
    "classify label".split()
) | ASSERTIONS
PURE_OPERATORS = frozenset(
    "+ - * / ^ ^^ ** == /= < > <= >= && || ++ <> . $ : :| !! ! , -> :: @ .. .|. .&. % === =/= ==>".split()
)
# Actions that known-pure modules also export.
ACTION = re.compile(
    r"put\w*|print|useAs\w*|\w*CString\w*|(map|for|imap|ifor)M\w*|(traverse|for|sequence)\w*_|sequence\w*"
)
KEYWORDS = frozenset("do mdo rec where case of if then else let in import instance class data type foreign".split())
SUITE_NAME = re.compile(r"spec|\w+(Spec|Tests?)")
TEST_DIRECTORIES = ("hask-redis-mux/test", "hask-redis-mux/bench", "test", "bench")


class ClassificationError(Exception):
    pass


def strictest(classes):
    return max(classes, key=ORDER.index)


def classify_path(path):
    lowered = path.lower()
    if not PLAIN_PATH.fullmatch(path):
        return MAINTAINER, "unrecognized path"
    if any(part.startswith(".") and part != ".out-of-scope" for part in path.split("/")):
        return MAINTAINER, "hidden path"
    if lowered.endswith(".md") and INSTRUCTIONS.search(lowered):
        return MAINTAINER, "possible agent instructions"
    if "/" in path and path.split("/")[0] != lowered.split("/")[0]:
        return MAINTAINER, "unrecognized path"
    for pattern, merge_class, reason in PATH_RULES:
        if pattern.fullmatch(lowered):
            is_doc = lowered.endswith(".md")
            if merge_class != MAINTAINER and not is_doc and SENSITIVE.search(lowered):
                return MAINTAINER, "authentication, TLS, credentials"
            return merge_class, reason
    return MAINTAINER, "unrecognized path"


class Repository:
    def __init__(self, path):
        self.path = path
        self.blobs = {}
        self.environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.environment["GIT_NO_REPLACE_OBJECTS"] = "1"

    def git(self, *arguments):
        result = subprocess.run(
            ["git", "-C", str(self.path), *arguments], capture_output=True, env=self.environment
        )
        if result.returncode:
            raise ClassificationError(f"git {arguments[0]}: {result.stderr.decode(errors='replace').strip()}")
        return result.stdout

    def commit(self, revision):
        return self.git("rev-parse", "--verify", "--end-of-options", f"{revision}^{{commit}}").decode().strip()

    def tree(self, commit):
        """{path: (mode, object)} for a commit."""
        result = {}
        for row in self.git("ls-tree", "-r", "-z", "--full-tree", commit).split(b"\0"):
            if row:
                metadata, path = row.split(b"\t", 1)
                mode, _, identity = metadata.decode().split()
                result[path.decode("utf-8", "surrogateescape")] = (mode, identity)
        return result

    def text(self, tree, path):
        if path not in tree:
            return None
        mode, identity = tree[path]
        if not mode.startswith("100"):
            raise ClassificationError(f"{path} is not a regular file")
        if identity not in self.blobs:
            self.blobs[identity] = self.git("cat-file", "blob", identity).decode("utf-8")
        return self.blobs[identity]


def surfaces(repository, tree):
    result = {}
    for path in sorted(tree):
        if path.endswith(".cabal"):
            directory = posixpath.dirname(path)
            part = haskell_api.surface(
                repository.text(tree, path), directory, lambda name: repository.text(tree, name)
            )
            result.update({(posixpath.basename(path), key): value for key, value in part.items()})
    if not result:
        raise haskell_api.ApiError("no public API found")
    # One package holds the libraries, so its keys need no package prefix.
    packages = {package for package, _ in result}
    if len(packages) != 1:
        raise haskell_api.ApiError("more than one package exposes libraries")
    return {key: value for (_, key), value in result.items()}


def sources(tree):
    return {path: entry for path, entry in tree.items() if path.endswith((".cabal", ".hs"))}


def diff_api(repository, base, head):
    try:
        before = surfaces(repository, base)
        after = before if sources(base) == sources(head) else surfaces(repository, head)
        status, changes = haskell_api.compare(before, after)
        return {"status": status, "changes": changes}
    except Exception as error:  # whatever went wrong, the API diff failed
        return {"status": "failed", "changes": [], "error": f"{type(error).__name__}: {error}"}


SHIPPING = ("library", "executable", "common", "foreign-library")
DEPENDENCY_FIELDS = ("build-depends",)
CLEAR_BOUNDS = re.compile(r"(>=? ?[\d.]+ ?&& ?)?<=? ?[\d.]+|\^>= ?[\d.]+")
SAFE_TEST_OPTIONS = re.compile(r"-W[a-z-]*|-O\d?|-threaded|-rtsopts")
TEST_FIELDS = {"import", "type", "main-is", "other-modules", "hs-source-dirs", "ghc-options", "build-depends"}


def package_dependencies(stanzas, kinds=None):
    found = set()
    for stanza, fields in stanzas.items():
        if kinds is None or stanza.split()[0:1] and stanza.split()[0] in kinds:
            for key, value in fields.items():
                if key[-1] in DEPENDENCY_FIELDS:
                    found |= set(cabal_file.dependencies(value))
    return found


def classify_cabal(base_text, head_text):
    if base_text is None or head_text is None:
        yield MAINTAINER, "package description added or removed"
        return
    base, head = cabal_file.parse(base_text), cabal_file.parse(head_text)
    local = {"hask-redis-mux"}
    for stanzas in (base, head):
        local |= {s.split()[1] for s in stanzas if s.startswith("library ")}
    everything = package_dependencies(base) | local
    shipping = package_dependencies(base, SHIPPING) | local
    for stanza in sorted({*base, *head}):
        old, new = base.get(stanza, {}), head.get(stanza, {})
        kind = stanza.split()[0] if stanza else "package"
        testing = kind in ("test-suite", "benchmark")
        existing = stanza in base
        if testing and not existing:
            yield EXTRA, f"{stanza}: new code that runs in CI"
        if testing and existing and stanza not in head:
            yield MAINTAINER, f"{stanza}: test suite removed"
        runs_tests = testing or {"test", "bench"} & set(cabal_file.words(old.get(("hs-source-dirs",), "")))
        if not testing and (stanza in base) != (stanza in head):
            # Libraries are judged by the API diff only once they exist.
            yield MAINTAINER, f"{stanza}: component added or removed"
        for key in sorted({*old, *new}, key=str):
            before, after = old.get(key, ""), new.get(key, "")
            if before == after and (key in old) == (key in new):
                continue
            field, where = key[-1], f"{stanza or 'package'}: {' / '.join(key)}"
            if len(key) > 1:
                yield MAINTAINER, f"{where}: conditional field"
            elif field == "version" and not stanza:
                yield MAINTAINER, f"{where}: releases"
            elif field in DEPENDENCY_FIELDS:
                previous, current = cabal_file.dependencies(before), cabal_file.dependencies(after)
                known = everything if testing else shipping
                fresh = sorted(set(current) - set(previous) - known)
                unclear = sorted(
                    name for name, bounds in current.items()
                    if bounds != previous.get(name) and name not in local
                    and not CLEAR_BOUNDS.fullmatch(bounds)
                    # A test may use an already known package without bounds of its own.
                    and not (testing and not bounds and name not in previous)
                )
                if testing and set(previous) - set(current):
                    yield EXTRA, f"{where}: test dependency dropped"
                if unclear:
                    yield MAINTAINER, f"{where}: unclear bounds for {', '.join(unclear)}"
                if fresh:
                    yield MAINTAINER, f"{where}: new dependencies {', '.join(fresh)}"
                elif not testing:
                    yield EXTRA, f"{where}: dependency bounds"
                else:
                    yield (EXTRA if kind == "benchmark" else LOW), f"{where}: tests"
            elif field == "ghc-options" and not all(
                SAFE_TEST_OPTIONS.fullmatch(word) for word in cabal_file.words(after)
            ):
                yield MAINTAINER, f"{where}: compiler options"
            elif runs_tests and existing and field in ("main-is", "type", "hs-source-dirs", "import"):
                yield MAINTAINER, f"{where}: test suite rewired"
            elif runs_tests and field == "other-modules" and (
                set(cabal_file.words(before)) - set(cabal_file.words(after))
            ):
                yield MAINTAINER, f"{where}: test module dropped"
            elif testing and field in TEST_FIELDS:
                yield (EXTRA if kind == "benchmark" else LOW), f"{where}: tests"
            elif kind == "library" and field in ("exposed-modules", "reexported-modules"):
                yield EXTRA, f"{where}: exported modules"
            elif kind in ("library", "executable") and field == "other-modules":
                yield LOW, f"{where}: internal modules"
            else:
                yield MAINTAINER, f"{where}: unrecognized field"


def pieces(text):
    """Independently comparable parts of a Haskell file, without comments."""
    result = Counter()
    for chunk in chunks(tokenize(text)) if text else []:
        if chunk[0].text in ("module", "class", "instance") or chunk[0].column:
            rows = {}
            for token in chunk:
                rows.setdefault(token.line, []).append(token)
            if chunk[0].text == "module":
                result.update(render(row) for row in rows.values())
                continue
            # Methods are compared one by one so that an unrelated method in a
            # class which also handles AUTH does not count as authentication.
            items, indent = [[]], None
            for index, row in enumerate(rows.values()):
                if index and indent is None:
                    indent = row[0].column
                if index and row[0].column <= indent:
                    items.append([])
                items[-1] += row
            result.update(render(item) for item in items)
        else:
            result[render(chunk)] += 1
    return result


def sensitive_change(base_text, head_text):
    base, head = pieces(base_text), pieces(head_text)
    return any(SENSITIVE.search(piece) for piece in [*(base - head), *(head - base)])


def runs_at_build_time(text):
    if not text:
        return False
    try:
        # Only real pragmas count, not comments about them.
        text = "\n".join(token.text for token in tokenize(text) if token.kind == "pragma")
    except SourceError:
        pass  # search everything
    return bool(BUILD_TIME.search(text) or len(OPTIONS.findall(text)) != len(list(SAFE_OPTIONS.finditer(text))))


def imported_modules(text):
    try:
        tokens = tokenize(text)
    except SourceError:
        # Over-approximate: every capitalized word may be an imported module.
        return set(re.findall(r"[A-Z][\w.']*", text))
    return {
        next((t.text for t in tokens[index + 1 :] if t.kind == "ident" and t.text[0].isupper()), "")
        for index, token in enumerate(tokens) if token.text == "import" and token.kind == "ident"
    }


def has_outside_access(text, app_modules):
    try:
        tokens = tokenize(text)
    except SourceError:
        return True
    if any(
        module not in app_modules and (not PURE_MODULES.fullmatch(module) or IMPURE_MODULES.search(module))
        for module in imported_modules(text)
    ):
        return True
    return any(
        (t.kind == "ident" and OUTSIDE_ACCESS.fullmatch(haskell_api.base_name(t.text)))
        or (t.kind == "string" and DISGUISED_STRING.search(t.text))
        for t in tokens
    )


def sensitive_app_modules(repository, *trees):
    """App modules connected to credentials or connections in any of the trees."""
    sources = [
        (path[4:-3].replace("/", "."), repository.text(tree, path))
        for tree in trees for path in tree if path.startswith("app/") and path.endswith(".hs")
    ]
    imports = {name: set() for name, _ in sources}
    for name, text in sources:
        imports[name] |= imported_modules(text)
    outside = {name for name, text in sources if has_outside_access(text, imports)}
    used = set(CREDENTIAL_MODULES)
    pending = list(used)
    while pending:
        for name in imports.get(pending.pop(), set()) & imports.keys() - used:
            used.add(name)
            pending.append(name)
    users = outside | {
        name for name, found in imports.items()
        if found & CREDENTIAL_MODULES or any(CONNECTION_MODULES.fullmatch(module) for module in found)
    }
    while True:
        more = {name for name, found in imports.items() if found & users} - users
        if not more:
            return used | users
        users |= more


def rows(text):
    """Lines of code as token lists."""
    result = {}
    for token in tokenize(text):
        result.setdefault(token.line, []).append(token)
    return list(result.values())


def shape(row):
    # Spacing can change how Haskell lexes a line, so columns count too.
    return tuple((token.column, token.kind, token.text) for token in row)


def column(row):
    return row[0].column


def identifiers(text):
    return Counter(haskell_api.base_name(t.text) for t in tokenize(text) if t.kind == "ident")


def local_names(text, synonyms):
    """Values a local module exports whose signature involves no monad."""
    try:
        module = haskell_api.Module(text)
    except (SourceError, IndexError):
        return set()
    result = set()
    for entry in module.exports:
        if entry.namespace in ("module", "pattern"):
            continue
        result.add(entry.name)
        result |= module.children.get(entry.name, set()) if entry.subs == ".." else set(entry.subs or ())
    return {
        name for name in result
        if all(is_pure_signature(part, synonyms) for part in module.parts.get(name, []))
    }


def io_synonyms(texts):
    """Type synonyms, in any of the files, that stand for something with IO."""
    synonyms = {}
    for text in texts:
        try:
            for chunk in chunks(tokenize(text)):
                if chunk[0].text == "type" and len(chunk) > 1:
                    synonyms.setdefault(chunk[1].text, set()).update(t.text for t in chunk[2:])
        except SourceError:
            continue
    found = set()
    while True:
        more = {
            name for name, used in synonyms.items()
            if any(IO_TYPE.search(u) or haskell_api.base_name(u) in found for u in used)
        } - found
        if not more:
            return found
        found |= more


def is_pure_signature(tokens, synonyms):
    if any(
        IO_TYPE.search(t.text) or (t.kind == "ident" and haskell_api.base_name(t.text) in synonyms) for t in tokens
    ):
        return False
    start = next((i + 1 for i, t in enumerate(tokens) if t.text == "::"), 0)
    arrow = next((i for i, t in enumerate(tokens) if t.text == "=>"), None)
    if arrow is None:
        return True
    result = tokens[arrow + 1 :]
    arrows = [index for index, token in depth_zero(result) if token.text in ("->", "=>")]
    result = result[arrows[-1] + 1 :] if arrows else result
    constrained = {t.text for t in tokens[start:arrow] if t.kind == "ident" and not t.text[0].isupper()}
    # A constrained variable in the result could stand for an action.
    return not constrained & {t.text for t in result if t.kind == "ident"}


class Names:
    """Which names in an existing test file are known to be pure."""

    def __init__(self, text, local_exports, synonyms=frozenset()):
        self.pure, self.impure, self.aliases = set(), set(), {}
        signatures = set()
        self.framework = set()
        for chunk in chunks(tokenize(text)):
            if chunk[0].text == "import":
                item = haskell_api.parse_import(chunk)
                known = bool(PURE_TEST_MODULES.fullmatch(item.module))
                exported = local_exports.get(item.module)
                self.aliases.setdefault(item.alias, []).append((known, exported))
                if item.qualified:
                    continue
                if item.entries is not None and not item.hiding:
                    listed = {e.name for e in item.entries} | {
                        sub for e in item.entries if isinstance(e.subs, tuple) for sub in e.subs
                    }
                    if item.module in TEST_FRAMEWORKS:
                        self.framework |= listed
                        continue
                    for name in listed:
                        pure = name in exported if exported is not None else known
                        (self.pure if pure else self.impure).add(name)
                elif exported is not None:
                    self.pure |= exported
                elif item.hiding and item.module == "Prelude":
                    self.impure |= {e.name for e in item.entries}
                continue
            names = haskell_api.signature_names(chunk) if chunk[0].kind != "pragma" else None
            if names:
                signatures |= set(names)
                pure = is_pure_signature(chunk, synonyms)
                (self.pure if pure else self.impure).update(names)
            elif chunk[0].text != "module":
                # Anything else defined here, including operators, fields and
                # methods, is unknown unless it has a pure signature.
                self.impure |= {t.text for t in chunk[:1] if t.kind == "ident"} - signatures
                if chunk[0].text in ("class", "data", "newtype", "foreign", "infix", "infixl", "infixr") or (
                    chunk[0].kind != "ident"
                ):
                    self.impure |= {t.text for t in chunk if t.kind in ("ident", "operator")}
                left = chunk
                for index, token in depth_zero(chunk):
                    if token.text in ("=", "|"):
                        left = chunk[:index]
                        break
                if chunk[0].text not in ("class", "data", "newtype", "instance", "type", "deriving"):
                    self.impure |= {
                        t.text for _, t in depth_zero(left) if t.kind == "operator" and t.text not in ("@", "!")
                    }

    def can_bind(self, name):
        """Whether a lambda or let may introduce a name without hiding another."""
        return name == "_" or not (
            screened(name) or name in self.pure | self.impure | self.framework | PURE_NAMES
        )

    def allows(self, text):
        name = haskell_api.base_name(text)
        if screened(name):
            return False
        if name != text:
            sources = self.aliases.get(text[: -len(name) - 1], [])
            return bool(sources) and all(
                name in exported if exported is not None else known for known, exported in sources
            )
        return name not in self.impure and (name in self.pure or name in PURE_NAMES)


def screened(name):
    return bool(WEAKENING.fullmatch(name) or OUTSIDE_ACCESS.fullmatch(name) or ACTION.fullmatch(name))


def is_expression(tokens, names, bound=frozenset()):
    """Whether tokens use only allowed operators, pure names and lambda variables."""
    # (scope when a bracket or element starts, scope after its lambdas)
    scopes, index = [(frozenset(bound), frozenset(bound))], 0
    try:
        sum(1 for _ in depth_zero(tokens))
    except SourceError:
        return False
    while index < len(tokens):
        token = tokens[index]
        if token.kind == "punct":
            if token.text in "([{":
                scopes.append((scopes[-1][1], scopes[-1][1]))
            elif token.text in ")]}":
                scopes.pop()
            elif token.text == ",":
                scopes[-1] = (scopes[-1][0], scopes[-1][0])
            elif token.text == ";":
                return False
        elif token.kind == "operator" and token.text == "\\":
            end = next((i for i in range(index, len(tokens)) if tokens[i].text == "->"), None)
            if end is None:
                return False
            pattern = tokens[index + 1 : end]
            try:
                sum(1 for _ in depth_zero(pattern))
            except SourceError:
                return False
            for part in pattern:
                if not (part.kind == "ident" or part.kind == "punct" and part.text in "(),"):
                    return False
                if part.text in KEYWORDS:
                    return False
                if not haskell_api.is_upper(part):
                    if not names.can_bind(part.text):
                        return False
                    scopes[-1] = (scopes[-1][0], scopes[-1][1] | {part.text})
            index = end
        elif token.kind == "operator":
            if "." in token.text and token.text[0].isupper():
                operator = token.text.lstrip("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_'.")
                alias = token.text[: len(token.text) - len(operator) - 1]
                sources = names.aliases.get(alias, [])
                if not sources or not all(known for known, _ in sources):
                    return False
            elif token.text not in PURE_OPERATORS or token.text in names.impure:
                return False
        elif token.kind == "ident":
            if token.text in KEYWORDS:
                return False
            if not haskell_api.is_upper_name(token.text):
                if token.text not in scopes[-1][1] and not names.allows(token.text):
                    return False
        elif token.kind == "pragma":
            return False
        index += 1
    return bool(tokens)


def is_assertion(tokens, names, bound=frozenset()):
    """One `left `shouldX` right` whose operands are pure expressions."""
    try:
        outer = list(depth_zero(tokens))
    except SourceError:
        return False
    ticks = [index for index, token in outer if token.text == "`"]
    if any(token.text in ("$", "->", "\\", "=", "@") for _, token in outer if token.kind == "operator"):
        return False
    found = [i for i in ticks[::2] if tokens[i + 1].text in ASSERTIONS]
    if len(found) != 1:
        return False
    left, right = tokens[: found[0]], tokens[found[0] + 3 :]
    # Other backticked functions could bind looser than the assertion.
    if any(tokens[i + 1].text not in ("div", "mod", "quot", "rem", "elem", "notElem") for i in ticks[::2] if i != found[0]):
        return False
    return is_expression(left, names, bound) and is_expression(right, names, bound)


def items(block):
    """Split rows into layout items, or None when they are not aligned."""
    result = []
    for row in block:
        if column(row) < column(block[0]):
            return None
        if column(row) == column(block[0]):
            result.append([])
        result[-1].append(row)
    return result


def is_test_block(block, names):
    """Whether rows are one complete group or test that only makes assertions."""
    header, body = render(block[0]), items(block[1:])
    if body is None or any(column(row) <= column(block[0]) for row in block[1:]):
        return False
    if GROUP.fullmatch(header):
        return bool(body) and all(is_test_block(item, names) for item in body)
    match = TEST.fullmatch(header)
    if not match:
        return False
    tokens = [token for row in block for token in row][3:]
    bound = set()
    if match[2] == "do":
        for item in body:
            statement = [token for row in item for token in row]
            if statement[0].text == "let" and len(statement) > 3:
                binding = statement[1:]
                if binding[0].kind != "ident" or not names.can_bind(binding[0].text) or binding[1].text != "=" or not is_expression(
                    binding[2:], names, bound
                ):
                    return False
                # A second binding would start in the column of the first.
                if any(column(row) <= binding[0].column for row in item[1:]):
                    return False
                bound.add(binding[0].text)
            elif not is_assertion(statement, names, bound):
                return False
        return bool(body) and not render(body[-1][0]).startswith("let ")
    if block[0][0].text == "prop" or tokens[0].text == "property":
        return is_expression(tokens, names)
    return is_assertion(tokens, names)


def only_new_tests(old, new, names):
    """Whether new is old plus complete test blocks, each after a sibling."""
    old, new = rows(old), rows(new)
    position, added = 0, []
    for index, row in enumerate(new):
        if position < len(old) and shape(row) == shape(old[position]):
            position += 1
        else:
            added.append(index)
    if position < len(old):
        return False
    index = 0
    while index < len(added):
        start = added[index]
        indent, end = column(new[start]), start + 1
        while end < len(new) and end in added and column(new[end]) > indent:
            end += 1
        if not is_test_block(new[start:end], names) or (end < len(new) and column(new[end]) > indent):
            return False
        sibling = start - 1
        while sibling >= 0 and column(new[sibling]) > indent:
            sibling -= 1
        outer = sibling
        while outer >= 0 and column(new[outer]) >= indent:
            outer -= 1
        # The block must be a statement of an existing `do`, after another test in it.
        if sibling < 0 or column(new[sibling]) != indent or not SIBLING.match(render(new[sibling])):
            return False
        if outer < 0 or new[outer][-1].text != "do" or column(new[outer + 1]) != indent:
            return False
        if new[start - 1][-1].kind == "operator" or new[start - 1][-1].text in ("do", "`", ","):
            return False
        index += end - start
    return True


def classify_test_edit(old, new, test_modules, local_exports, synonyms):
    """Classify a change to an existing test file, or a new one when old is None."""
    if old is None:
        if any(WEAKENING.fullmatch(name) for name in identifiers(new)):
            yield EXTRA, "new code may skip or weaken tests"
        return
    if (imported_modules(old) - imported_modules(new)) & test_modules:
        yield MAINTAINER, "a test file no longer imports a test module"
    if any(SUITE_NAME.fullmatch(name) for name in identifiers(old) - identifiers(new)):
        yield MAINTAINER, "a test suite is no longer run"
    if not only_new_tests(old, new, Names(old, local_exports, synonyms)):
        yield EXTRA, "more than complete new tests"


class TestTree:
    """What the test and benchmark components use before a change."""

    def __init__(self, repository, tree):
        self.exports = {}  # pure values of the local modules tests may name
        self.synonyms = io_synonyms(repository.text(tree, path) for path in tree if path.endswith(".hs"))
        self.wired = set()  # files that a component runs or builds
        self.modules = {"Prelude"}  # modules that a new file must not shadow
        self.tests = {
            path[len(directory) + 1 : -3].replace("/", ".")
            for path in tree for directory in TEST_DIRECTORIES
            if path.startswith(directory + "/") and path.endswith(".hs")
        }
        for path in tree:
            if path.endswith(".cabal"):
                try:
                    self._package(posixpath.dirname(path), cabal_file.parse(repository.text(tree, path)))
                except cabal_file.CabalError as error:
                    raise ClassificationError(f"{path}: {error}") from error
            elif path.endswith(".hs"):
                name = re.sub(r"^(app|hask-redis-mux/lib/[^/]+)/", "", path)[:-3].replace("/", ".")
                if LOCAL_PURE_MODULES.fullmatch(name):
                    self.exports[name] = local_names(repository.text(tree, path), self.synonyms)
                # test components also build app and library files
                self.modules |= imported_modules(repository.text(tree, path))

        self.shadowed = {name.casefold() for name in self.modules}

    def _package(self, directory, stanzas):
        for stanza, fields in stanzas.items():
            values = {}
            for name in (stanza, *(f"common {i}" for i in cabal_file.words(fields.get(("import",), "")))):
                for key, value in stanzas.get(name, {}).items():
                    values.setdefault(key[-1], []).extend(cabal_file.words(value))
            directories = values.get("hs-source-dirs", [])
            if stanza.split()[0:1] not in (["test-suite"], ["benchmark"]) and not {"test", "bench"} & set(directories):
                continue
            mains = values.get("main-is", [])
            modules = values.get("other-modules", [])
            for file in (*mains, *(m.replace(".", "/") + ".hs" for m in modules)):
                self.wired |= {posixpath.join(directory, d, file) for d in directories}
            self.modules |= {m[:-3].replace("/", ".") for m in mains} | set(modules)

    def classify(self, path, old, new):
        directory = next((d for d in TEST_DIRECTORIES if path.startswith(d + "/")), None)
        if new is None:
            if path in self.wired:
                yield MAINTAINER, "a file of a test suite removed"
            elif directory:
                yield EXTRA, "test deleted"
            return
        if old is None:
            name = path[len(directory or "app") + 1 : -3].replace("/", ".")
            if (directory or path.startswith("app/")) and name.casefold() in self.shadowed:
                yield MAINTAINER, "the new file shadows a module used by tests"
        if directory:
            yield from classify_test_edit(old, new, self.tests, self.exports, self.synonyms)


def classify_file(repository, base, head, path, sensitive_modules, test_tree):
    merge_class, reason = classify_path(path)
    yield merge_class, reason
    old, new = base.get(path), head.get(path)
    modes = {entry[0] for entry in (old, new) if entry}
    if modes - {"100644", "100755"} or (old and new and old[0] != new[0]) or (not old and new[0] != "100644"):
        yield MAINTAINER, "unusual file mode"
        return
    if merge_class == MAINTAINER:
        return
    lowered = path.lower()
    try:
        if path.endswith(".hs"):
            yield from test_tree.classify(path, repository.text(base, path), repository.text(head, path))
        if lowered.endswith(".cabal"):
            yield from classify_cabal(repository.text(base, path), repository.text(head, path))
        elif lowered.endswith(".hs") and any(
            runs_at_build_time(repository.text(tree, path)) for tree in (base, head)
        ):
            yield MAINTAINER, "code that runs while compiling"
        elif path.startswith("app/") and path[4:-3].replace("/", ".") in sensitive_modules:
            yield MAINTAINER, "connected to credentials or with outside access"
        elif lowered.endswith(".hs") and not re.match(r"(hask-redis-mux/)?(test|bench)/", lowered):
            if sensitive_change(repository.text(base, path), repository.text(head, path)):
                yield MAINTAINER, "authentication, TLS, credentials in changed code"
    except (SourceError, cabal_file.CabalError, UnicodeDecodeError, ClassificationError) as error:
        yield MAINTAINER, f"cannot parse: {error}"


def classify(repository, base_revision, head_revision):
    result = {"class": MAINTAINER, "reasons": [], "api": {"status": "failed", "changes": []}}
    base_commit = repository.commit(base_revision)
    head_commit = repository.commit(head_revision)
    merge_bases = repository.git("merge-base", "--all", base_commit, head_commit).decode().split()
    merge_base = merge_bases[0]
    result.update(base=base_commit, head=head_commit, merge_base=merge_base)
    reasons = result["reasons"]

    def add(merge_class, reason, path=None):
        reasons.append({"class": merge_class, "reason": reason, **({"path": path} if path else {})})

    trusted = repository.tree(base_commit)
    directory = Path(__file__).resolve().parent
    for path in SELF:
        own = (directory / posixpath.basename(path)).read_bytes()
        if path not in trusted or repository.git("cat-file", "blob", trusted[path][1]) != own:
            add(MAINTAINER, "the running classifier is not the base branch's", path)
    if len(merge_bases) != 1:
        add(MAINTAINER, "no single merge base")
    if len(repository.git("rev-list", "--parents", "-n", "1", head_commit).split()) > 2:
        add(MAINTAINER, "the head is a merge commit")
    old, new = repository.tree(merge_base), repository.tree(head_commit)
    names = Counter(path.casefold() for path in new)
    # A rename is a deletion plus an addition, so both paths are classified.
    changed = sorted(path for path in {*old, *new} if old.get(path) != new.get(path))
    sensitive_modules = sensitive_app_modules(repository, old, new)
    test_tree = TestTree(repository, old)
    for path in changed:
        if names[path.casefold()] > 1:
            add(MAINTAINER, "path differs from another only by case", path.encode("utf-8", "replace").decode())
        for merge_class, reason in classify_file(repository, old, new, path, sensitive_modules, test_tree):
            add(merge_class, reason, path.encode("utf-8", "replace").decode())
    if not changed:
        add(MAINTAINER, "empty change")
    result["api"] = diff_api(repository, old, new)
    status = result["api"]["status"]
    if status != "unchanged":
        add(
            {"compatible": EXTRA, "breaking": MAINTAINER}.get(status, MAINTAINER),
            {"compatible": "backward-compatible API", "breaking": "breaking API"}.get(status, "API diff failed"),
        )
    result["class"] = strictest(reason["class"] for reason in reasons)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", type=Path, default=Path(__file__).parents[2])
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    arguments = parser.parse_args()
    try:
        result = classify(Repository(arguments.repo), arguments.base, arguments.head)
    except Exception as error:  # any failure takes the strictest class
        result = {
            "class": MAINTAINER,
            "reasons": [{"class": MAINTAINER, "reason": f"{type(error).__name__}: {error}"}],
            "api": {"status": "failed", "changes": []},
        }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
