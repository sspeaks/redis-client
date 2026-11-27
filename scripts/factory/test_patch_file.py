import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import patch_file
from patch_file import Rejected


def new_file(path="docs/a.md", lines=("text",), mode="100644"):
    content = "".join(f"{line}\n" for line in lines).encode()
    return (
        f"diff --git a/{path} b/{path}\nnew file mode {mode}\n"
        f"index 0000000..{patch_file.blob_id(content)[:7]}\n--- /dev/null\n+++ b/{path}\n"
        f"@@ -0,0 +1,{len(lines)} @@\n" + "".join(f"+{line}\n" for line in lines)
    ).encode()


def edit(path="docs/a.md", old=b"one\n", new=b"two\n"):
    def side(mark, content):
        return "".join(f"{mark}{line}\n" for line in content.decode().splitlines())

    return (
        f"diff --git a/{path} b/{path}\n"
        f"index {patch_file.blob_id(old)[:9]}..{patch_file.blob_id(new)[:9]} 100644\n"
        f"--- a/{path}\n+++ b/{path}\n"
        f"@@ -1,{old.count(10)} +1,{new.count(10)} @@\n" + side("-", old) + side("+", new)
    ).encode()


def rename(old, new, similarity="100%"):
    return (
        f"diff --git a/{old} b/{new}\nsimilarity index {similarity}\n"
        f"rename from {old}\nrename to {new}\n"
    ).encode()


class PatchCase(unittest.TestCase):
    def assertRejected(self, code, data):
        with self.assertRaises(Rejected) as caught:
            patch_file.parse(data)
        self.assertEqual(str(caught.exception), code)


class PathTest(PatchCase):
    def test_paths_outside_the_repository(self):
        for path in ("/etc/passwd", "../x", "a/../../x", "a/./b", "a//b", ".", "a/", "~/x", "a\\..\\b",
                     "C:/x", ".git/config", ".GIT/hooks/x", "sub/.git/config", ".git./config",
                     "git~1/config", ".gitmodules", "x/.GitModules", "a b", "a\tb", "x/..", "..."):  # fmt: skip
            with self.subTest(path):
                self.assertRejected("patch-path", new_file(path))

    def test_quoted_and_unicode_paths(self):
        for path in (".g\u0131thub/workflows/x.yml", "\uff0egithub/workflows/x.yml", "docs/caf\u00e9.md",
                     ".github\u200b/workflows/x.yml", ".git\u200c/x", "K\u212a.md"):  # fmt: skip
            with self.subTest(path):
                self.assertRejected("patch-path", new_file(path))
        quoted = new_file().replace(b"a/docs/a.md b/docs/a.md", b'"a/\\056github/x" "b/\\056github/x"')
        self.assertRejected("patch-path", quoted)

    def test_workflow_variants(self):
        for path in (".github/workflows/x.yml", ".GitHub/WORKFLOWS/x.yml", ".github/workflows",
                     ".github/workflows/deep/x", ".github/actions/x/run.sh", "tool/action.yml",
                     "Action.YAML", "x/.github/Workflows/y"):  # fmt: skip
            with self.subTest(path):
                self.assertRejected("patch-workflow", new_file(path))

    def test_renaming_a_workflow_in_or_out(self):
        self.assertRejected("patch-workflow", rename(".github/workflows/x.yml", "docs/x.yml"))
        self.assertRejected("patch-workflow", rename("docs/x.yml", ".github/Workflows/x.yml"))

    def test_the_header_must_name_the_file_that_is_written(self):
        data = new_file().replace(b"+++ b/docs/a.md", b"+++ b/.github/workflows/x.yml")
        self.assertRejected("patch-malformed", data)
        data = rename("docs/a.md", "docs/b.md").replace(b"rename to docs/b.md", b"rename to ../b.md")
        self.assertRejected("patch-malformed", data)

    def test_a_path_may_be_touched_only_once(self):
        self.assertRejected("patch-path-repeated", new_file() + new_file())
        self.assertRejected("patch-path-repeated", new_file("docs/a.md") + new_file("docs/A.md"))
        self.assertRejected("patch-path-repeated", rename("a", "b") + new_file("a"))

    def test_collisions_with_the_tree(self):
        tree = {"docs/a.md": ("100644", "0"), "LINK": ("120000", "0"), "sub": ("160000", "0")}
        for path, code in (
            ("docs/A.md", "patch-path-collision"),
            ("Docs/b.md", "patch-path-collision"),
            ("docs", "patch-path-collision"),
            ("docs/a.md/b", "patch-path-collision"),
            ("LINK/b", "patch-path-collision"),
            ("sub/b", "patch-path-collision"),
            ("docs/a.md", "patch-stale"),
        ):
            with self.subTest(path), self.assertRaisesRegex(Rejected, code):
                patch_file.check_paths(patch_file.parse(new_file(path)), tree)

    def test_links_and_submodules_already_in_the_tree_cannot_be_edited(self):
        for mode in ("120000", "160000"):
            with self.subTest(mode), self.assertRaisesRegex(Rejected, "patch-file-mode"):
                patch_file.check_paths(
                    patch_file.parse(edit()), {"docs/a.md": (mode, "0")}
                )
            with self.subTest(mode), self.assertRaisesRegex(Rejected, "patch-file-mode"):
                patch_file.check_paths(
                    patch_file.parse(rename("docs/a.md", "b")), {"docs/a.md": (mode, "0")}
                )


