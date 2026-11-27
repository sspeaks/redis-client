"""Rules over .github/workflows that gate.py's run records depend on.

The gate ignores runs outsiders can start, and reads only factory-*.yml runs, so
a factory job must not hide in either place. There is no YAML parser in the
standard library, so anything but one plain spelling is refused.
"""

import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import gate

ROOT = Path(__file__).parents[2] / ".github/workflows"
WRITER_EVENTS = {"workflow_call", "workflow_dispatch", "schedule", "push"}
TOP_LEVEL = re.compile(r"name: [A-Z][A-Za-z -]*|on:|permissions: \{\}|permissions:|concurrency:|jobs:")
EVENT = re.compile(r"  ([a-z_]+):")
# Below an event: a plain key or list item, with a value that ends on its line.
PLAIN = r"[A-Za-z0-9$][^\"#&*|>\\]*"
VALUE = rf'(?:{PLAIN}|"[^"\\]*"|\[(?: ?"?[\w*./-]+"?,?)* ?\])'
DETAIL = re.compile(rf"    +(?:(?:- )?[\w-]+:(?: {VALUE})?|- {VALUE})")

# Every line of factory-classify.yml but comments, with the action's pin removed.
CLASSIFY = '''\
name: Factory merge class
on:
  pull_request_target:
    branches: [ "main" ]
    types: [opened, synchronize, reopened, edited]
permissions:
  contents: read
concurrency:
  group: factory-classify-${{ github.event.pull_request.number }}
  cancel-in-progress: true
jobs:
  classify:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    outputs:
      class: ${{ steps.classify.outputs.class }}
    steps:
    - uses: actions/checkout@PIN
      with:
        ref: ${{ github.event.pull_request.base.sha }}
        fetch-depth: 0
        persist-credentials: false
    - name: Classify
      id: classify
      env:
        BASE_SHA: ${{ github.event.pull_request.base.sha }}
        HEAD_SHA: ${{ github.event.pull_request.head.sha }}
        NUMBER: ${{ github.event.pull_request.number }}
      run: |
        set -euo pipefail
        git fetch --no-tags origin "refs/pull/${NUMBER}/head"
        python3 scripts/factory/classify.py --base "$BASE_SHA" --head "$HEAD_SHA" > "$RUNNER_TEMP/class.json"
        class="$(jq -er .class "$RUNNER_TEMP/class.json")"
        echo "class=$class" >> "$GITHUB_OUTPUT"
        { echo "Merge class: **$class**"; echo; sed 's/^/    /' "$RUNNER_TEMP/class.json"; } >> "$GITHUB_STEP_SUMMARY"
'''
# The exact text of each workflow in gate.OUTSIDER_RUNS.
OUTSIDER_TEXT = {"factory-classify.yml": CLASSIFY}


def normalized(text):
    lines = (line for line in text.split("\n") if line.strip() and not line.lstrip().startswith("#"))
    return "".join(
        re.sub(r"(actions/checkout)@[0-9a-f]{40} # v\d+$", r"\1@PIN", line) + "\n"
        for line in lines
    )


def workflow_errors(files):
    """Errors in {file name: text} for a whole workflows directory."""
    errors = []
    outsiders = set()
    for name, text in sorted(files.items()):
        if re.search(r"[^\n -~]", text):
            errors.append(f"{name}: only printable ASCII and newlines are allowed")
        elif name.startswith("factory-"):
            errors.extend(f"{name}: {error}" for error in _factory_errors(name, text, outsiders))
        else:
            errors.extend(f"{name}: {error}" for error in _other_errors(name, text))
    if outsiders != gate.OUTSIDER_RUNS:
        errors.append("gate.OUTSIDER_RUNS does not match the workflows' outside triggers")
    return errors


def _factory_errors(name, text, outsiders):
    if not re.fullmatch(r"factory-[a-z-]+\.yml", name):
        yield "use a plain lower-case name ending in .yml"
    lines = [line for line in text.split("\n") if line.strip() and not line.lstrip().startswith("#")]
    tops = [line for line in lines if not line.startswith(" ")]
    for line in tops:
        if not TOP_LEVEL.fullmatch(line):
            yield f"unexpected top-level line {line!r}"
    keys = [line.partition(":")[0] for line in tops]
    if len(keys) != len(set(keys)) or "on" not in keys:
        yield "top-level keys must be unique and include on"
    if not {"name", "on"} <= set(keys) or lines.index(tops[0]) != 0:
        yield "must start with name and have on"
        return
    start = lines.index("on:") + 1 if "on:" in lines else len(lines)
    events = []
    for line in lines[start:]:
        if not line.startswith(" "):
            break
        event = EVENT.fullmatch(line)
        if event:
            events.append(event[1])
        elif not events or not DETAIL.fullmatch(line):
            yield f"on: line is not plain: {line!r}"
    if not events or len(events) != len(set(events)):
        yield "on: must list each event once"
    for event in events:
        if event not in WRITER_EVENTS:
            outsiders.add((f".github/workflows/{name}", event))
            if normalized(text) != OUTSIDER_TEXT.get(name):
                yield f"open to outsiders through {event}, but is not the exact reviewed text"


