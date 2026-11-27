"""Prove that the factory token cannot do what only the maintainer may.

prove(admin, token, run, nonce) -> (problems, unproved)

`admin` and `token` are apis (setup_github.py); `run` is a Factory resume run that
waits for approval. Empty `problems` means every mandatory attempt was refused.
`unproved` lists extra permissions GitHub's answers could not settle.

No attempt can do lasting harm if the token turns out to be too powerful:
  * The pending approval is REJECTED, not approved. Both need the same permission,
    and a rejected resume resumes nothing.
  * The workflow change is an inert new file on a scratch branch, never on main.
  * The ruleset attempt runs on a scratch branch under a temporary copy of main's
    rules without bypass actors. main itself is never written.
  * The tag has a scratch name that no workflow publishes. It is tried only after
    the tag ruleset was verified.
  * Other permissions are tried on objects that do not exist, or with requests
    GitHub must reject as invalid.
No refusal counts alone: every attempt is made twice, and answers that disagree,
even two refusals with a different status or message, are reported as NOT PROVED,
a problem. Git data and file writes succeed with the same calls
where they are allowed, before and after, and the push main's rules refused must
succeed once the copy is gone. For the other attempts the maintainer's login sends
the same harmless request (for the approval, one naming no real environment) and
must get a different answer, so an outage, a dead token, or a malformed request is
not a refusal. What stays open is in `unproved`, never counted as proved.

Scratch commits say [skip ci]. Scratch objects are removed in all cases: Ctrl-C, a
closed terminal or SIGTERM stops the test, and further ones do not stop the cleanup.
After SIGKILL or a crash, the wizard's next run offers it. cleanup() touches only
names under PREFIX. Unreferenced Git objects stay, as after any branch deletion.
"""

import base64
import signal
import time
from contextlib import contextmanager

from setup_github import (
    MAINTAINER,
    ROOT,
    Problem,
    check,
    everything,
    get,
    main_rules,
    tag_ruleset,
    waiting_resume,
)

PREFIX = "factory-negative-test"
SIGNALS = (signal.SIGINT, signal.SIGHUP, signal.SIGTERM)
DENIED = "Resource not accessible by personal access token"
INERT = (
    "on: workflow_dispatch\njobs:\n  inert:\n    if: false\n"
    "    runs-on: ubuntu-latest\n    steps:\n      - run: 'true'\n"
)


def permission_probes(nonce):
    """Permissions neither token may have. Nothing changes even when permitted."""
    absent = f"{PREFIX}-{nonce}"
    variable = absent.replace("-", "_").upper()
    return {
        "Administration": ("DELETE", f"{ROOT}/environments/{absent}", None),
        "Variables": ("DELETE", f"{ROOT}/actions/variables/{variable}", None),
        "Secrets": ("DELETE", f"{ROOT}/actions/secrets/{variable}", None),
        "Actions": ("POST", f"{ROOT}/actions/workflows/{absent}.yml/dispatches", {"ref": "main"}),
        "Deployments": ("POST", f"{ROOT}/deployments", {"ref": absent}),
    }


def write_probes():
    """Permissions the publisher has and the gate must not. GitHub rejects them as invalid."""
    ref = {"ref": f"refs/heads/{PREFIX}-invalid", "sha": "0" * 40}
    return {
        "Issues": ("POST", f"{ROOT}/issues", {}),
        "Pull requests": ("POST", f"{ROOT}/pulls", {}),
        "Contents": ("POST", f"{ROOT}/git/refs", ref),
    }


def denied(answer):
    return (
        answer.status == 403
        and isinstance(answer.body, dict)
        and str(answer.body.get("message", "")).startswith(DENIED)
    )


def _send_twice(admin, token, request, controls=(404, 409, 422)):
    """The token's two answers, each after the maintainer's control. None if a control failed."""
    answers = []
    for _ in range(2):
        if admin(*request).status not in controls:
            return None
        answers.append(token(*request))
    return answers


