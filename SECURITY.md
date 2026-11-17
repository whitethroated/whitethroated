# Security Policy

## Supported versions

WhiteThroated is pre-alpha. Only the latest `main` receives fixes, on a
best-effort basis.

| Version | Supported |
| ------- | --------- |
| main    | Yes       |
| older   | No        |

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Report it
privately through a GitHub security advisory:

https://github.com/whitethroated/whitethroated/security/advisories/new

Include the affected commit, the impact, and reproduction steps or a
proof of concept where possible.

You will receive an initial response on a best-effort basis; this is a
pre-alpha project with a single maintainer. If the report is accepted,
a fix is developed privately and released before any public details
are disclosed.

## Scope notes

- Test fixtures under `Tests/` (for example the localhost TLS
  certificate) are dummy values and are labeled as such; they are not
  vulnerabilities.
- Benchmark servers and example apps bind to localhost by default and
  are not hardened for hostile networks.