class ModeTest(PatchCase):
    def test_symlinks_submodules_and_odd_modes(self):
        for mode in ("120000", "160000", "100755", "100664", "040000", "104755", "1006440", " 100644", ""):
            with self.subTest(mode):
                self.assertRejected("patch-file-mode", new_file(mode=mode))
        self.assertRejected(
            "patch-file-mode", edit().replace(b" 100644\n", b" 120000\n")
        )
        deleted = new_file().replace(b"new file mode 100644", b"deleted file mode 160000")
        self.assertRejected("patch-file-mode", deleted)

    def test_mode_changes_alone_or_with_an_edit_or_rename(self):
        data = b"diff --git a/x b/x\nold mode 100644\nnew mode 100755\n"
        self.assertRejected("patch-mode-change", data)
        self.assertRejected("patch-mode-change", data + edit("x").split(b"\n", 1)[1])
        self.assertRejected("patch-mode-change", data + rename("x", "y").split(b"\n", 1)[1])
        self.assertRejected("patch-mode-change", b"diff --git a/x b/x\nnew mode 120000\n")

    def test_a_smuggled_second_header_is_malformed(self):
        data = new_file().replace(b"index 0", b"deleted file mode 100644\nindex 0")
        self.assertRejected("patch-malformed", data)
        data = new_file().replace(b"index 0", b"new file mode 120000\nindex 0")
        self.assertRejected("patch-malformed", data)
        self.assertRejected("patch-malformed", b"diff --git a/a b/b\ncopy from a\ncopy to b\n")


class FormTest(PatchCase):
    def test_binary(self):
        header = b"diff --git a/x b/x\nnew file mode 100644\nindex 0000000..1234567\n"
        self.assertRejected("patch-binary", header + b"Binary files /dev/null and b/x differ\n")
        self.assertRejected("patch-binary", header + b"GIT binary patch\nliteral 1\nIcmZPo000310RR91\n\n")
        self.assertRejected("patch-binary", new_file(lines=("a\0b",)))
        self.assertRejected("patch-not-utf8", new_file().replace(b"+text", b"+\xff\xfe"))

    def test_hidden_characters_in_added_lines(self):
        for character in ("\u202e", "\u200b", "\ufeff", "\r", "\x1b", "\u2028", "\ufe0f", "\U000e0041", "\u3164"):
            with self.subTest(repr(character)):
                self.assertRejected("patch-hidden-characters", new_file(lines=(f"a{character}b",)))

    def test_junk_anywhere(self):
        for data in (
            b"junk\n" + new_file(),
            new_file() + b"junk\n",
            new_file() + b"-- \n2.0\n",
            new_file().replace(b"index", b"GARBAGE\nindex"),
            b"From: x\n\n" + new_file(),
            b"\n",
        ):
            with self.subTest(data):
                self.assertRejected("patch-malformed", data)
        self.assertRejected("patch-empty", b"")

    def test_truncation(self):
        whole = new_file(lines=("one", "two", "three"))
        for length in range(1, len(whole)):
            with self.subTest(length), self.assertRaises(Rejected):
                changes = patch_file.parse(whole[:length])
                patch_file.apply(changes[0], None)

    def test_a_missing_last_hunk_is_caught_by_the_blob_id(self):
        old = b"".join(b"%d\n" % n for n in range(40))
        new = old.replace(b"\n2\n", b"\nX\n").replace(b"\n35\n", b"\nY\n")
        data = git_diff({"f": old}, {"f": new})
        cut = data[: data.rindex(b"@@ -")]
        self.assertEqual(patch_file.apply(patch_file.parse(data)[0], old), new)
        with self.assertRaisesRegex(Rejected, "patch-stale"):
            patch_file.apply(patch_file.parse(cut)[0], old)

    def test_lying_hunk_counts(self):
        for counts in (b"+1,0", b"+1,2", b"+1,99999999999", b"+1,-1", b"+1,\xd9\xa1"):
            with self.subTest(counts), self.assertRaises(Rejected):
                patch_file.parse(new_file().replace(b"+1,1", counts))
        with self.assertRaises(Rejected):
            patch_file.parse(new_file().replace(b"-0,0", b"-0,1"))

    def test_lying_hunk_positions(self):
        for header in (b"@@ -9,1 +9,1 @@", b"@@ -1,1 +2,1 @@", b"@@ -0,1 +1,1 @@"):
            data = edit().replace(b"@@ -1,1 +1,1 @@", header)
            with self.subTest(header), self.assertRaises(Rejected):
                patch_file.apply(patch_file.parse(data)[0], b"one\n")

    def test_another_version_of_the_file_is_stale(self):
        for base in (b"one\nmore\n", b"zero\n", b"", b"one"):
            with self.subTest(base), self.assertRaisesRegex(Rejected, "patch-stale"):
                patch_file.apply(patch_file.parse(edit())[0], base)

    def test_a_no_op_edit(self):
        data = edit(old=b"one\n", new=b"one\n")
        with self.assertRaisesRegex(Rejected, "patch-empty"):
            patch_file.apply(patch_file.parse(data)[0], b"one\n")


