#!/usr/bin/env python3
"""The steps behind setup-wizard.sh. Run the wizard, not this.

Exit 0 done or verified, 1 not verified, declined, or stopped.

    check NAME [ARGUMENT]   read-only; NAME is a key of CHECKS
    stored TOKEN            read-only: the token is stored, and the maintainer says it was tested
    labels | setup-test | dispatch-resume | resume | attest NAME
    token TOKEN | unset TOKEN | revoked TOKEN | cleanup

Every step that changes GitHub asks first, and needs the whole word `yes`. All but
unset and cleanup refuse while FACTORY_ENABLED is on, and nothing here can set it. Nothing is
remembered locally: state comes from GitHub, so every step can be run again. Changes
other than unset and cleanup also need this checkout to be GitHub's main, unmodified.

A token is read from a hidden terminal prompt, held in memory, and sent only to
`gh secret set` on stdin and, for GitHub's own tokens, to api.github.com. It is
never printed, passed as an argument or environment variable, or written to a
file. It is stored only after it passed its tests.
"""

import argparse
import os
import re
import secrets
import select
import subprocess
import sys
import termios
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import negative_test as negative  # noqa: E402
import setup_github as github  # noqa: E402
from setup_github import REPO, ROOT, Problem, check  # noqa: E402

# Exact or narrow lengths, so that a truncated or doubled paste is refused. GitHub and
# Anthropic do not document them; if they change, change them here.
GITHUB_TOKEN = r"github_pat_[A-Za-z0-9]{22}_[A-Za-z0-9]{59}"
TOKENS = {
    "gate": ("FACTORY_GATE_TOKEN", GITHUB_TOKEN),
    "publish": ("FACTORY_PUBLISH_TOKEN", GITHUB_TOKEN),
    "subscription": (
        "CLAUDE_CODE_OAUTH_TOKEN", r"(?!.+sk-ant-)sk-ant-oat[0-9]{2}-[A-Za-z0-9_-]{77,115}",
    ),
}
TOKENS["agent"] = TOKENS["subscription"]
ENVIRONMENT_OF = {
    "gate": "factory-publish", "publish": "factory-publish",
    "subscription": "factory-model", "agent": "factory-agent",
}
SUBSCRIPTIONS = ("subscription", "agent")
SUBSCRIPTION_LIFE = timedelta(days=365)
ATTESTATIONS = {
    "usage-credits": "claude.ai > Settings > Usage shows usage credits OFF, checked just now",
    "gate-scope": "the gate token is for sspeaks/redis-client only, with exactly Variables, Actions, "
                  "Issues and Contents: READ (Metadata is implied)",
    "publish-scope": "the publish token is for sspeaks/redis-client only, with exactly Contents, Issues and "
                     "Pull requests: READ AND WRITE (Metadata is implied)",
    "subscription-control": "you found where a setup-token is revoked in your Claude account",
    "subscription-expiry": "a calendar reminder is set for 11 months from now, as the token lasts one year",
}
CHECKS = {
    "preflight": github.preflight,
    "workflows": github.workflows_on_main,
    "switch": github.switch_off,
    "environment": github.environment,
    "labels": github.labels,
    "copies": github.secret_copies,
    "missing": github.secret_missing,
    "credits": github.usage_credits,
    "forks": github.fork_approval,
    "tags": github.tag_ruleset,
    "main": github.main_ruleset,
    "mergeable": github.main_mergeable,
    "checkout": github.checkout,
    "leftovers": negative.leftover_problems,
    "resumed": github.resumed,
}


def confirm(question):
    if sys.stdin.isatty():
        termios.tcflush(sys.stdin, termios.TCIFLUSH)  # Only an answer typed now counts.
    print(f"  ? {question}\n    Type yes to go on (visible; never paste a token here): ", end="", flush=True)
    answer = sys.stdin.readline().strip()
    if len(answer) > 30:
        raise Problem("if that was a token, the terminal has shown it: revoke it now")
    if answer != "yes":
        raise Problem("not confirmed; nothing more was done")


def say(text):
    print(f"  {text}", flush=True)


def require(*checks):
    """Run (function, *arguments) checks and stop at any problem."""
    problems = []
    for function, *arguments in checks:
        problems += check(function, github.gh_api, *arguments)
    if problems:
        raise Problem("\n  ".join(problems))


def before_change():
    require((github.preflight,), (github.checkout,), (github.switch_off,))


def made(answer, what):
    if not 200 <= answer.status < 300:
        raise Problem(f"{what} failed (answer {answer.status})")


