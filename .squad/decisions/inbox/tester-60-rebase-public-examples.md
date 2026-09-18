# PR #178 reconciliation: typed public examples

- Preserve the breaking Either-only public contract from issue #60 in all README and Haddock runner examples after rebasing onto the public-example compile gate from PR #176.
- Keep each newly added error-handling and migration Haskell fence self-contained so it is compiled as a standalone consumer.
- Increase the exact package README fence count from six to eight, ensuring future public snippets cannot bypass the source-derived compilation check.
