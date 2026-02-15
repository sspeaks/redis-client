# 1. Executive Summary

## Overview

This document provides a comprehensive comparison between two Redis client libraries targeting different language ecosystems:

| | **hask-redis-mux** (Haskell) | **StackExchange.Redis** (C# / .NET) |
|---|---|---|
| **Language** | Haskell (GHC) | C# (.NET 6+) |
| **Repository** | [sspeaks/redis-client](https://github.com/sspeaks/redis-client) | [StackExchange/StackExchange.Redis](https://github.com/StackExchange/StackExchange.Redis) |
| **License** | MIT | MIT |
| **First Release** | 2024 | 2014 |
| **Architecture** | Multiplexed pipelining over RESP3 | Multiplexed pipelining over RESP2/RESP3 |
| **Cluster Support** | Yes — automatic MOVED/ASK redirection, topology discovery | Yes — automatic MOVED/ASK redirection |
| **TLS Support** | Yes — via `crypton` | Yes — via SslStream |
| **Package Manager** | Hackage (Cabal / Stack) | NuGet |

## Design Philosophy

**hask-redis-mux** embraces Haskell idioms: bracket-style resource management (`withStandaloneClient` / `withClusterClient`), typed responses via the `FromResp` typeclass, and FIFO-multiplexed pipelining that shares a single TCP connection across concurrent green threads. The library is intentionally minimal — it exposes the Redis command set through a clean typeclass (`RedisCommands`) and leaves application-level concerns (caching, retries, serialization) to the consumer.

**StackExchange.Redis** is the dominant .NET Redis client, battle-tested at Stack Overflow scale. It uses a similar multiplexed architecture but adds higher-level abstractions: automatic connection management via `ConnectionMultiplexer`, built-in profiling, Lua scripting helpers, and deep integration with the .NET async/await model. Its API surface is larger, covering Sentinel, Streams, and client-side caching.

## Key Differences at a Glance

| Aspect | hask-redis-mux | StackExchange.Redis |
|---|---|---|
| **Type Safety** | Compile-time via `FromResp` typeclass | Runtime via `RedisValue` / `RedisResult` casts |
| **Concurrency Model** | Green threads + FIFO multiplexer | .NET ThreadPool + async/await |
| **Resource Management** | Bracket pattern (exception-safe) | IDisposable / DI lifetime |
| **Pipelining** | Implicit (multiplexer batches automatically) | Explicit (`CreateBatch`) or fire-and-forget |
| **Connection Pooling** | Per-node pools (cluster), multiplexer count (standalone) | Single multiplexed connection (configurable) |
| **Pub/Sub** | Not yet implemented | Full support via `GetSubscriber()` |
| **Transactions** | Via CLIENT REPLY pipelining | Full MULTI/EXEC via `CreateTransaction` |
| **Lua Scripting** | Raw EVAL via `executeCommand` | `ScriptEvaluate` with prepared scripts |
| **Memory Overhead** | Low — GHC RTS with generational GC | Moderate — .NET GC with LOH considerations |