def _message(answer):
    return str(answer.body.get("message")) if isinstance(answer.body, dict) else None


def _settled(what, answers, refused):
    """A problem unless both answers are the same refusal; NOT PROVED when they disagree.

    Two refusals with different statuses or messages are not the same refusal: one of
    them may be an outage or a malformed request rather than a missing permission.
    """
    if answers is None:
        return f"control failed: {what}, for the maintainer"
    verdicts = [refused(answer) for answer in answers]
    same = len({(answer.status, _message(answer)) for answer in answers}) == 1
    if all(verdicts) and same:
        return None
    statuses = ", ".join(str(answer.status) for answer in answers)
    if any(verdicts):
        return f"NOT PROVED: {what} (answers {statuses}); try again later"
    return f"{what} was not refused (answers {statuses})"


def probe_denied(admin, token, probes):
    """(problems, unproved): each probe is sent twice with both logins."""
    problems, unproved = [], []
    for permission, request in probes.items():
        answers = _send_twice(admin, token, request)
        if answers and [answer.status for answer in answers] == [404, 404]:
            unproved.append(f"no {permission}: write")
            continue
        problem = _settled(f"{permission}: write", answers, denied)
        if problem:
            problems.append(problem)
    return problems, unproved


def fine_grained(token):
    """Problems with the kind of token, its owner, or its expiry."""
    answer = token("GET", "/user")
    if answer.status != 200 or answer.body.get("login") != MAINTAINER:
        return [f"the token does not work or is not {MAINTAINER}'s"]
    problems = []
    if "x-oauth-scopes" in answer.headers:
        problems.append("the token is a classic token, not a fine-grained one")
    if "github-authentication-token-expiration" not in answer.headers:
        problems.append("the token has no expiry date")
    return problems


def prove(admin, token, run, nonce, *, settle=5):
    problems = fine_grained(token) + check(tag_ruleset, admin) + check(leftover_problems, admin)
    if waiting_resume(admin) != run:
        problems.append("the Factory resume run is not waiting")
    if problems:
        return problems, []

    problems = _approval(admin, token, run)
    if problems:  # Far too powerful, or untestable, so give it no more to do.
        return problems, []
    unproved = []
    with _stoppable():
        try:
            found, unproved = _permissions(admin, token, nonce)
            problems += found
            problems += _repository(admin, token, nonce, settle)
        except Problem as error:
            problems.append(str(error))
        finally:
            _ignore_signals()
            problems += cleanup(admin, token, settle=settle)
    if waiting_resume(admin) != run:
        problems.append("the Factory resume run stopped waiting during the test")
    return problems, unproved


def _ignore_signals():
    for number in SIGNALS:
        signal.signal(number, signal.SIG_IGN)


@contextmanager
def _stoppable():
    """The first stop raises KeyboardInterrupt; later ones are ignored."""
    def stop(*_):
        _ignore_signals()
        raise KeyboardInterrupt

    before = [signal.signal(number, stop) for number in SIGNALS]
    try:
        yield
    finally:
        for number, handler in zip(SIGNALS, before):
            signal.signal(number, handler)


def _approval(admin, token, run):
    run_id, environment_id = run
    path = f"{ROOT}/actions/runs/{run_id}/pending_deployments"
    decision = {"environment_ids": [1], "state": "rejected", "comment": PREFIX}
    answers = []
    for _ in range(2):
        if admin("POST", path, decision).status != 422:
            answers = None
            break
        answers.append(token("POST", path, {**decision, "environment_ids": [environment_id]}))
        if not denied(answers[-1]):
            answers.append(answers[-1])  # It may have decided; never try again.
            break
    problem = _settled("deciding a pending environment", answers, denied)
    if waiting_resume(admin) != run:
        return [problem or "the Factory resume run stopped waiting"]
    return [problem] if problem else []


