Work in this repository, which builds with Nix. Run commands as `nix-shell --run '...'`.

1. Run `cabal build hask-redis-mux` inside the Nix shell. The first run downloads the toolchain and can take several minutes.
2. Write the output of `ghc --print-libdir`, run inside the same Nix shell, to `factory-proof.txt` at the repository root. The file must hold that one line and nothing else.

Change no other tracked file. Do not commit.
