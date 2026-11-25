"""Turn an agent's workspace into a text patch without trusting anything in it.

The agent controls every file there, including .gitattributes, .gitignore and
git directories. So the host reads the files itself and hands git only bytes:
no work tree, attributes, filters, hooks or configuration from the workspace or
the host take part. Ignore rules come from the sources before the agent ran.
"""

import hashlib
import itertools
import os
import stat
import subprocess

MAX_FILE = 8 * 1024 * 1024
MAX_TOTAL = 128 * 1024 * 1024
MAX_ENTRIES = 50_000
MAX_CHANGES = 500
REGULAR, EXECUTABLE, SYMLINK = "100644", "100755", "120000"


class PatchRefused(Exception):
    pass


def blob_id(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data, usedforsecurity=False).hexdigest()


def is_text(data):
    try:
        return "\0" not in data.decode()
    except UnicodeDecodeError:
        return False


def read_file(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with open(descriptor, "rb") as stream:
        data = stream.read(MAX_FILE + 1)
    if len(data) > MAX_FILE:
        raise PatchRefused("a file is too large")
    return data


class Baseline:
    """The sources before the agent runs. Keep `directory` outside the workspace."""

    def __init__(self, directory, workspace):
        self.workspace = os.fspath(workspace)
        self.git_dir, self.ignore = f"{directory}/repository.git", f"{directory}/ignore"
        os.makedirs(self.ignore)
        subprocess.run(
            ["git", "init", "-q", "--bare", self.git_dir],
            check=True, env=self.environment(), capture_output=True,
        )  # fmt: skip
        subprocess.run(
            ["git", "init", "-q", self.ignore],
            check=True, env=self.environment(), capture_output=True,
        )  # fmt: skip
        if os.path.lexists(f"{self.workspace}/.git"):
            raise PatchRefused("the workspace must be exported sources without .git")
        self.files = {}
        self.files = self.snapshot()
        for path, (_, data) in self.files.items():
            if os.path.basename(path) == ".gitignore":
                target = f"{self.ignore}/{path}"
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "wb") as stream:
                    stream.write(data)
        self.tree = self.write_tree(self.files)

    def environment(self):
        return {
            "PATH": os.environ.get("PATH", os.defpath),
            "HOME": "/nonexistent",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_ATTR_NOSYSTEM": "1",
        }

    def git(self, *arguments, data=b""):
        return subprocess.run(
            ["git", f"--git-dir={self.git_dir}", *arguments],
            cwd=self.git_dir, env=self.environment(), input=data,
            check=True, capture_output=True,
        ).stdout  # fmt: skip

    def ignored(self, paths):
        done = subprocess.run(
            ["git", "check-ignore", "-z", "--stdin", "--no-index"],
            cwd=self.ignore, env=self.environment(), capture_output=True,
            input=b"".join(os.fsencode(path) + b"\0" for path in paths),
        )  # fmt: skip
        if done.returncode not in (0, 1):
            raise PatchRefused("ignore rules could not be applied")
        return {os.fsdecode(path) for path in done.stdout.split(b"\0") if path}

    def snapshot(self):
        """Every file that is tracked or not ignored, as path -> (mode, bytes)."""
        files, total, seen, level = {}, 0, 0, [""]
        while level:
            entries, directories = {}, []
            for parent in level:
                with os.scandir(f"{self.workspace}/{parent}") as listing:
                    found = list(itertools.islice(listing, MAX_ENTRIES + 1))
                for entry in found:
                    if parent == "" and entry.name == ".git":
                        continue  # The container's own repository.
                    seen += 1
                    if seen > MAX_ENTRIES:
                        raise PatchRefused("too many files")
                    path = f"{parent}{entry.name}"
                    if not path.isprintable() or "\\" in path or '"' in path:
                        raise PatchRefused("a file name is not plain text")
                    entries[path] = entry.stat(follow_symlinks=False).st_mode
            for path, mode in entries.items():
                if stat.S_ISDIR(mode):
                    os.makedirs(f"{self.ignore}/{path}", exist_ok=True)
            ignored = self.ignored(entries)
            for path, mode in entries.items():
                if stat.S_ISDIR(mode):
                    tracked = any(name.startswith(f"{path}/") for name in self.files)
                    if path in ignored and not tracked:
                        continue
                elif path in ignored and path not in self.files:
                    continue
                if os.path.basename(path).casefold() == ".git":
                    raise PatchRefused("the workspace contains another repository")
                if stat.S_ISDIR(mode):
                    directories.append(f"{path}/")
                elif stat.S_ISLNK(mode):
                    target = os.fsencode(os.readlink(f"{self.workspace}/{path}"))
                    files[path] = SYMLINK, target
                elif stat.S_ISREG(mode):
                    data = read_file(f"{self.workspace}/{path}")
                    total += len(data)
                    if total > MAX_TOTAL:
                        raise PatchRefused("the files are too large together")
                    files[path] = (EXECUTABLE if mode & 0o100 else REGULAR), data
                else:
                    raise PatchRefused("the workspace contains a special file")
            level = directories
        return files

    def write_tree(self, files):
        self.git("read-tree", "--empty")
        index = b""
        for path, (mode, data) in sorted(files.items()):
            blob = blob_id(data)
            if self.files.get(path) != (mode, data) or files is self.files:
                self.git("hash-object", "-w", "--no-filters", "--stdin", data=data)
            index += f"{mode} {blob}\t".encode() + os.fsencode(path) + b"\0"
        self.git("update-index", "-z", "--index-info", data=index)
        return self.git("write-tree").strip().decode()

    def patch(self):
        """Return the patch as bytes, or raise PatchRefused."""
        try:
            files = self.snapshot()
            changed = [
                path
                for path in self.files.keys() | files.keys()
                if self.files.get(path) != files.get(path)
            ]
            if len(changed) > MAX_CHANGES:
                raise PatchRefused("too many changed files")
            for path in changed:
                for mode, data in filter(None, (self.files.get(path), files.get(path))):
                    if mode == SYMLINK:
                        raise PatchRefused("the patch adds or changes a symbolic link")
                    if not is_text(data):
                        raise PatchRefused("the patch adds or changes a binary file")
            return self.git(
                "diff-tree", "-p", "--no-color", "--no-ext-diff", "--no-textconv",
                "--no-renames", "--full-index", self.tree, self.write_tree(files),
            )  # fmt: skip
        except (OSError, RecursionError, subprocess.CalledProcessError) as error:
            raise PatchRefused(f"the workspace could not be read: {type(error).__name__}") from None