def _permissions(admin, token, nonce):
    problems, unproved = probe_denied(admin, token, permission_probes(nonce))
    # A 422 shows write access only if GitHub checks permission before validity.
    checked_first = denied(token(*permission_probes(nonce)["Deployments"]))
    for permission, request in write_probes().items():
        if permission == "Contents":  # _repository uses it.
            continue
        if admin(*request).status != 422 or token(*request).status != 422:
            problems.append(f"the token lacks {permission}: write, or that cannot be tested")
        elif not checked_first:
            unproved.append(f"has {permission}: write")
    return problems, unproved


def _repository(admin, token, nonce, settle):
    problems = []

    def expect_refused(what, attempt, unchanged, ruled=False):
        """Two attempts; each must be refused and change nothing."""
        def refused(answer):
            message = str(answer.body.get("message", "")) if isinstance(answer.body, dict) else ""
            return _refused(answer) and unchanged() and (not ruled or "rule" in message.lower())

        problem = _settled(what, [attempt(), attempt()], refused)
        if problem:
            problems.append(problem)

    control = f"{PREFIX}/{nonce}/control"
    update = f"{ROOT}/git/refs/heads/{control}"
    head = get(admin, f"{ROOT}/git/ref/heads/main")["object"]["sha"]

    # Control: the same calls work where they are allowed.
    first = _made(_commit(token, head, f"{PREFIX}.txt", "1\n"), "commit")["sha"]
    _made(_branch(token, control, first), "new branch")
    second = _made(_commit(token, first, f"{PREFIX}.txt", "2\n"), "commit")["sha"]
    _made(token("PATCH", update, {"sha": second, "force": False}), "branch update")
    _made(_branch(token, f"{PREFIX}/{nonce}/tag-control", head), "new branch at main")
    _made(_file(token, control, f"{PREFIX}-file.txt", "1\n"), "file write")

    # Workflows: as the publisher writes, then through the contents API.
    path = f".github/workflows/negative-test-{nonce}.yml"
    target = f"{PREFIX}/{nonce}/workflow"
    def push_workflow():
        answer = _commit(token, second, path, INERT)
        if answer.status == 201:
            answer = _branch(token, target, answer.body["sha"])
        return answer

    expect_refused("pushing a workflow file", push_workflow,
                   lambda: _absent(admin, f"{ROOT}/git/ref/heads/{target}"))
    expect_refused("writing a workflow file", lambda: _file(token, control, path, INERT),
                   lambda: _absent(admin, f"{ROOT}/contents/{path}?ref={control}"))

    # Ruleset: the same update as the control, now under main's rules.
    before = get(admin, f"{ROOT}/git/ref/heads/{control}")["object"]["sha"]
    third = _made(_commit(token, before, f"{PREFIX}.txt", "3\n"), "commit")["sha"]
    rulesets = [
        _made(admin("POST", f"{ROOT}/rulesets", {
            "name": f"{PREFIX}-{nonce}-{index}",
            "target": "branch",
            "enforcement": "active",
            "bypass_actors": [],
            "conditions": {"ref_name": {"include": [f"refs/heads/{control}"], "exclude": []}},
            "rules": rules,
        }), "temporary ruleset")["id"]
        for index, rules in enumerate(main_rules(admin))
    ]
    time.sleep(settle)
    expect_refused(
        "pushing against main's rules",
        lambda: token("PATCH", update, {"sha": third, "force": False}),
        lambda: get(admin, f"{ROOT}/git/ref/heads/{control}")["object"]["sha"] == before,
        ruled=True,
    )
    scratch = f"{ROOT}/rulesets/{rulesets[0]}"
    expect_refused("deleting a ruleset", lambda: token("DELETE", scratch),
                   lambda: admin("GET", scratch).status == 200)

    tag = f"tags/{PREFIX}-{nonce}"
    expect_refused("creating a tag",
                   lambda: token("POST", f"{ROOT}/git/refs", {"ref": f"refs/{tag}", "sha": head}),
                   lambda: _absent(admin, f"{ROOT}/git/ref/{tag}"))

    # Control: without the copied rules the refused push works, so the token and
    # the request were good all along.
    for identity in rulesets:
        admin("DELETE", f"{ROOT}/rulesets/{identity}")
    for _ in range(3):
        time.sleep(settle)
        answer = token("PATCH", update, {"sha": third, "force": False})
        if answer.status == 200:
            break
    if not problems:
        _made(answer, "the same push without main's rules")
    return problems