def _other_errors(name, text):
    if name.casefold().startswith("factory"):
        yield "factory workflows are named factory-*.yml, in lower case"
    # Joining escaped line breaks and folded lines, so a name cannot be split.
    joined = re.sub(r"\\?\n\s*", "", text)
    for form in (text, joined, re.sub(r"[\s\"'\\]+", "", text)):
        if "factory-" in form.casefold():
            yield "refers to the factory; only factory-*.yml may"
            break
    if re.search(r"\\(?:[xuU][0-9A-Fa-f]{2}|N\{)", text):
        yield "escaped characters could hide a name"
    if re.search(r"(?m)(?:^|[\s{,\"'])(?:name|uses)[\"']?\s*:.*(?:\$\{\{|[&*][A-Za-z])", text):
        yield "a computed or aliased name could hide a factory name"


class WorkflowRuleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files = {
            path.name: path.read_bytes().decode("utf-8") for path in ROOT.iterdir() if path.is_file()
        }

    def assertRejected(self, name, text):
        with self.subTest(name=name, text=text[:80]):
            errors = workflow_errors({**self.files, name: text})
            self.assertTrue(any(error.startswith(f"{name}: ") for error in errors), errors)

    def edited(self, name, old, new):
        self.assertIn(old, self.files[name])
        return self.files[name].replace(old, new, 1)

    def test_this_repository_follows_the_rules(self):
        self.assertEqual(workflow_errors(self.files), [])

    def test_plain_factory_workflow_is_accepted(self):
        text = ("name: Factory work\n\non:\n  schedule:\n    - cron: \"0 10 * * *\"\n"
                "  workflow_dispatch:\n\npermissions: {}\n\njobs:\n  a:\n"
                "    name: factory-agent-work\n")
        self.assertEqual(workflow_errors({**self.files, "factory-work.yml": text}), [])

    def test_outside_triggers_cannot_hide(self):
        for on in (
                "on:\n  issues:\n", "on: issues\n", "on: [push, issues]\n", "on: {issues: {}}\n",
                '"on":\n  issues:\n', "'on':\n  issues:\n", "on :\n  issues:\n",
                "? on\n: issues\n", "!!str on:\n  issues:\n", '"o\\x6e":\n  issues:\n',
                "on: &a\n  issues:\n", "on: *a\n", "on:\n  <<: *a\n  push:\n",
                'on:\n  push:\n  "issues":\n', "on:\n  push:\n  'issues':\n",
                "on:\n  push:\n  issues :\n", "on:\n  push:\n  ? issues\n",
                'on:\n  push:\n  "iss\\x75es":\n', "on:\n  push: {}\n  issues: {}\n",
                "on:\n   push:\n   issues:\n", "on:\n push:\n issues:\n",
                "on:\n    push:\n    issues:\n", "on:\n  push:\n  issues: &x\n",
                "on:\n  push:\n  !!str issues:\n", "on:\n  - push\n  - issues\n",
                "on:\n  push:\non:\n  issues:\n", 'on:\n  push:\n"on":\n  issues:\n',
                "env:\n  X: |\non:\n  push:\n", "on:\n  push:\n    x: |\n      y\n  issues:\n",
                "on:\n  push:\n    x: \"a\n  b\": c\n", "on:\n  push:\n    x: *a\n",
                "on:\n  push:\n    <<: *a\n", "on:\n  push:\r\n  issues:\n",
                "on:\n  push:\u2028  issues:\n", "on:\n\tissues:\n", "on:\n", "",
                "---\non:\n  push:\n", "on:\n  push:\n...\n---\non:\n  issues:\n"):
            self.assertRejected("factory-x.yml", f"name: Factory x\n\n{on}\njobs:\n  a:\n")
        self.assertRejected("factory-x.yml", "on:\n  push:\n\njobs:\n  a:\n")
        self.assertRejected("factory-x.yml", "name: |\n  a\non:\n  push:\n\njobs:\n  a:\n")
        self.assertRejected("factory-x.yml", "")

    def test_factory_names_are_plain(self):
        for name in ("factory-X.yml", "factory-x.yaml", "factory-x.YML", "Factory-x.yml",
                     "FACTORY-x.yml", "factory_x.yml"):
            self.assertRejected(name, "name: Factory x\n\non:\n  push:\n\njobs:\n  a:\n")

    def test_classify_must_match_the_reviewed_text(self):
        name = "factory-classify.yml"
        for old, new in (
                ("types: [opened,", "types: [closed, opened,"),
                ("  pull_request_target:", '  "pull_request_target":'),
                ("permissions:\n  contents: read", "permissions:\n  contents: write"),
                ("permissions:\n  contents: read", "permissions: write-all"),
                ("cancel-in-progress: true", "cancel-in-progress: false"),
                ("pull_request.number }}\n  cancel", "run_id }}\n  cancel"),
                ("  classify:\n", "  classify:\n    name: factory-pause\n"),
                ("  classify:\n", '  classify:\n    "name": "factory\\x2dagent"\n'),
                ("jobs:\n", "jobs:\n  x:\n    uses: ./.github/workflows/factory-pause.yml\n"),
                ("jobs:\n", "jobs:\n  factory-agent:\n    runs-on: ubuntu-latest\n"),
                ("    timeout-minutes: 10", "    environment: factory-publish\n    timeout-minutes: 10"),
                ("    - name: Classify", "    - name: factory-pause-failed"),
                ("        NUMBER:", "        TOKEN: ${{ secrets.X }}\n        NUMBER:"),
                ("actions/checkout@", "evil/checkout@"),
                ("  pull_request_target:", "  issues:\n  pull_request_target:")):
            self.assertRejected(name, self.edited(name, old, new))

    def test_classify_comments_and_pins_may_change(self):
        name = "factory-classify.yml"
        text = "# Note\n" + re.sub(r"@[0-9a-f]{40} # v\d+", "@" + "a" * 40 + " # v9", self.files[name])
        self.assertEqual(workflow_errors({**self.files, name: text}), [])

    def test_removed_outsider_workflow_must_leave_the_gate_list(self):
        files = {k: v for k, v in self.files.items() if k != "factory-classify.yml"}
        self.assertTrue(workflow_errors(files))

    def test_other_workflows_cannot_call_or_imitate_the_factory(self):
        for body in (
                "    uses: ./.github/workflows/factory-pause.yml",
                "    uses: sspeaks/redis-client/.github/workflows/factory-publish.yml@main",
                "    uses: './.github/workflows/Factory-pause.yml'",
                '    "uses": ./.github/workflows/factory-pause.yml',
                "    uses: >-\n      ./.github/workflows/fac\n      tory-pause.yml",
                '    uses: "./.github/workflows/fac\\\n      tory-pause.yml"',
                '    uses: "./.github/workflows/\\x66actory-pause.yml"',
                '    uses: "./.github/workflows/\\u0066actory-pause.yml"',
                "    uses: &x a\n    other: 1", "    uses: *x", "    uses: ${{ vars.X }}",
                "    name: factory-agent-x", "    name: 'factory-pause'", "    name: Factory-Agent",
                '    "name": "factory\\x2dpause"', "    name : factory-pause",
                "    {name: factory-agent}", "    name: ${{ format('{0}-agent', 'factory') }}",
                '    "name" : ${{ matrix.x }}', "    name: *x",
                "    steps:\n    - name: factory-agent-run", "    steps:\n    - name: factory-usage-limit",
                "    steps:\n    - {name: factory-pause-failed}", "    steps:\n    - name: ${{ vars.X }}"):
            for name in ("other.yml", "other.yaml", "Other.yml"):
                self.assertRejected(name, f"name: Other\non:\n  push:\njobs:\n  a:\n{body}\n")
        self.assertRejected("other.yml", "name: Other\non:\n  push:\njobs:\n  factory-agent:\n")
        self.assertRejected("runTests.yml", self.edited(
            "runTests.yml", "  build:\n", "  factory-pause:\n"))

    def test_ordinary_other_workflow_is_accepted(self):
        text = "name: Other\non:\n  issues:\njobs:\n  a:\n    name: Build * things\n"
        self.assertEqual(workflow_errors({**self.files, "other.yml": text}), [])


if __name__ == "__main__":
    unittest.main()
