# 7. Developer Experience

## Build Systems & Tooling

| Aspect | hask-redis-mux | StackExchange.Redis |
|---|---|---|
| **Build Tool** | Cabal (or Stack); Nix for reproducible builds | dotnet CLI / MSBuild |
| **Package Manager** | Hackage (Cabal) | NuGet |
| **Dependency Resolution** | Cabal solver; Nix pins exact versions | NuGet automatic resolution |
| **Build Speed** | Slower initial build (GHC compilation); fast incremental | Fast builds; incremental by default |
| **IDE Support** | HLS (Haskell Language Server) for VS Code, Neovim | Excellent — Visual Studio, Rider, VS Code (OmniSharp) |
| **REPL** | GHCi for interactive testing | dotnet script / C# Interactive |

## Documentation

| Aspect | hask-redis-mux | StackExchange.Redis |
|---|---|---|
| **API Docs** | Haddock-generated on Hackage | XML docs on NuGet; extensive GitHub wiki |
| **Examples** | README quick-start; growing | Extensive wiki, blog posts, Stack Overflow |
| **Type Signatures** | Self-documenting via Haskell type system | Requires reading XML comments |
| **Tutorials** | Limited (newer library) | Abundant (10+ years of community content) |

## Community & Ecosystem

| Aspect | hask-redis-mux | StackExchange.Redis |
|---|---|---|
| **Maturity** | New (2024); actively developed | Mature (2014); production-proven at Stack Overflow |
| **Contributors** | Small team | Large open-source community |
| **Issues / Support** | GitHub issues | GitHub issues + Stack Overflow tags |
| **Production Users** | Growing | Stack Overflow, Microsoft, thousands of .NET shops |
| **Alternative Libraries** | `hedis` (established Haskell Redis client) | `ServiceStack.Redis`, `FreeRedis` |

## Error Messages & Debugging

### hask-redis-mux

- **Type errors** caught at compile time — wrong return types fail to build
- **Runtime errors** via `MultiplexerException` variants: `Dead`, `ParseError`, `ConnectionClosed`
- **GHC profiling** via `+RTS -s -p` for memory and time profiling
- **Debug output** — can inspect raw RESP frames for protocol debugging

### StackExchange.Redis

- **Runtime errors** via `RedisConnectionException`, `RedisTimeoutException`, `RedisServerException`
- **Event hooks** — `ConnectionMultiplexer.InternalError`, `ConnectionFailed`, `ConnectionRestored`
- **Built-in profiling** — `ProfilingSession` tracks command timing per logical operation
- **.NET diagnostics** — integrates with `DiagnosticSource` and OpenTelemetry
- **Detailed logging** — `TextWriter` logging for connection management internals

> **Verdict:** StackExchange.Redis offers a more polished developer experience with extensive documentation, mature tooling, and built-in diagnostics. hask-redis-mux compensates with stronger compile-time guarantees and Haskell's type system, which catches entire categories of errors before runtime.