def read_secret(prompt, pattern):
    """One hidden line. Anything after it makes the whole paste unusable."""
    terminal = None
    try:
        terminal = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        before = termios.tcgetattr(terminal)
    except (OSError, termios.error):
        if terminal is not None:
            os.close(terminal)
        raise Problem("there is no terminal that can hide input, so no token was read") from None
    hidden = termios.tcgetattr(terminal)
    hidden[3] &= ~(termios.ECHO | termios.ECHONL)
    try:
        termios.tcsetattr(terminal, termios.TCSAFLUSH, hidden)
        os.write(terminal, f"  {prompt} (hidden): ".encode())
        line = os.read(terminal, 4096)
        # Without line editing, an unfinished line is visible to select too.
        hidden[3] &= ~termios.ICANON
        termios.tcsetattr(terminal, termios.TCSANOW, hidden)
        more = bool(select.select([terminal], [], [], 0.5)[0])
        os.write(terminal, b"\n")
    finally:
        # Also discards the rest, so it cannot answer or show at a later prompt.
        termios.tcsetattr(terminal, termios.TCSAFLUSH, before)
        os.close(terminal)
    if more or not line.endswith(b"\n"):
        raise Problem("the paste was not exactly one line; nothing was stored")
    value = line.decode("ascii", "replace").strip()
    if not re.fullmatch(pattern, value):
        raise Problem("that is not a token of the expected kind and length; nothing was stored")
    return value


def store(secret, environment, value):
    command = ["gh", "secret", "set", secret, "--repo", REPO]
    if environment:
        command += ["--env", environment]
    ran = subprocess.run(
        command, input=value, text=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        env=github.gh_environment(), check=False,
    )
    if ran.returncode:
        raise Problem(f"gh secret set {secret} failed")


def labels(_):
    before_change()
    for name, description in github.NEW_LABELS.items():
        if check(github.labels, github.gh_api, (name,)):
            confirm(f"Create label {name}?")
            made(github.gh_api("POST", f"{ROOT}/labels", {
                "name": name, "description": description, "color": "5319e7",
            }), "creating the label")
    require((github.labels,))
    say("All labels exist.")


def dispatch(workflow):
    """Start a run on main and return its id."""
    before = github.latest_run(github.gh_api, workflow)
    made(github.gh_api(
        "POST", f"{ROOT}/actions/workflows/{workflow}.yml/dispatches", {"ref": "main"},
    ), f"starting {workflow}")
    for _ in range(30):
        time.sleep(2)
        run = github.latest_run(github.gh_api, workflow)
        if run and (not before or run["id"] != before["id"]):
            say(f"Started: {run['html_url']}")
            return run["id"]
    raise Problem(f"{workflow} did not appear")


def wait_for(path, done, what, *, minutes):
    deadline = time.monotonic() + minutes * 60
    while True:
        value = github.get(github.gh_api, path) if path else None
        if done(value):
            return value
        if time.monotonic() > deadline:
            raise Problem(f"{what} took longer than {minutes} minutes; run this step again")
        time.sleep(5)


def setup_test(_):
    before_change()
    require((github.workflows_on_main,), (github.environment, "factory-publish"))
    run = github.latest_run(github.gh_api, "factory-setup-test")
    if run and not check(github.setup_test, github.gh_api, run):
        say(f"Already passed: {run['html_url']}")
    else:
        if not run or run["status"] == "completed":
            confirm("Start Factory setup test? The gate then refuses work until an approved resume.")
            identity = dispatch("factory-setup-test")
        else:
            identity = run["id"]
        run = wait_for(f"{ROOT}/actions/runs/{identity}", lambda r: r["status"] == "completed",
                       "the setup test", minutes=15)
        require((github.setup_test, run))
        say("GitHub recorded the jobs and steps as gate.py expects.")
    # After an approved resume the gate allows again, as it should.
    decision = github.gate_if_enabled(github.gh_api)
    resume = github.latest_run(github.gh_api, "factory-resume")
    if resume and resume["created_at"] > run["updated_at"] and decision.allowed:
        say("A later approved resume has cleared it.")
    elif decision.allowed or f"run {run['id']} " not in decision.reason:
        raise Problem(f"the gate does not refuse because of that run: {decision.reason}")
    else:
        say(f"The gate refuses as it must: {decision.reason}")


