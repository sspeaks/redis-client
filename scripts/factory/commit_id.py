"""A full Git commit id, as GitHub and `git rev-parse` print it: 40 lower-case hex digits.

PATTERN                regular expression text, for building larger patterns
is_commit_id(value) -> True only for a str that is exactly one commit id
"""

import re

PATTERN = "[0-9a-f]{40}"
_FULL = re.compile(PATTERN)


def is_commit_id(value):
    return isinstance(value, str) and _FULL.fullmatch(value) is not None
