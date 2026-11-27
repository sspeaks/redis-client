"""Behavior of the merge classifier, through its command line."""

import importlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
LOW, EXTRA, MAINTAINER = "low-risk", "extra-evidence", "maintainer"
SOURCES = ("classify.py", "cabal_file.py", "haskell_api.py", "haskell_source.py")

CABAL = """cabal-version: 3.0
name: hask-redis-mux
version: 0.3.0.0

common defaults
    build-depends: base >=4.19 && <4.22

library
    import: defaults
    reexported-modules: Database.Redis.Resp
    build-depends: resp

library resp
    import: defaults
    hs-source-dirs: lib/resp
    exposed-modules: Database.Redis.Resp
                   , Database.Redis.Other
    build-depends: bytestring >=0.12 && <0.13

library cluster
    import: defaults
    hs-source-dirs: lib/cluster
    exposed-modules: Database.Redis.Cluster
    other-modules: Database.Redis.Hidden
    build-depends: resp

test-suite Spec
    type: exitcode-stdio-1.0
    main-is: Spec.hs
    other-modules: Suite.Api
    hs-source-dirs: test
    build-depends: hspec >=2.11
"""

RESP = """{-# LANGUAGE LambdaCase #-}
-- | Docs.
module Database.Redis.Resp
  ( Resp (..)
  , Opaque
  , Codec (..)
  , parse
  , (<+>)
  ) where

import Data.ByteString (ByteString)
import qualified Data.Map as M

data Resp = Simple ByteString | Number Int
  deriving (Eq, Show)

data Opaque = MkOpaque Int

class Codec a where
  encode :: a -> ByteString
  decode :: ByteString -> Maybe a
  decode _ = Nothing

instance Codec Resp where
  encode (Simple s) = s
  encode (Number _) = mempty

type Table = M.Map Int Resp

infixl 6 <+>
(<+>) :: Resp -> Resp -> Resp
a <+> _ = a

-- | Parse it.
parse :: ByteString -> Maybe Table
parse _ = Nothing

authCheck :: Int -> Int
authCheck x = x

helper :: Int -> Int
helper x = x
"""

FILES = {
    "hask-redis-mux/hask-redis-mux.cabal": CABAL,
    "hask-redis-mux/lib/resp/Database/Redis/Resp.hs": RESP,
    "hask-redis-mux/lib/resp/Database/Redis/Other.hs": "module Database.Redis.Other (other) where\n\nother :: Int\nother = 1\n",
    "hask-redis-mux/lib/cluster/Database/Redis/Cluster.hs": (
        "module Database.Redis.Cluster (module Database.Redis.Other, Alias, run) where\n\n"
        "import Database.Redis.Hidden\nimport Database.Redis.Other (other)\n\n"
        "run :: Secretive -> Int\nrun _ = other\n"
    ),
    "hask-redis-mux/lib/cluster/Database/Redis/Hidden.hs": (
        "module Database.Redis.Hidden (Alias, Secretive) where\n\n"
        "type Alias = Int\n\ntype Secretive = Bool\n"
    ),
    "hask-redis-mux/lib/client/Database/Redis/Client.hs": "module Database.Redis.Client () where\n",
    "hask-redis-mux/lib/redis/Database/Redis.hs": "module Database.Redis () where\n",
    "redis-client.cabal": "name: redis-client\nversion: 0.1\n\nexecutable redis-client\n    main-is: Main.hs\n    build-depends: base, hask-redis-mux\n\n"
    "executable E2E\n    main-is: E2E.hs\n    hs-source-dirs: test\n    other-modules: Helper\n",
    "app/Main.hs": "module Main (main) where\n\nmain :: IO ()\nmain = pure ()\n",
    "app/ClusterCli.hs": "module ClusterCli () where\n\nplain :: Int\nplain = 1\n\npassword :: Int\npassword = 1\n",
    "app/ClusterNodes.hs": "module ClusterNodes () where\n\nnodes :: Int\nnodes = 1\n",
    "app/Pure.hs": "module Pure () where\n\nplain :: Int\nplain = 1\n",
    "app/CredentialConfig.hs": "module CredentialConfig () where\n\nimport Support\n",
    "app/Support.hs": "module Support () where\n\nplain :: Int\nplain = 1\n",
    "app/Session.hs": "module Session () where\n\nimport Wrapper\n\nplain :: Int\nplain = 1\n",
    "app/Wrapper.hs": "module Wrapper () where\n\nimport Database.Redis.Connector (Connector)\n",
    "hask-redis-mux/test/Spec.hs": (
        "module Main (main) where\n\nimport qualified Suite.Api as Api\nimport Test.Hspec\n\n"
        "main :: IO ()\nmain = hspec $ do\n  Api.spec\n  it \"one\" $ do\n    1 `shouldBe` 1\n    2 `shouldBe` 2\n"
    ),
    "hask-redis-mux/test/Suite/Api.hs": "module Suite.Api (spec) where\n\nspec :: Int\nspec = 1\n",
    "test/E2E.hs": "main :: IO ()\nmain = pure ()\n",
    "test/Spec.hs": "main :: IO ()\nmain = pure ()\n",
    "README.md": "readme\n",
    "Makefile": "all:\n",
    "flake.lock": "{}\n",
    ".github/workflows/ci.yml": "on: push\n",
}


class ClassifierTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = tempfile.TemporaryDirectory()
        root = Path(cls.template.name)
        for path, text in FILES.items():
            (root / path).parent.mkdir(parents=True, exist_ok=True)
            (root / path).write_text(text, encoding="utf-8")
        (root / "scripts/factory").mkdir(parents=True)
        for name in SOURCES:
            shutil.copy(HERE / name, root / "scripts/factory" / name)
        cls.run_git(root, "init", "-q", "-b", "main")
        cls.run_git(root, "add", "-A")
        cls.run_git(root, "commit", "-qm", "base")

        # Most cases add a commit to the template and classify it in-process;
        # the copy in the template is loaded so that it is the base's own.
        names = [Path(name).stem for name in SOURCES]
        saved = {name: sys.modules.pop(name) for name in names if name in sys.modules}
        sys.path.insert(0, str(root / "scripts/factory"))
        try:
            cls.module = importlib.import_module("classify")
        finally:
            sys.path.pop(0)
            cls.loaded = {name: sys.modules.pop(name, None) for name in names}
            sys.modules.update(saved)
        cls.repository = cls.module.Repository(root)

    @classmethod
    def tearDownClass(cls):
        cls.template.cleanup()

    def setUp(self):
        self._root = None

    @property
    def root(self):
        """A private copy of the repository, for cases that change the base or need a checkout."""
        if self._root is None:
            directory = tempfile.TemporaryDirectory()
            self.addCleanup(directory.cleanup)
            self._root = Path(directory.name) / "repo"
            shutil.copytree(
                self.template.name, self._root, ignore=shutil.ignore_patterns("__pycache__")
            )
            self.run_git(self._root, "update-ref", "-d", "refs/heads/change")
        return self._root

    @property
    def script(self):
        return self.root / "scripts/factory/classify.py"

    def classify_in_template(self, edits):
        stream = [b"commit refs/heads/change\ncommitter t <t@example.invalid> 0 +0000\ndata 0\nfrom refs/heads/main^0\n"]
        for path, text in edits.items():
            quoted = '"' + "".join(
                chr(b) if 32 < b < 127 and b not in b'"\\' else f"\\{b:03o}" for b in path.encode()
            ) + '"'
            if text is None:
                stream.append(f"D {quoted}\n".encode())
            else:
                data = text.encode()
                stream.append(f"M 100644 inline {quoted}\ndata {len(data)}\n".encode() + data + b"\n")
        subprocess.run(
            ["git", "-C", self.template.name, "fast-import", "--quiet", "--force"],
            input=b"".join(stream), check=True, env=self.repository.environment,
        )
        return self.module.classify(self.repository, "main", "change")

    @staticmethod
    def run_git(root, *arguments):
        environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
        return subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false",
             "-C", str(root), *arguments],
            check=True, capture_output=True, text=True, env=environment,
        ).stdout

    def commit(self, edits, prepare=None):
        """Commit edits on a branch, then return to a checkout of the base."""
        self.run_git(self.root, "checkout", "-qb", "change")
        for path, text in edits.items():
            target = self.root / path
            if text is None:
                target.unlink()
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text, encoding="utf-8")
        if prepare:
            prepare()
        self.run_git(self.root, "add", "-A")
        self.run_git(self.root, "commit", "-qm", "change", "--allow-empty")
        self.run_git(self.root, "checkout", "-q", "main")

    def run_script(self, *arguments):
        result = subprocess.run(
            [sys.executable, str(self.script), *arguments], capture_output=True, text=True, check=True
        )
        return json.loads(result.stdout)

    def classify(self, edits, prepare=None):
        if edits and prepare is None and self._root is None:
            return self.classify_in_template(edits)
        self.commit(edits, prepare)
        return self.run_script("--base", "main", "--head", "change")

    def assert_class(self, expected, edits, api=None, prepare=None):
        result = self.classify(edits, prepare)
        self.assertEqual(result["class"], expected, result)
        if api:
            self.assertEqual(result["api"]["status"], api, result)
        return result

    def edit(self, name, old, new):
        path = next(p for p in FILES if p.endswith(name))
        self.assertEqual(FILES[path].count(old), 1)
        return {path: FILES[path].replace(old, new)}

    def test_the_tested_code_is_the_base_copy(self):
        for name, module in self.loaded.items():
            self.assertEqual(Path(module.__file__).parent, Path(self.template.name) / "scripts/factory", name)

    # Path classes

    def test_single_path_classes(self):
        for path, expected in {
            "test/New.hs": LOW,
            "hask-redis-mux/test/New.hs": LOW,
            "bench/New.hs": EXTRA,
            "hask-redis-mux/bench/New.hs": EXTRA,
            "docs/copilot_instructions.md": MAINTAINER,
            "docs/prompts/x.md": MAINTAINER,
            "docs/system-design.md": LOW,
            "docs/workflows.md": LOW,
            "docs/cursor.md": LOW,
            "docs/memory-policy.md": LOW,
            "docs/new.md": LOW,
            "README.md": LOW,
            "docs/AUTHENTICATION.md": LOW,
            ".out-of-scope/idea.md": LOW,
            "app/New.hs": LOW,
            "app/ClusterNodes.hs": EXTRA,
            "flake.lock": EXTRA,
            "hask-redis-mux/data/redis-command-metadata.json": EXTRA,
            "hask-redis-mux/lib/crc16/crc16.c": EXTRA,
            "hask-redis-mux/lib/client/Database/Redis/Client.hs": MAINTAINER,
            "app/CredentialConfig.hs": MAINTAINER,
            "test/AuthenticatedClusterE2E.hs": MAINTAINER,
            "hask-redis-mux/test/TLSConfigSpec.hs": MAINTAINER,
            "Makefile": MAINTAINER,
            "docker/Makefile": MAINTAINER,
            ".github/workflows/ci.yml": MAINTAINER,
            ".githooks/pre-commit": MAINTAINER,
            "scripts/new.py": MAINTAINER,
            "CLAUDE.md": MAINTAINER,
            "docs/AGENTS.md": MAINTAINER,
            "docs/.claude/settings.md": MAINTAINER,
            "docs/agents/domain.md": MAINTAINER,
            "docs/agents.md/x.md": MAINTAINER,
            "docs/factory_policy.md": MAINTAINER,
            "docs/x.instructions.md": MAINTAINER,
            "docs/.cursor/rules.md": MAINTAINER,
            "docs/.github/x.md": MAINTAINER,
            "docs/my-agent-notes.md": MAINTAINER,
            "docs/\uff21\uff27\uff25\uff2e\uff34\uff33.md": MAINTAINER,
            "docs/\u017fkill.md": MAINTAINER,
            "docs/a\tb.md": MAINTAINER,
            "docs/PROMPT.md": MAINTAINER,
            "test/..hs": MAINTAINER,
            "app/Main.hs": MAINTAINER,
            "app/AppConfig.hs": MAINTAINER,
            "docs/factory.md": MAINTAINER,
            "docs/adr/0001-x.md": MAINTAINER,
            "docs/release-process.md": MAINTAINER,
            "cabal.project": MAINTAINER,
            "flake.nix": MAINTAINER,
            "docker/x/docker-compose.yml": MAINTAINER,
            "mystery.bin": MAINTAINER,
            "test/data.bin": MAINTAINER,
            "test/New.hs\n.md": MAINTAINER,
            "hask-redis-mux/lib/extra/X.hs": MAINTAINER,
            "other.cabal": MAINTAINER,
        }.items():
            with self.subTest(path=path):
                self.setUp()
                text = "module X () where\n" if path.endswith(".hs") else "changed\n"
                if path.endswith(".cabal"):
                    text = "name: other\n"
                self.assert_class(expected, {path: text})

    def test_mixed_changes_take_the_strictest_class(self):
        samples = {
            LOW: {"docs/a.md": "a\n"},
            EXTRA: {"flake.lock": "{ }\n"},
            MAINTAINER: {"Makefile": "changed:\n"},
        }
        order = [LOW, EXTRA, MAINTAINER]
        for count in range(1, 8):
            chosen = [c for bit, c in enumerate(order) if count >> bit & 1]
            with self.subTest(classes=chosen):
                self.setUp()
                edits = {}
                for item in chosen:
                    edits.update(samples[item])
                self.assert_class(max(chosen, key=order.index), edits)

    def test_rename_out_of_a_controlled_path(self):
        edits = {"Makefile": None, "docs/makefile-notes.md": FILES["Makefile"]}
        self.assert_class(MAINTAINER, edits)

    def test_rename_into_a_controlled_path(self):
        self.assert_class(MAINTAINER, {"README.md": None, "scripts/readme.md": FILES["README.md"]})

    def test_rename_between_low_risk_paths(self):
        self.assert_class(LOW, {"README.md": None, "docs/readme.md": FILES["README.md"]})

    def test_rename_from_extra_evidence_path(self):
        self.assert_class(EXTRA, {"app/ClusterNodes.hs": None, "app/Cli.hs": "module Cli () where\n"})

    def test_deletions_use_the_deleted_path(self):
        for path, expected in {
            "test/Spec.hs": EXTRA,
            "hask-redis-mux/test/Spec.hs": MAINTAINER,
            "hask-redis-mux/test/Suite/Api.hs": MAINTAINER,
            "test/E2E.hs": MAINTAINER,
            "app/ClusterNodes.hs": EXTRA,
            ".github/workflows/ci.yml": MAINTAINER,
            "redis-client.cabal": MAINTAINER,
        }.items():
            with self.subTest(path=path):
                self.setUp()
                self.assert_class(expected, {path: None})

    def test_symlink_and_executable_are_unrecognized(self):
        def symlink():
            (self.root / "docs").mkdir()
            (self.root / "docs/link.md").symlink_to("/etc/hosts")

        self.assert_class(MAINTAINER, {}, prepare=symlink)
        self.setUp()
        self.assert_class(MAINTAINER, {}, prepare=lambda: (self.root / "README.md").chmod(0o755))

    def test_empty_change(self):
        self.assert_class(MAINTAINER, {})

    def test_unknown_commit(self):
        self.assertEqual(self.run_script("--base", "main", "--head", "missing")["class"], MAINTAINER)

    def test_changes_are_measured_from_the_merge_base(self):
        self.commit({"README.md": "changed\n"})
        (self.root / "Makefile").write_text("later:\n")
        self.run_git(self.root, "commit", "-qam", "later")
        self.assertEqual(self.run_script("--base", "main", "--head", "change")["class"], LOW)

    # Sensitive code

    def test_sensitive_declaration_outside_sensitive_paths(self):
        self.assert_class(MAINTAINER, self.edit("app/ClusterCli.hs", "password = 1", "password = 2"))

    def test_change_beside_a_sensitive_declaration(self):
        self.assert_class(EXTRA, self.edit("app/ClusterCli.hs", "plain = 1", "plain = 2"))

    # Package descriptions

    def test_cabal_changes(self):
        cases = {
            "new dependency": (("bytestring >=0.12 && <0.13", "bytestring >=0.12 && <0.13, evil"), MAINTAINER),
            "bounds": (("<0.13", "<0.14"), EXTRA),
            "test dependency promoted": (("build-depends: resp\n\ntest", "build-depends: resp, hspec\n\ntest"), MAINTAINER),
            "new test dependency": (("hspec >=2.11", "hspec >=2.11, evil"), MAINTAINER),
            "known test dependency": (("hspec >=2.11", "hspec >=2.11, bytestring"), LOW),
            "release": (("0.3.0.0", "0.4.0.0"), MAINTAINER),
            "unknown field": (("test\n    build", "test\n    cpp-options: -DX\n    build"), MAINTAINER),
            "library flags": (("hs-source-dirs: lib/resp", "hs-source-dirs: lib/resp\n    ghc-options: -O0"), MAINTAINER),
            "unparseable": (("library resp", "library resp {"), MAINTAINER),
        }
        for name, ((old, new), expected) in cases.items():
            with self.subTest(name):
                self.setUp()
                self.assert_class(expected, self.edit("mux.cabal", old, new))

    def test_new_test_suite(self):
        added = CABAL + "\ntest-suite More\n    type: exitcode-stdio-1.0\n    main-is: More.hs\n    build-depends: hspec\n"
        self.assert_class(EXTRA, {"hask-redis-mux/hask-redis-mux.cabal": added})
        self.assert_class(EXTRA, self.edit("mux.cabal", "test-suite Spec", (
            "test-suite New\n    type: exitcode-stdio-1.0\n    main-is: Spec.hs\n    hs-source-dirs: test\n\ntest-suite Spec"
        )))
        # Even without any field, and for every other runnable component.
        self.assert_class(EXTRA, self.edit("mux.cabal", "test-suite Spec", "test-suite New\n\ntest-suite Spec"))
        self.assert_class(EXTRA, self.edit("mux.cabal", "test-suite Spec", "benchmark New\n\ntest-suite Spec"))
        self.assert_class(MAINTAINER, self.edit("mux.cabal", "test-suite Spec", "executable New\n\ntest-suite Spec"))

    # Public API

    def test_internal_protocol_change_leaves_the_api_unchanged(self):
        for old, new in (
            ("parse _ = Nothing", "parse _ = Just mempty"),
            ("-- | Parse it.", "-- | Parse it well."),
            ("  decode _ = Nothing", "  decode x = const Nothing x"),
            ("MkOpaque Int", "MkOpaque Bool"),
            ("helper :: Int -> Int\nhelper x = x", "helper :: Bool -> Bool\nhelper x = x"),
            ("import qualified Data.Map as M", "import qualified Data.Map as M\nimport Data.List (sort)"),
        ):
            with self.subTest(new=new):
                self.setUp()
                self.assert_class(EXTRA, self.edit("Resp.hs", old, new), "unchanged")

    def test_compatible_additions(self):
        for old, new in (
            ("  , parse\n", "  , parse\n  , helper\n"),
            ("instance Codec Resp", "instance Monoid Resp\n\ninstance Codec Resp"),
        ):
            with self.subTest(new=new):
                self.setUp()
                self.assert_class(EXTRA, self.edit("Resp.hs", old, new), "compatible")

    def test_compatible_new_exposed_module(self):
        edits = self.edit("mux.cabal", ", Database.Redis.Other", ", Database.Redis.Other\n                   , Database.Redis.New")
        edits["hask-redis-mux/lib/resp/Database/Redis/New.hs"] = "module Database.Redis.New (x) where\nx :: Int\nx = 1\n"
        self.assert_class(EXTRA, edits, "compatible")

    def test_compatible_re_export_of_an_existing_module(self):
        self.assert_class(
            EXTRA,
            self.edit("mux.cabal", "reexported-modules: Database.Redis.Resp", "reexported-modules: Database.Redis.Resp, Database.Redis.Cluster"),
            "compatible",
        )

    def test_breaking_changes(self):
        for old, new in (
            ("  , parse\n", ""),
            ("parse :: ByteString -> Maybe Table", "parse :: ByteString -> Maybe Resp"),
            ("Number Int\n", "Number Int | Null\n"),
            ("Number Int\n", "Number Integer\n"),
            ("Resp (..)", "Resp"),
            ("deriving (Eq, Show)", "deriving (Show)"),
            ("  encode :: a -> ByteString", "  encode :: a -> ByteString\n  extra :: a -> Int"),
            ("  decode _ = Nothing\n", ""),
            ("instance Codec Resp where\n  encode (Simple s) = s\n  encode (Number _) = mempty\n", ""),
            ("type Table = M.Map Int Resp", "type Table = M.Map Integer Resp"),
            ("import qualified Data.Map as M", "import qualified Data.IntMap as M"),
            ("import Data.ByteString (ByteString)", "import Data.ByteString.Lazy (ByteString)"),
            ("infixl 6", "infixl 7"),
            ("LambdaCase", "LambdaCase, StrictData"),
            ("instance Codec Resp", "instance Show (Maybe Int)\n\ninstance Codec Resp"),
            ("data Opaque = MkOpaque Int", "data Opaque a = MkOpaque Int"),
        ):
            with self.subTest(old=old, new=new):
                self.setUp()
                self.assert_class(MAINTAINER, self.edit("Resp.hs", old, new), "breaking")

    def test_breaking_change_through_hidden_modules_and_re_exports(self):
        for name, old, new in (
            ("Hidden.hs", "type Alias = Int", "type Alias = Bool"),
            ("Hidden.hs", "Secretive = Bool", "Secretive = Int"),
            ("Other.hs", "other :: Int", "other :: Integer"),
            ("mux.cabal", "                   , Database.Redis.Other\n", ""),
            ("mux.cabal", "reexported-modules: Database.Redis.Resp\n", "reexported-modules:\n"),
        ):
            with self.subTest(name=name, new=new):
                self.setUp()
                result = self.classify(self.edit(name, old, new))
                self.assertEqual(result["class"], MAINTAINER)
                self.assertIn(result["api"]["status"], ("breaking", "failed"))

    def test_every_re_exporting_module_is_reported(self):
        result = self.classify(self.edit("Other.hs", "other :: Int", "other :: Integer"))
        self.assertEqual(
            {change["change"] for change in result["api"]["changes"]},
            {"changed Database.Redis.Other: other", "changed Database.Redis.Cluster: other"},
        )

    def test_failed_api_diff(self):
        for old, new in (
            ("import qualified Data.Map", "#if X\nimport qualified Data.Map"),
            ("helper :: Int", "makeLenses ''Resp\n\nhelper :: Int"),
            ("parse :: ByteString -> Maybe Table\n", ""),
            ("  ) where", "  where"),
            ("helper x = x", "helper x = [q|x|]"),
            ("helper x = x", "helper x = x; data Extra = Extra"),
            ("helper x = x", 'helper x = "unterminated'),
            ("helper :: Int", "type family F a\n\nhelper :: Int"),
            ("{-# LANGUAGE LambdaCase #-}", "{-# OPTIONS_GHC -F -pgmF evil #-}"),
            ("  , parse\n", "  , parse\n  , missing\n"),
        ):
            with self.subTest(new=new):
                self.setUp()
                self.assert_class(MAINTAINER, self.edit("Resp.hs", old, new), "failed")

    def test_missing_module_source_fails_the_api_diff(self):
        path = next(p for p in FILES if p.endswith("Other.hs"))
        self.assert_class(MAINTAINER, {path: None}, "failed")

    def test_build_time_code_needs_the_maintainer(self):
        for prefix in ("test/", "hask-redis-mux/test/", "bench/", "app/"):
            for text in (
                "{-# OPTIONS_GHC -F -pgmF evil #-}\nmodule New () where\n",
                "{-#options_ghc -Wall -F#-}\nmodule New () where\n",
                "{-# OPTIONS -cpp #-}\nmodule New () where\n",
                "{-# LANGUAGE CPP #-}\nmodule New () where\n",
                "{-# LANGUAGE {- #-} -} LambdaCase, TemplateHaskell #-}\nmodule New () where\n",
                "{-# LANGUAGE QuasiQuotes #-}\nmodule New () where\n",
                "module New () where\n{-# ANN module (1 :: Int) #-}\n",
                "module New () where\n{-# RULES \"x\" id = id #-}\n",
            ):
                with self.subTest(prefix=prefix, text=text):
                    self.setUp()
                    self.assert_class(MAINTAINER, {prefix + "New.hs": text})
        self.setUp()
        self.assert_class(LOW, {"test/New.hs": "{-# OPTIONS_GHC -Wno-orphans #-}\nmodule New () where\n"})

    def test_editing_a_file_that_already_runs_build_time_code(self):
        path = "test/New.hs"
        (self.root / path).write_text("{-# LANGUAGE CPP #-}\nmodule New () where\n")
        self.run_git(self.root, "add", "-A")
        self.run_git(self.root, "commit", "-qm", "base")
        self.assert_class(MAINTAINER, {path: "module New () where\n"})

    def test_app_modules_connected_to_credentials(self):
        for name, expected in {"Support": MAINTAINER, "Session": MAINTAINER, "Wrapper": MAINTAINER, "Pure": LOW}.items():
            with self.subTest(name):
                self.setUp()
                text = FILES[f"app/{name}.hs"] + "\nextra :: Int\nextra = 1\n"
                self.assert_class(expected, {f"app/{name}.hs": text})

    def test_gaining_or_losing_a_credential_connection(self):
        for edits in (
            {"app/Pure.hs": "module Pure () where\n\nimport Wrapper\n"},
            {"app/Pure.hs": "module Pure () where\n\nimport {- X -} safe qualified Network.Socket as N\n"},
            {"app/Session.hs": "module Session () where\n"},
        ):
            with self.subTest(edits):
                self.setUp()
                self.assert_class(MAINTAINER, edits)

    def test_app_code_with_outside_access(self):
        for code in (
            "import System.Process",
            "import System.Environment (getEnv)",
            "import System.Posix.Env",
            "import System.IO",
            "import System.Directory",
            "import Network.Socket",
            "import Foreign.C",
            "import GHC.IO.Handle",
            "import Data.Text.IO",
            "import Data.X509",
            "import Some.Unknown",
            "import System.IO.Unsafe",
            'foreign import ccall "getenv" g :: Int -> IO Int',
            'x = readFile "client.pem"',
            'x = BS.hGetLine y',
            "x = getContents",
            "x = skipVerify True",
            'x = send "AU\\84H"',
            'x = send "AU\\   \\TH"',
            "x = T.verifyPeer False",
            "x = print apiToken",
            'x = login "y"',
        ):
            with self.subTest(code):
                self.setUp()
                self.assert_class(MAINTAINER, {"app/Pure.hs": "module Pure () where\n\n" + code + "\n"})
        self.setUp()
        # Reached through another app module.
        edits = {
            "app/Files.hs": "module Files () where\nimport System.IO\n",
            "app/Pure.hs": "module Pure () where\nimport Files\n",
        }
        self.assert_class(MAINTAINER, edits)
        self.setUp()
        text = "module Pure () where\n\nimport Control.Monad (when)\nimport Data.IORef (newIORef)\nimport qualified Data.ByteString as BS\n"
        self.assert_class(LOW, {"app/Pure.hs": text})

    def test_harmless_mentions_are_not_build_time_code(self):
        for text in (
            "-- uses CPP, TemplateHaskell and {-# ANN #-} style\nmodule New () where\n",
            "{- {-# LANGUAGE CPP #-} -}\nmodule New () where\n",
            "{-# OPTIONS_GHC -O2 -Wall -Wno-orphans #-}\nmodule New () where\n",
        ):
            with self.subTest(text):
                self.setUp()
                self.assert_class(LOW, {"test/New.hs": text})
        for text in (
            "{-# LANGUAGE\n  LambdaCase\n  , TemplateHaskell\n#-}\nmodule New () where\n",
            "{-# OPTIONS_GHC -O2 -fplugin=Evil #-}\nmodule New () where\n",
            "--|{-# LANGUAGE CPP #-}\nmodule New () where\n",
            "--\u2192{-# LANGUAGE CPP #-}\nmodule New () where\n",
        ):
            with self.subTest(text):
                self.setUp()
                self.assert_class(MAINTAINER, {"test/New.hs": text})

    def test_standalone_deriving_is_not_compatible(self):
        self.assert_class(
            MAINTAINER, self.edit("Resp.hs", "data Opaque", "deriving instance Show Opaque\n\ndata Opaque"), "breaking"
        )

    def test_criss_cross_history(self):
        g = lambda *a: self.run_git(self.root, *a)
        g("checkout", "-qb", "a")
        (self.root / "Makefile").write_text("secure:\n")
        g("commit", "-qam", "a")
        g("checkout", "-q", "main")
        g("checkout", "-qb", "b")
        (self.root / "README.md").write_text("b\n")
        g("commit", "-qam", "b")
        g("checkout", "-q", "main")
        g("merge", "-q", "--no-ff", "a", "-m", "ma")
        g("merge", "-q", "--no-ff", "b", "-m", "mb")
        g("checkout", "-qb", "change", "b")
        g("merge", "-q", "-s", "ours", "a", "-m", "evil")
        (self.root / "README.md").write_text("later\n")
        g("commit", "-qam", "not a merge")
        g("checkout", "-q", "main")
        result = self.run_script("--base", "main", "--head", "change")
        self.assertEqual(result["class"], MAINTAINER)
        self.assertIn("no single merge base", [reason["reason"] for reason in result["reasons"]])

    def test_merge_commit_head(self):
        self.commit({"README.md": "changed\n"})
        self.run_git(self.root, "checkout", "-qb", "other")
        (self.root / "docs").mkdir()
        (self.root / "docs/a.md").write_text("a\n")
        self.run_git(self.root, "add", "-A")
        self.run_git(self.root, "commit", "-qm", "other")
        self.run_git(self.root, "checkout", "-q", "change")
        self.run_git(self.root, "merge", "-q", "--no-ff", "other", "-m", "merge")
        self.run_git(self.root, "checkout", "-q", "main")
        self.assertEqual(self.run_script("--base", "main", "--head", "change")["class"], MAINTAINER)

    def test_case_colliding_path(self):
        root, git = self.root, self.run_git
        blob = git(root, "rev-parse", "HEAD:README.md").strip()
        git(root, "checkout", "-qb", "change")
        git(root, "update-index", "--add", "--cacheinfo", f"100644,{blob},test/spec.hs")
        git(root, "commit", "-qm", "change")
        git(root, "checkout", "-qf", "main")
        self.assertEqual(self.run_script("--base", "main", "--head", "change")["class"], MAINTAINER)

    def test_conditional_modules(self):
        for old, new in (
            ("                   , Database.Redis.Other\n", "    if os(windows)\n        exposed-modules: Database.Redis.Other\n"),
            ("    reexported-modules: Database.Redis.Resp", "    if os(windows)\n        reexported-modules: Database.Redis.Resp"),
        ):
            with self.subTest(new):
                self.setUp()
                result = self.classify(self.edit("mux.cabal", old, new))
                self.assertEqual(result["class"], MAINTAINER)
                self.assertIn(result["api"]["status"], ("breaking", "failed"))

    def test_unclear_dependency_changes(self):
        bound = "bytestring >=0.12 && <0.13"
        for old, new in (
            (f"    build-depends: {bound}", f"    if os(windows)\n        build-depends: {bound}"),
            (bound, "bytestring"),
            (bound, "bytestring >=0.12"),
            (bound, "bytestring ==0.12.1"),
            (bound, "bytestring ==0.12.*"),
            (bound, "bytestring (>=0.12 && <0.13) || ==0.9"),
            (f"    build-depends: {bound}", f"    build-tool-depends: resp:resp\n    build-depends: {bound}"),
            ("hspec >=2.11", "hspec ==2.11"),
            ("hspec >=2.11", "hspec"),
            ("    build-depends: hspec", "    ghc-options: -F -pgmF evil\n    build-depends: hspec"),
            ("    build-depends: hspec", "    if os(windows)\n        main-is: Other.hs\n    build-depends: hspec"),
            ("name: hask", "x-y: 1\u2028name: hask"),
        ):
            with self.subTest(new):
                self.setUp()
                self.assert_class(MAINTAINER, self.edit("mux.cabal", old, new))

    def test_unicode_operator_is_not_a_comment(self):
        self.assert_class(MAINTAINER, self.edit("Resp.hs", "helper x = x", "helper x = x --\u2192 authPassword"), "failed")

    def test_semantic_changes_are_not_compatible(self):
        for old, new in (
            ("helper ::", "{-# RULES \"x\" forall a. parse a = Nothing #-}\nhelper ::"),
            ("helper ::", "{-# ANN helper (1 :: Int) #-}\nhelper ::"),
            ("import Data.ByteString (ByteString)", "import Data.ByteString (ByteString)\nimport Evil"),
            ("import Data.ByteString (ByteString)", "import Data.ByteString (ByteString)\nimport Evil ()"),
            ("import Data.ByteString (ByteString)", "import Data.ByteString (ByteString)\nimport Evil hiding (x)"),
            ("instance Codec Resp", "instance {-# OVERLAPPING #-} Codec Opaque where\n  encode _ = mempty\n\ninstance Codec Resp"),
            ("instance Codec Resp", "instance Codec a where\n  encode _ = mempty\n\ninstance Codec Resp"),
            ("instance Codec Resp", "instance Codec [Int] where\n\ninstance Codec [a] where\n\ninstance Codec Resp"),
        ):
            with self.subTest(new):
                self.setUp()
                result = self.classify(self.edit("Resp.hs", old, new))
                self.assertEqual(result["class"], MAINTAINER)
                self.assertIn(result["api"]["status"], ("breaking", "failed"))

    def test_specific_instance_under_an_existing_general_one(self):
        path = next(p for p in FILES if p.endswith("Resp.hs"))
        general = RESP + "\ninstance Codec [a] where\n  encode _ = mempty\n"
        (self.root / path).write_text(general)
        self.run_git(self.root, "commit", "-qam", "general")
        self.assert_class(MAINTAINER, {path: general + "\ninstance Codec [Int] where\n  encode _ = mempty\n"}, "breaking")

    # Tests as evidence

    def edit_spec(self, old, new):
        path = "hask-redis-mux/test/Spec.hs"
        self.assertEqual(FILES[path].count(old), 1)
        return {path: FILES[path].replace(old, new)}

    def test_additions_only_to_tests_stay_low_risk(self):
        for old, new in (
            ("main :: IO ()", "-- pending, xit and focus in a comment\nmain :: IO ()"),
            ("    2 `shouldBe` 2\n", "    2 `shouldBe` 2\n  it \"two\" $ do\n    let x = 3\n    x `shouldBe`\n      3\n"),
            ("    2 `shouldBe` 2\n", "    2 `shouldBe` 2\n\n  it \"two\" $ 3 `shouldSatisfy` (\\x -> x > 2)\n"),
            (
                "    2 `shouldBe` 2\n",
                "    2 `shouldBe` 2\n  describe \"more\" $ do\n    it \"a\" $ do\n      [1] `shouldContain` [1]\n"
                "    it \"b\" $ property $ \\x ->\n      x == (x :: Int)\n",
            ),
        ):
            with self.subTest(new):
                self.setUp()
                self.assert_class(LOW, self.edit_spec(old, new))
        self.setUp()
        self.assert_class(LOW, {"test/New.hs": "module New () where\n"})

    def test_weakened_tests_need_extra_evidence(self):
        for old, new in (
            ("    2 `shouldBe` 2\n", ""),
            ("    2 `shouldBe` 2\n", "    2 `shouldBe` 3\n"),
            ("    2 `shouldBe` 2\n", "    -- 2 `shouldBe` 2\n"),
            ("    1 `shouldBe` 1\n    2", "    {- 1 `shouldBe` 1 -}\n    2"),
            ("    1 `shouldBe` 1\n", "    pending\n    1 `shouldBe` 1\n"),
            ("    1 `shouldBe` 1\n", "    H.pendingWith \"later\"\n    1 `shouldBe` 1\n"),
            ('  it "one"', '  xit "two" $ pure ()\n  it "one"'),
            ('  it "one"', '  fit "two" $ pure ()\n  it "one"'),
            ('  it "one"', '  fdescribe "two" $ pure ()\n  it "one"'),
            ('  it "one"', '  focus $\n  it "one"'),
            ('  it "one"', '  when False $\n  it "one"'),
            ('  it "one"', '  runIO exitSuccess\n  it "one"'),
            ("main = hspec $ do\n", "main = hspec $ do\n  modifyArgs (const a)\n"),
            ("    2 `shouldBe` 2\n", "    2 `shouldBe` 2; 3 `shouldBe` 3\n"),
        ):
            with self.subTest(new):
                self.setUp()
                self.assert_class(EXTRA, self.edit_spec(old, new))
        self.setUp()
        self.assert_class(EXTRA, {"test/New.hs": "module New () where\n\nx :: Int\nx = focus 1\n"})

    def test_only_complete_new_test_blocks_are_low_risk_additions(self):
        block, first, main = '  it "one" $ do\n', "    1 `shouldBe` 1\n", "main :: IO ()\n"
        last, hspec = "    2 `shouldBe` 2\n", "main = hspec $ do\n"
        new = '  it "two" $ do\n    3 `shouldBe` 3\n'
        cases = [(last, last + addition) for addition in (
            "     `seq` pure ()\n",
            "      `orElse` pure ()\n",
            "    3 `shouldBe` 3\n",
            '   it "two" $ do\n    3 `shouldBe` 3\n',
            '  it "two" $ do\n',
            "  runIO (throwIO ExitSuccess)\n",
            '  it "two" $ do\n    exitSuccess `shouldReturn` ()\n',
            '  it "two" $ do\n    throwIO ExitSuccess\n    3 `shouldBe` 3\n',
            '  it "two" $ do\n    x <- evil\n    x `shouldBe` 3\n',
            '  it "two" $ do\n    unsafePerformIO evil `shouldBe` 3\n',
            '  it "two" $ do\n    3 `shouldBe` 3; evil\n',
            '  it "two" $ do\n    3 `shouldBe` 3\n   evil\n',
            '  it "two" $ do\n    let x = do evil\n    3 `shouldBe` 3\n',
            '  describe "two" $ do\n    runIO evil\n    it "a" $ do\n      3 `shouldBe` 3\n',
            '  describe "two" $ do\n    3 `shouldBe` 3\n',
            '  before_ evil $ it "two" $ do\n    3 `shouldBe` 3\n',
            '  it "two" $ do\n    3 `shouldBe` 3\n\nx :: Int\nx = 1\n',
            '  it "two" pending\n',
            '  it "two" $ 3 `myShould` 3\n',
            '  it "two" $ property $ ioProperty evil\n',
            '  prop "two" $ Q.monadicIO evil\n',
            '  prop "two" $ whenFail evil True\n',
        )]
        cases += [(block, wrapper + block) for wrapper in (
            "  replicateM_ 0 $\n", "  forM_ [] $ \\_ ->\n", "  around_ (const (pure ())) $\n",
            "  const (pure ()) $\n", "  mempty <$\n", "  parallel $\n", '  describe "x" $\n', new,
            '  describe "x" $ do\n',
        )]
        cases += [(first, row + first) for row in (
            "    return ()\n", "    throwIO ExitSuccess\n", "    throwIO (Pending Nothing Nothing)\n",
            "    let a `shouldBe` b = pure () :: IO ()\n", '  it "two" $ do\n    3 `shouldBe` 3\n',
            "    1  `shouldBe` 1\n",
        )]
        cases += [(main, row + main) for row in (
            "shouldBe :: a -> a -> IO ()\nshouldBe _ _ = pure ()\n\n", "it :: Int\nit = 1\n\n",
        )]
        cases += [
            ("1 `shouldBe` 1", "1  `shouldBe` 1"),
            (hspec, 'main = do\n  evil\n  hspec $ do\n'),
            ("module Main", "{-# LANGUAGE RebindableSyntax #-}\nmodule Main"),
            ("module Main", "{-# LANGUAGE LambdaCase #-}\nmodule Main"),
            ("module Main", "{-# OPTIONS_GHC -O0 #-}\nmodule Main"),
            ("import Test.Hspec\n", "import Data.List (sort)\nimport Test.Hspec\n"),
        ]
        for old, text in cases:
            with self.subTest(text):
                result = self.classify(self.edit_spec(old, text))
                self.assertNotEqual(result["class"], LOW, result)

    def test_added_tests_use_only_known_pure_names(self):
        """Operands and properties are allowlisted: operators, and where each name comes from."""
        path, last = "hask-redis-mux/test/Spec.hs", "    2 `shouldBe` 2\n"
        base = FILES[path].replace("import Test.Hspec\n", (
            "import qualified Data.ByteString as BS\nimport qualified Data.Map as M\nimport Data.List (sort)\n"
            "import qualified Data.Vector as V\nimport Database.Redis.Resp\nimport System.Environment (setEnv)\nimport System.Process\n"
            "import qualified System.IO as I\nimport Evil (length)\nimport Test.Hspec\nimport Test.QuickCheck\n"
        )) .replace("main :: IO ()\n", (
            "pureHelper :: Int -> Int\npureHelper x = x\n\nioHelper :: Int -> IO Int\nioHelper = pure\n\n"
            "untyped x = x\n\ntype Act = Int -> IO ()\n\ntype Deep = Act\n\nviaSynonym :: Int -> Deep\nviaSynonym = undefined\n\n"
            "viaMonad :: MonadX q => Int -> q Int\nviaMonad = undefined\n\nviaResult :: Run r => Int -> r\nviaResult = undefined\n\n"
            "viaImported :: Int -> Remote\nviaImported = undefined\n\nconstrained :: Ord a => a -> Int\nconstrained _ = 1\n\nreverse :: Int -> IO ()\nreverse _ = pure ()\n\nmain :: IO ()\n"
        ))
        root = self.root
        (root / path).write_text(base)
        other = "hask-redis-mux/test/Suite/Api.hs"
        (root / other).write_text(FILES[other] + "\ntype Remote = IO ()\n")
        self.run_git(root, "commit", "-qam", "imports")
        main = self.run_git(root, "rev-parse", "main").strip()
        repository = self.module.Repository(root)
        for expected, bodies in (
            (LOW, (
                "1 + 2 `shouldBe` 3",
                "pureHelper 1 `shouldBe` 1",
                "constrained 'a' `shouldBe` 1",
                "property $ (\\x -> x, 1) == (\\y -> y, 1)",
                "sort [2, 1] `shouldBe` [1, 2]",
                "M.lookup 1 (M.fromList [(1, 2)]) `shouldBe` Just 2",
                "M.empty M.! 1 `shouldBe` 2",
                "BS.length (BS.pack [1]) `shouldBe` (1 :: Int)",
                "parse \"x\" `shouldSatisfy` (\\r -> r == Nothing)",
                "(map negate . filter even $ [1]) `shouldBe` []",
                "property $ \\x y -> (x :: Int) + y == y + x",
                "property $ \\(a, _) -> forAll (elements [1]) $ \\b -> a == b ==> True",
            )),
            (EXTRA, (
                'writeFile "f" "x" >> 1 `shouldBe` 1',
                'setEnv "a" "b" *> 1 `shouldBe` 1',
                'property $ \\x -> callCommand "x" >> x `shouldBe` (1 :: Int)',
                'property $ callCommand "x"',
                'property $ setEnv "a" "b"',
                "putStrLn \"x\" `shouldBe` putStrLn \"x\"",
                "ioHelper 1 `seq` 1 `shouldBe` 1",
                "pureHelper (ioHelper 1) `shouldBe` 1",
                "untyped 1 `shouldBe` 1",
                "reverse 1 `shouldBe` 1",
                "length [1] `shouldBe` 1",
                "I.stdout `shouldBe` I.stdout",
                "BS.readFile \"x\" `shouldBe` BS.readFile \"x\"",
                "I.hPutStr I.stdout `shouldBe` 1",
                "unknown 1 `shouldBe` 1",
                "evil $ 1 `shouldBe` 1",
                "1 `shouldBe` 1 <* 2",
                "1 `shouldBe` (1 <$ 2)",
                "(1 =<< 2) `shouldBe` 1",
                "1 I.<+> 2 `shouldBe` 1",
                "1 `finally` 2 `shouldBe` 1",
                "(\\callCommand -> 1) (callCommand 1) `shouldBe` 1",
                "property $ \\(callCommand \"x\" -> y) -> True",
                "[1 | True] `shouldBe` [1]",
                "pure 1 `shouldBe` 1",
                'property $ snd (\\callCommand -> True, callCommand "touch MARK")',
                'property $ snd (\\q -> True, q 1)',
                "property $ [\\q -> True, q] == []",
                "property $ (\\q -> True) && q",
                "property $ \\pureHelper -> True",
                "property $ \\setEnv -> True",
                "property $ \\length -> True",
                "property $ \\negate -> True",
                "property $ \\exitSuccess -> True",
                "property $ \\putStrLn -> True",
                "do\n    let callCommand = 1\n        \n    let sort = 1\n    1 `shouldBe` 1",
                "viaSynonym 1 `shouldBe` 1",
                "viaMonad 1 `shouldBe` 1",
                "viaResult 1 `shouldBe` 1",
                "viaImported 1 `shouldBe` 1",
                "BS.putStr 1 `shouldBe` 1",
                "BS.useAsCString 1 2 `shouldBe` 1",
                "BS.packCString 1 `shouldBe` 1",
                "M.mapM_ 1 2 `shouldBe` 1",
                "V.forM_ 1 2 `shouldBe` 1",
                "do\n    [1\n    ] `shouldBe` [1]",
                "sequence_ [1] `shouldBe` 1",
                "mapM_ negate [1] `shouldBe` ()",
            )),
        ):
            for body in bodies:
                with self.subTest(body):
                    text = base.replace(last, last + '  it "two" $ ' + body + "\n")
                    (root / path).write_text(text)
                    self.run_git(root, "commit", "-qam", "change")
                    result = self.module.classify(repository, main, "HEAD")
                    self.assertEqual(result["class"], expected, result)
                    self.run_git(root, "reset", "-q", "--hard", main)

    def test_exit_and_pending_forms_in_new_files(self):
        for code in ("throwIO ExitSuccess", "throwIO (Pending Nothing Nothing)", "PENDING", "P.isPendingX"):
            with self.subTest(code):
                self.assert_class(EXTRA, {"test/New.hs": f"module New () where\n\nx :: Int\nx = {code}\n"})

    def test_removed_suite_wiring_needs_the_maintainer(self):
        for old, new in (
            ("  Api.spec\n", ""),
            ("  Api.spec\n", "  -- Api.spec\n"),
            ("import qualified Suite.Api as Api", "import qualified Suite.Other as Api"),
        ):
            with self.subTest(new):
                self.setUp()
                self.assert_class(MAINTAINER, self.edit_spec(old, new))

    def test_renamed_suite_file(self):
        path = "hask-redis-mux/test/Suite/Api.hs"
        self.assert_class(MAINTAINER, {path: None, "hask-redis-mux/test/Suite/New.hs": FILES[path]})

    def test_removed_suite_in_package_description(self):
        stanza = CABAL[CABAL.index("\ntest-suite"):]
        for old, new in (
            (stanza, ""),
            ("test-suite Spec", "benchmark Spec"),
            ("main-is: Spec.hs", "main-is: Noop.hs"),
            ("    other-modules: Suite.Api\n", ""),
            ("other-modules: Suite.Api", "other-modules: Suite.Other"),
            ("hs-source-dirs: test", "hs-source-dirs: bench, test"),
            ("type: exitcode-stdio-1.0", "type: detailed-0.9"),
            ("    type: exitcode", "    import: defaults\n    type: exitcode"),
        ):
            with self.subTest(new):
                self.setUp()
                self.assert_class(MAINTAINER, self.edit("mux.cabal", old, new))
        self.setUp()
        self.assert_class(LOW, self.edit("mux.cabal", "other-modules: Suite.Api", "other-modules: Suite.Api, Suite.New"))

    def test_dependency_dropped_from_a_test_suite(self):
        self.assert_class(EXTRA, self.edit("mux.cabal", "hspec >=2.11", "base"))

    def test_benchmark_component_needs_extra_evidence(self):
        added = CABAL + "\nbenchmark More\n    type: exitcode-stdio-1.0\n    main-is: More.hs\n    build-depends: hspec\n"
        self.assert_class(EXTRA, {"hask-redis-mux/hask-redis-mux.cabal": added})

    def test_end_to_end_executable_wiring(self):
        self.assert_class(MAINTAINER, self.edit("redis-client.cabal", "    other-modules: Helper\n", ""))

    def test_new_module_that_shadows_another(self):
        for path in (
            "hask-redis-mux/test/Test/Hspec.hs",
            "test/Test/Hspec.hs",
            "test/Prelude.hs",
            "hask-redis-mux/test/test/Hspec.hs",
            "test/Data/ByteString.hs",
            "app/Prelude.hs",
            "app/E2E.hs",
            "bench/Suite/Api.hs",
        ):
            with self.subTest(path):
                self.setUp()
                self.assert_class(MAINTAINER, {path: "module X () where\n"})

    # Trust

    def test_head_cannot_change_its_own_classification(self):
        edits = {"scripts/factory/classify.py": "print('{\"class\": \"low-risk\"}')\n"}
        self.assert_class(MAINTAINER, edits)

    def test_a_classifier_that_is_not_the_base_version_refuses(self):
        self.commit({"README.md": "changed\n"})
        for name in SOURCES:
            with self.subTest(name):
                target = self.root / "scripts/factory" / name
                original = target.read_text()
                target.write_text(original + "\n# tampered\n")
                self.assertEqual(self.run_script("--base", "main", "--head", "change")["class"], MAINTAINER)
                target.write_text(original)
        self.assertEqual(self.run_script("--base", "main", "--head", "change")["class"], LOW)


