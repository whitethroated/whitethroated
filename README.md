# Hudhud

Hudhud is an experimental high-performance web framework written in Swift.

The project has two non-negotiable goals:

1. An ergonomic developer experience inspired by Express.js.
2. A low-overhead runtime architecture designed to push Swift server performance as far as practical.

Hudhud is currently pre-alpha. The first milestone focuses on a small HTTP/1.1 core, routing, middleware, request/response primitives, tests, and reproducible benchmarks.

## Design principles

- Swift-first API.
- SwiftNIO event loops as the transport foundation.
- No `Task` creation on the default request hot path.
- Minimal abstraction between the socket and the route handler.
- Route tables are compiled during application setup and treated as read-only while serving.
- Synchronous handlers have a fast path; NIO futures are available for asynchronous I/O.
- Performance claims must be backed by reproducible release-build benchmarks.

## Status

Initial framework foundation is being built now.