def _refused(answer):
    message = str(answer.body.get("message", "")) if isinstance(answer.body, dict) else ""
    limited = (
        "retry-after" in answer.headers
        or answer.headers.get("x-ratelimit-remaining") == "0"
        or "rate limit" in message.lower()
    )
    return answer.status in (403, 404, 422) and not limited


def _absent(admin, path):
    return admin("GET", path).status == 404


def _made(answer, what):
    if answer.status not in (200, 201):
        raise Problem(f"control failed: {what} answered {answer.status}")
    return answer.body


def _commit(token, parent, path, content):
    base = get(token, f"{ROOT}/git/commits/{parent}")["tree"]["sha"]
    file = {"path": path, "mode": "100644", "type": "blob", "content": content}
    tree = token("POST", f"{ROOT}/git/trees", {"base_tree": base, "tree": [file]})
    if tree.status != 201:
        return tree
    return token("POST", f"{ROOT}/git/commits", {
        "message": f"[skip ci] {PREFIX}", "tree": tree.body["sha"], "parents": [parent],
    })


def _file(token, branch, path, content):
    return token("PUT", f"{ROOT}/contents/{path}", {
        "message": f"[skip ci] {PREFIX}",
        "branch": branch,
        "content": base64.b64encode(content.encode()).decode(),
    })


def _branch(token, name, commit):
    return token("POST", f"{ROOT}/git/refs", {"ref": f"refs/heads/{name}", "sha": commit})


def _scratch(admin):
    """Rulesets come first, because they protect their branch from deletion."""
    for ruleset in everything(admin, f"{ROOT}/rulesets"):
        if ruleset["name"].startswith(f"{PREFIX}-"):
            yield ruleset["name"], f"{ROOT}/rulesets/{ruleset['id']}"
    for prefix in (f"heads/{PREFIX}/", f"tags/{PREFIX}-"):
        refs = get(admin, f"{ROOT}/git/matching-refs/{prefix}")
        if not isinstance(refs, list):
            raise Problem("the scratch refs are not a list")
        for found in refs:
            if found["ref"].startswith(f"refs/{prefix}"):
                yield found["ref"], f"{ROOT}/git/{found['ref']}"


def leftovers(admin):
    return [name for name, _ in _scratch(admin)]


def leftover_problems(admin):
    for name in leftovers(admin):
        yield f"a scratch object is left: {name}; run the wizard with: cleanup"


def cleanup(admin, token=None, *, settle=5):
    """Done when two looks in a row find nothing, as a late write may still land."""
    clean, left = 0, []
    for attempt in range(6):
        if attempt:
            time.sleep(settle)
        try:
            found = list(_scratch(admin))
        except Exception:  # One failed look must not end the cleanup.
            clean, left = 0, ["scratch objects that could not be listed"]
            continue
        left = [name for name, _ in found]
        clean = 0 if left else clean + 1
        if clean == 2:
            return []
        for name, path in found:
            try:
                answer = admin("DELETE", path)
                if answer.status >= 300 and token and name.startswith("refs/tags/"):
                    token("DELETE", path)  # If it could create the tag, it may delete it.
            except Exception:
                pass  # The next look finds it again.
    left = left or ["nothing seen, but not confirmed"]
    return [
        f"left behind: {name}; " + (
            "turn the tag ruleset off, delete the tag, turn the ruleset on again"
            if name.startswith("refs/tags/") else "run the wizard with: cleanup"
        )
        for name in left
    ]