class WorkflowTest(unittest.TestCase):
    def test_workflow_runs_base_code_without_checking_out_the_head(self):
        text = (ROOT / ".github/workflows/factory-classify.yml").read_text()
        self.assertIn("pull_request_target:", text)
        self.assertNotIn("pull_request:", text)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", text)
        self.assertNotIn("ref: ${{ github.event.pull_request.head", text)
        self.assertNotIn("secrets.", text)
        self.assertNotIn("write", text)
        self.assertIn("persist-credentials: false", text)
        self.assertIn("types: [opened, synchronize, reopened, edited]", text)


class RealRepositoryTest(unittest.TestCase):
    """The checked-in libraries must stay readable, or every change needs the maintainer."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(HERE))
        import haskell_api

        package = ROOT / "hask-redis-mux"
        cls.api = haskell_api
        cls.cabal = (package / "hask-redis-mux.cabal").read_text()
        cls.package = package

    def read(self, path, overrides=None):
        if overrides and path in overrides:
            return overrides[path]
        target = ROOT / path
        return target.read_text() if target.is_file() else None

    def surface(self, overrides=None):
        return self.api.surface(self.cabal, "hask-redis-mux", lambda p: self.read(p, overrides))

    def test_every_exposed_module_has_a_surface(self):
        surface = self.surface()
        exposed = [k.split(" exposes ")[1] for k in surface if " exposes " in k]
        self.assertGreaterEqual(len(set(exposed)), 18)
        for module in exposed:
            exports = [k for k in surface if k.startswith(f"{module}: ") and not k.endswith(": extensions")]
            self.assertTrue(exports, module)

    def test_emptying_any_exposed_module_is_not_compatible(self):
        base = self.surface()
        sources = {
            ".".join(p.with_suffix("").parts[len((self.package / "lib").parts) + 1 :]): str(p.relative_to(ROOT))
            for p in (self.package / "lib").rglob("*.hs")
        }
        for module in {k.split(" exposes ")[1] for k in base if " exposes " in k}:
            with self.subTest(module):
                path = sources[module]
                pattern = rf"^module {re.escape(module)}\b.*?\)\s*where"
                text, count = re.subn(
                    pattern, f"module {module} () where", self.read(path), count=1, flags=re.DOTALL | re.MULTILINE
                )
                self.assertEqual(count, 1)
                try:
                    status, changes = self.api.compare(base, self.surface({path: text}))
                except self.api.ApiError:
                    continue
                self.assertEqual(status, "breaking")
                self.assertTrue(any(c["change"].startswith(f"removed {module}: ") for c in changes))


if __name__ == "__main__":
    unittest.main()
