# Skill: cross-platform portability

Use this skill whenever changing platform APIs, sockets, filesystem behavior,
system-library integration, process/signal behavior, concurrency assumptions,
or code that must work on both macOS/Darwin and Linux/Glibc.

This skill is mandatory for changes involving C system interfaces, libpq, zlib,
socket APIs, file descriptors, sockaddr values, platform conditionals, or
Linux-only/macOS-only benchmark behavior.

## Principle

A passing macOS build is not portability evidence.

A passing Linux build is not portability evidence for Darwin either.

WhiteThroated should preserve one semantic contract across supported platforms
while isolating unavoidable platform differences behind small, testable
boundaries.

## Supported platform mindset

Assume at least these dimensions can differ:

- Darwin vs Glibc;
- macOS vs Linux kernel behavior;
- ARM64 vs x86_64;
- kqueue vs epoll;
- Swift toolchain minor versions;
- system-library versions;
- C enum/import representation;
- socket structure layout;
- signal/process semantics;
- filesystem details;
- TLS/system package availability.

Do not encode behavior observed on one developer machine as a universal OS rule.

## Conditional imports

Use explicit platform imports where system APIs differ.

Typical pattern:

```swift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
```

Keep conditional compilation narrow.

Do not scatter large duplicated implementations across many files when a small
platform adapter can isolate the difference.

Prefer defining one normalized internal value or helper and using it from common
logic.

## C type normalization

Swift's imported C types may differ between platforms.

Examples include:

- socket type constants represented as Int32 vs enum/rawValue;
- option constants;
- socklen_t-related conversions;
- errno values;
- structure fields available on one platform but not another.

Do not force-cast platform C types casually.

Normalize once with explicit, checked conversions where practical.

A platform-specific cast should document why the target width/sign is safe.

## sockaddr differences

Do not assume Darwin-only fields such as `sin_len` exist on Linux.

When constructing socket addresses:

- initialize all required fields;
- set family using the correct imported type;
- set length fields only where the platform defines them;
- preserve byte order conversions;
- pass the correct structure length;
- avoid reading uninitialized padding.

Use helpers to keep raw pointer rebinding localized and auditable.

## Socket API behavior

Even when APIs share names, operational behavior can differ.

Review:

- connect;
- accept;
- listen backlog;
- nonblocking mode;
- shutdown;
- close;
- socket options;
- SIGPIPE behavior;
- timeout behavior;
- cancellation sockets;
- readiness notification;
- error codes.

Do not infer Linux behavior from loopback results on macOS.

A test using a deliberately silent peer can expose platform-specific blocking
behavior that does not occur against a real protocol peer. Model the production
peer behavior when the test is intended to prove real lifecycle semantics.

## Event notification

SwiftNIO abstracts most kqueue/epoll differences. Prefer staying at the NIO
level when possible.

If code bypasses NIO and interacts with descriptors directly:

- define ownership;
- define blocking/nonblocking state;
- define which thread/queue performs the operation;
- define close ordering;
- handle interrupted syscalls;
- handle EAGAIN/EWOULDBLOCK correctly;
- avoid descriptor reuse races.

Do not add a custom polling loop when SwiftNIO already owns the connection.

## errno handling

When using C APIs:

- capture errno immediately after failure;
- do not call unrelated C APIs before interpreting it;
- distinguish retryable/transient cases;
- handle EINTR where the operation requires retry;
- do not assume identical errno values across platforms.

Public errors should express stable framework semantics rather than exposing raw
platform numbers as the only contract.

## Signals

Signal behavior differs materially between environments.

Do not assume:

- SIGPIPE is ignored;
- process signal masks match local shell behavior;
- container PID 1 behaves like a normal process;
- signal delivery occurs on a chosen thread.

Prefer SwiftNIO or established lifecycle abstractions for server shutdown where
possible.

If direct signal handling is required, keep it outside signal-unsafe operations
and document the supported process model.

## Filesystem portability

Review:

- path separators and normalization;
- symlink behavior;
- case sensitivity assumptions;
- temporary directory behavior;
- file permission semantics;
- atomic rename guarantees;
- open flags;
- descriptor lifetime.

Do not infer a security boundary from macOS default case-insensitive filesystem
behavior.

Static-file path safety must be semantic and explicit.

## System libraries

For SwiftPM system-library targets such as libpq or zlib:

- document required development packages;
- keep module maps/headers minimal;
- prefer pkg-config when appropriate;
- do not vendor implementation source merely to make CI easier;
- verify package naming on supported Linux distributions;
- verify Homebrew/keg-only discovery when relevant;
- isolate version-specific API differences.

Do not assume the version on a developer Mac matches Ubuntu CI or production.

## libpq portability

When changing PostgreSQL integration, check:

- libpq major version;
- cancellation API behavior;
- TLS defaults/features;
- thread-safety guarantees;
- connection-state APIs;
- error strings;
- nonblocking vs blocking behavior;
- pkg-config discovery.

A code path that works with one libpq version may behave differently on another.

Use `.agents/skills/data-persistence/SKILL.md` alongside this skill.

## zlib portability

When changing compression integration, verify:

- zlib API availability;
- initialization/finalization return codes;
- integer-width conversions;
- buffer ownership;
- streaming flush semantics;
- system library linking.

Do not assume an SDK-provided macOS zlib layout matches Linux packaging.

## TLS portability

NIOSSL provides the primary abstraction for direct TLS. Prefer it over platform
TLS APIs.

Still validate:

- dependency version;
- certificate file access;
- path handling;
- supported protocol configuration;
- platform-specific build/link behavior.

Do not add Security.framework- or OpenSSL-specific application code to core
paths unless the task explicitly introduces a platform adapter.

## Architecture differences

Avoid assumptions tied to one CPU architecture:

- pointer size;
- alignment;
- unaligned access;
- cache-line size;
- atomic width;
- endianness;
- integer overflow behavior in C bridges.

Swift integer semantics are stable, but unsafe/raw memory code creates new proof
obligations.

Any unsafe optimization must be benchmarked on the architecture it is intended
to improve and must retain a correct portable fallback when necessary.

## Time and clock behavior

Use monotonic clocks for elapsed-time measurement.

Do not use wall clock for benchmark duration or timeout arithmetic when a
monotonic source is available.

Review differences in:

- clock resolution;
- scheduler granularity;
- timer coalescing;
- CI virtualization.

Do not convert platform timing noise into deterministic test thresholds.

## Threading and scheduling

A thread count that is optimal on an M1 Pro loopback benchmark is not a universal
production default.

Platform scheduling, CPU topology, container quotas, and NUMA can change the
best configuration.

Separate:

- portable correctness default;
- measured host-specific tuning;
- benchmark-only configuration.

Do not hard-code a macOS-derived event-loop count as a Linux performance truth
without evidence.

## Build portability

When touching Package.swift or system dependencies, verify applicable builds on
both platform families.

Pay attention to:

- platform availability annotations;
- system-library provider declarations;
- compiler conditional branches;
- Linux-only missing Foundation/Darwin APIs;
- strict concurrency diagnostics;
- linker flags.

Avoid adding shell scripts to solve portability; repository implementation and
benchmark programs must remain Swift according to root instructions.

## Testing strategy

For platform-sensitive changes, require:

1. deterministic local/unit tests for common semantics;
2. platform-specific compile coverage;
3. runtime tests on the affected platform when behavior depends on the OS or
   system library;
4. full release suite where feasible.

Test the semantic contract, not just whether a function returns.

For a bug that only reproduced on Linux, keep a regression that actually runs
on Linux CI or a documented Linux validation path.

Do not "fix" portability by skipping the affected test on the failing platform
unless the feature is explicitly unsupported there.

## Linux validation

Use the repository Linux validation checklist for Linux-sensitive work.

At minimum record applicable environment details:

- distro/version;
- kernel;
- CPU architecture;
- Swift version;
- system-library versions;
- package dependencies;
- release/debug mode.

For performance conclusions, also follow the benchmark skill and use controlled
hardware. GitHub-hosted CI is correctness evidence, not stable performance
evidence.

## Cross-platform API design

Public APIs should expose semantic behavior, not Darwin/Glibc implementation
details.

Avoid public types that leak:

- raw errno numbers as the primary error model;
- sockaddr layout;
- platform-only file flags;
- vendor-specific library handles.

If a platform-specific capability is genuinely required, isolate it behind an
explicit platform-specific API rather than contaminating the portable default.

## Review checklist

Before approving a platform-sensitive change, verify:

- Darwin/Glibc imports are correct;
- C types are normalized safely;
- Darwin-only fields are not used on Linux;
- descriptor ownership is explicit;
- blocking behavior is understood on both platforms;
- errno is captured and interpreted safely;
- system-library versions are considered;
- macOS-only tests are not the sole evidence for Linux behavior;
- Linux-only work does not regress Darwin builds;
- architecture assumptions are documented;
- performance tuning is not mistaken for a portable default.

## Stop conditions

Reject or redesign the change when:

- it compiles only because one platform imports a C constant differently;
- platform-specific code is duplicated broadly instead of isolated;
- a descriptor can be closed/reused while another operation still owns it;
- a test simulates a peer unlike production and then treats the result as a
  platform truth;
- macOS success is presented as Linux validation;
- Linux CI is bypassed for code that depends on Glibc/system libraries;
- an architecture-specific unsafe optimization lacks a correct fallback;
- a host-specific tuning result is hard-coded as a universal runtime default.
