---
applyTo: '**'
---
This project is build with nixpkgs. If vscode is not started with nix-shell then the dependencies might not be in path.

DO NOT DO ANYTHING WITHOUT READING AND ABIDING BY THE BELOW ACTIONS
Actions:
  - It's expected that you profile before you make changes and after you make changes with `cabal run --enable-profiling -- {flags}`. These 2 profiles should be compared and serious regressions must be addressed. Prefer using just -p for RTS flags because its easiest to compare.
  - If redis isnt running locally, start it up with docker
  - Also if you're running in fill mode, always use the `-f` flag in case the redis instance is running locally in docker so we dont consume too much ram.
  - It's also expected that you run `cabal test` and `./rune2eTests.sh` whenever you're doen making changes.
  - Remove any profiling artifacts once you're done.