def dispatch_resume(_):
    before_change()
    require((github.workflows_on_main,), (github.environment, "factory-resume"))
    if github.waiting_resume(github.gh_api):
        tested = github.latest_run(github.gh_api, "factory-setup-test")
        waiting = github.latest_run(github.gh_api, "factory-resume")
        if tested and waiting["created_at"] < tested["updated_at"]:
            raise Problem("a resume run older than the setup test is waiting; reject it and try again")
        say("A Factory resume run is already waiting.")
        return
    confirm("Start a Factory resume run? Leave it waiting: do not approve or reject it yet.")
    dispatch("factory-resume")
    wait_for(None, lambda _: github.waiting_resume(github.gh_api), "the resume run", minutes=10)
    say("It waits for your approval. Leave it waiting.")


def resume(_):
    require((github.preflight,), (github.resumed,))
    say("A Factory resume run was approved, and the gate would allow work with the switch on.")


def token(arguments):
    kind = arguments.token
    secret, pattern = TOKENS[kind]
    before_change()
    require(
        (github.workflows_on_main,),
        (github.environment, ENVIRONMENT_OF[kind]),
        (github.secret_copies,),
    )
    if kind in SUBSCRIPTIONS:
        for name in ("usage-credits", "subscription-control"):
            confirm(ATTESTATIONS[name] + "?")
    else:
        confirm(ATTESTATIONS[f"{kind}-scope"] + "?")
    run = None
    if kind == "publish":
        run = github.waiting_resume(github.gh_api)
        if not run:
            raise Problem("no Factory resume run is waiting; the negative test needs one")
        confirm(
            "Run the negative test? It makes scratch branches and a temporary ruleset named "
            f"{negative.PREFIX}, tries to make a tag, tries to reject the waiting resume run, and "
            "removes what it made."
        )
        clean()
    value = read_secret(f"Paste the new {secret}", pattern)
    unproved = []
    if kind == "gate":
        problems, unproved = gate_token_problems(github.gh_api, github.token_api(value))
    elif kind == "publish":
        problems, unproved = negative.prove(
            github.gh_api, github.token_api(value), run, secrets.token_hex(6)
        )
    else:
        problems = []
    if problems:
        raise Problem("the token was NOT stored; revoke it now:\n  " + "\n  ".join(problems))
    if unproved:
        confirm("NOT PROVED by any test, so only your word counts. Does the token's page show: "
                + ", ".join(unproved) + "?")
    places = sorted(place.removeprefix("environment ") if place.startswith("environment ") else ""
                    for place in github.KINDS[kind][1])
    places = [place or None for place in places]
    confirm(f"Store it as {secret} in: " + ", ".join(p or "repository Actions" for p in places) + "?")
    require((github.switch_off,), (github.environment, ENVIRONMENT_OF[kind]), (github.secret_copies,))
    for place in places:
        store(secret, place, value)
    require((github.secret_missing, kind), (github.secret_copies,))
    say(f"{secret} is stored.")
    if unproved:
        say("Still NOT PROVED, taken on your word: " + ", ".join(unproved))
    if kind in SUBSCRIPTIONS:
        say(f"It expires about {datetime.now(timezone.utc) + SUBSCRIPTION_LIFE:%Y-%m-%d}.")
        confirm(ATTESTATIONS["subscription-expiry"] + "?")


def gate_token_problems(admin, api):
    problems = negative.fine_grained(api)
    if problems:
        return problems, []
    for path in ("actions/variables", "actions/runs?per_page=1", "issues?per_page=1", "git/ref/heads/main"):
        if api("GET", f"{ROOT}/{path}").status != 200:
            problems.append(f"the token cannot read {path}")
    probes = {**negative.permission_probes(secrets.token_hex(6)), **negative.write_probes()}
    found, unproved = negative.probe_denied(admin, api, probes)
    # The repository is public, so reading these proves no permission.
    unproved += [f"has {name}: read" for name in ("Actions", "Issues", "Contents")]
    return problems + found, unproved


def stored(arguments):
    secret, _ = TOKENS[arguments.token]
    require((github.environment, ENVIRONMENT_OF[arguments.token]),
            (github.secret_missing, arguments.token), (github.secret_copies,))
    places = github.KINDS[arguments.token][1]
    dates = {place: date for place, date in github.secret_places(github.gh_api)[secret].items()
             if place in places}
    for place, date in dates.items():
        say(f"{secret} in {place}, last set {date}")
    if arguments.token in SUBSCRIPTIONS:
        oldest = min(datetime.fromisoformat(d.replace("Z", "+00:00")) for d in dates.values())
        left = oldest + SUBSCRIPTION_LIFE - datetime.now(timezone.utc)
        if left < timedelta(days=30):
            raise Problem("the subscription token expires within 30 days; rotate it")
        say(f"It expires in at most {left.days} days.")
        confirm(ATTESTATIONS["subscription-expiry"] + "?")
    else:
        confirm("GitHub cannot show a stored token, so this is not verified, only your word: "
                "did this wizard test and store that one?")