class CountTest(unittest.TestCase):
    def test_counts_both_sides(self):
        changes = patch_file.parse(edit(old=b"1\n2\n3\n", new=b"4\n5\n") + new_file("x", ("a", "b")))
        self.assertEqual(patch_file.changed_lines(changes), 7)

    def test_content_that_looks_like_headers_still_counts(self):
        lines = ("++ b/x", "-- a/x", "@@ -1 +1 @@", "diff --git a/x b/x")
        self.assertEqual(patch_file.changed_lines(patch_file.parse(new_file(lines=lines))), 4)

    def test_only_exact_generated_paths_are_exempt(self):
        (generated,) = patch_file.GENERATED
        self.assertEqual(patch_file.changed_lines(patch_file.parse(new_file(generated))), 0)
        for path in (generated.lower(), "x/" + generated, generated + ".hs"):
            self.assertEqual(patch_file.changed_lines(patch_file.parse(new_file(path))), 1)

    def test_renaming_into_or_out_of_a_generated_path_still_counts(self):
        (generated,) = patch_file.GENERATED
        body = edit("x").split(b"\n", 1)[1]
        for old, new in ((generated, "y.hs"), ("y.hs", generated)):
            hunk = body.replace(b"--- a/x", f"--- a/{old}".encode()).replace(
                b"+++ b/x", f"+++ b/{new}".encode()
            )
            changes = patch_file.parse(rename(old, new, "90%") + hunk)
            self.assertEqual(patch_file.changed_lines(changes), 2)


def git_diff(before, after):
    """A real `git diff`, as an independent source of patches."""
    with tempfile.TemporaryDirectory() as directory:
        def run(*arguments):
            return subprocess.run(
                ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                 "-c", "core.autocrlf=false", *arguments],
                cwd=directory, check=True, capture_output=True,
            ).stdout  # fmt: skip

        def write(files):
            for path, content in files.items():
                target = Path(directory, path)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(content)

        run("init", "-q")
        write(before)
        run("add", "-A", "-f")
        run("commit", "-q", "--allow-empty", "--no-verify", "-m", "base")
        for path in before:
            if path not in after:
                Path(directory, path).unlink()
        write(after)
        run("add", "-A", "-f")
        return run("diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-color",
                   "--src-prefix=a/", "--dst-prefix=b/", "HEAD")  # fmt: skip


class RealGitTest(unittest.TestCase):
    def check(self, before, after):
        changes = patch_file.parse(git_diff(before, after))
        patch_file.check_paths(changes, {path: ("100644", "0") for path in before})
        result = dict(before)
        contents = [(c, patch_file.apply(c, before.get(c.old))) for c in changes]
        for change in changes:
            if change.old is not None:
                del result[change.old]
        result.update({c.new: text for c, text in contents if c.new is not None})
        self.assertEqual(result, after)
        return changes

    def test_edits_creations_deletions_and_renames(self):
        long = b"".join(b"line %d\n" % n for n in range(50))
        self.check(
            {"a": long, "b": long[:100], "gone": b"x\ny\n", "old/name.hs": long, "empty": b""},
            {
                "a": long.replace(b"line 3\n", b"new\nnew\n").replace(b"line 44\n", b""),
                "b": long[:100] + b"more\n",
                "fresh/file": b"hello\n",
                "blank": b"",
                "new/name.hs": long.replace(b"line 9\n", b"LINE 9\n"),
            },
        )

    def test_missing_final_newlines(self):
        self.check({"a": b"x"}, {"a": b"x\n"})
        self.check({"a": b"x\n"}, {"a": b"x"})
        self.check({"a": b"x\ny"}, {"a": b"x\nz"})
        self.check({"a": b"x"}, {})
        self.check({}, {"a": b"x"})

    def test_lines_that_look_like_patch_syntax(self):
        self.check({"a": b"-- x\n@@ -1 +1 @@\n\\ q\n"}, {"a": b"++ x\ndiff --git a/a b/a\n\\ r\n"})

    def test_pure_rename(self):
        changes = self.check({"a": b"1\n2\n3\n"}, {"b": b"1\n2\n3\n"})
        self.assertEqual(patch_file.changed_lines(changes), 0)

    def test_empty_file_to_content_and_back(self):
        self.check({"a": b""}, {"a": b"x\n"})
        self.check({"a": b"x\n"}, {"a": b""})


if __name__ == "__main__":
    unittest.main()