def attest(arguments):
    confirm(ATTESTATIONS[arguments.name] + "?")


def unset(arguments):
    """Offer to delete this token's copies, and any of its name where none belongs.

    One failure or refusal does not stop the others. The other subscription token,
    which has the same name in its own environment, is kept."""
    secret, _ = TOKENS[arguments.token]
    others = set().union(*(places for kind, (name, places) in github.KINDS.items()
                           if name == secret and kind != arguments.token))
    paths, problems = {}, []
    try:
        paths = github.secret_paths(github.gh_api)
    except Exception:  # Still try every place known without asking GitHub.
        problems.append("the list of environments could not be read")
        paths = dict(github.FIXED_PATHS)
        paths.update({f"environment {name}": f"{ROOT}/environments/{name}/secrets"
                      for name in ("release", "factory-model", "factory-publish", "factory-resume",
                                   "factory-agent")})
    for place, path in paths.items():
        if place in others:
            continue
        try:
            names = {found["name"].upper() for found in github.everything(github.gh_api, path, "secrets")}
            if secret not in names:
                continue
            confirm(f"Delete {secret} from {place}? Jobs that need it then fail.")
            made(github.gh_api("DELETE", f"{path}/{secret}"), "deleting it")
            say(f"Deleted from {place}.")
        except Problem as error:
            problems.append(f"{place}: {error}")
        except Exception as error:
            problems.append(f"{place}: unexpected {type(error).__name__}")
    if problems:
        raise Problem("some copies may remain:\n  " + "\n  ".join(problems))
    say(f"No copy of {secret} is left on GitHub. The token works until it is revoked where it was made.")


def usage_credits(_):
    """The standing confirmation that unattended runs use in place of a person's."""
    name, value = github.USAGE_CREDITS
    before_change()
    confirm(ATTESTATIONS["usage-credits"] + "?")
    confirm(f"Set repository variable {name} to exactly {value!r}? If credits are ever turned on, "
            "delete it first.")
    exists = github.gh_api("GET", f"{ROOT}/actions/variables/{name}").status == 200
    if exists:
        answer = github.gh_api("PATCH", f"{ROOT}/actions/variables/{name}", {"name": name, "value": value})
    else:
        answer = github.gh_api("POST", f"{ROOT}/actions/variables", {"name": name, "value": value})
    made(answer, f"setting {name}")
    require((github.usage_credits,))
    say(f"{name} is exactly {value!r}.")


def revoked(arguments):
    # Nothing is asked to be pasted: a 401 for a mistyped token would prove nothing.
    confirm(f"Have you revoked the old {arguments.token} token where it was made? "
            "This is your word; it is not verified.")


def clean():
    left = negative.leftovers(github.gh_api)
    if left:
        confirm("Delete these scratch objects: " + ", ".join(left) + "?")
        problems = negative.cleanup(github.gh_api)
        if problems:
            raise Problem("\n  ".join(problems))
    say("No scratch objects are left.")


def cleanup(_):
    require((github.preflight,))
    clean()


def run_check(arguments):
    require((CHECKS[arguments.name], *([arguments.argument] if arguments.argument else [])))
    say("Verified: " + " ".join(filter(None, (arguments.name, arguments.argument))))


def main(argv=None):
    parser = argparse.ArgumentParser(description="Steps of the factory setup wizard.")
    commands = parser.add_subparsers(dest="command", required=True)
    one = commands.add_parser("check")
    one.add_argument("name", choices=CHECKS)
    one.add_argument("argument", nargs="?")
    one.set_defaults(function=run_check)
    one = commands.add_parser("attest")
    one.add_argument("name", choices=ATTESTATIONS)
    one.set_defaults(function=attest)
    for function in (token, stored, unset, revoked):
        one = commands.add_parser(function.__name__)
        one.add_argument("token", choices=TOKENS)
        one.set_defaults(function=function)
    for function in (labels, setup_test, dispatch_resume, resume, cleanup, usage_credits):
        one = commands.add_parser(function.__name__.replace("_", "-"))
        one.set_defaults(function=function)
    arguments = parser.parse_args(argv)
    try:
        arguments.function(arguments)
    except Problem as error:
        print(f"  Not done: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\n  Stopped.", file=sys.stderr)
        return 1
    except Exception as error:  # A traceback could show a local variable's value.
        print(f"  Not done: unexpected {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
