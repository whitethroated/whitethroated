---
name: secret-hygiene
description: Prevent credential and personal-identity leaks in code and before every commit.
---

# Secret Hygiene

Use this skill for every task that creates or changes repository content.
It applies alongside the task-specific skills, and its before-commit
checks run before every commit (see
`skills/agentic-git-workflow/SKILL.md`).

## Goal

No credential material and no personal identity ever enters the working
tree, a commit, or the pushed history: not in code, tests, fixtures,
docs, configs, examples, benchmarks, or commit messages.

## Definitions

- Credential material: private keys, API tokens, passwords, connection
  strings containing passwords, certificates bundled with private keys,
  and any other value that grants access to a system or account.
- Personal identity: any email address that is not the project's public
  noreply identity, and any other personal contact detail.
- Not secrets: public certificates without private keys, the project's
  public noreply identity, `example.*` placeholders, and synthetic test
  constants (fixed bytes such as `0x11` repeats) that grant access to
  nothing.

## Rules

1. Never write credential material into the repository. Fetch it at
   runtime from the environment or a secret store instead.
2. Test fixtures that look like credentials are allowed only when all
   of these hold: the file carries the line `Test-only fixture.`
   adjacent to the material, the subject is localhost or otherwise
   dummy, the scope is minimal, and the material grants access to
   nothing real. Prefer generating ephemeral credentials in test
   setup over committing static ones.
3. Every commit's author and committer email must be the project's
   public noreply identity
   (`YOUR_ID+YOUR_USER@users.noreply.github.com`). Set it before the
   first commit on any machine, and enable the hosting provider's
   push-blocking for exposed emails.
4. Never add `.env`, `*.pem`, `*.key`, `id_rsa*`, `credentials.*`, or
   equivalent secret-holder filenames.
5. Docs, skills, and examples use redacted placeholders
   (`ghp_<redacted>`, `AKIA…`, `<password>`) and never real-looking
   values. An example that scans as a secret is a leak.
6. "Temporary" credentials are forbidden. Temporary secrets become
   permanent history.
7. Never bypass these checks with `--no-verify` or an equivalent
   escape hatch. A failing check means the commit is not ready.

## Before-commit checks

Run all four checks on the staged diff. Any failure blocks the
commit until the staged content is fixed.

### 1. Identity

```text
git config user.email
```

must print an address ending in `@users.noreply.github.com`.

### 2. Credential content

Always-blocked patterns must print nothing:

```bash
git diff --cached -U0 -- . | grep -nE 'AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|xox[bap]-[A-Za-z0-9-]+|sk-[A-Za-z0-9]{20,}|aws_secret_access_key|(password|passwd|api[_-]?key|client_secret)[[:space:]]*[:=][[:space:]]*["'"'"']'
```

Key material is allowed only in labeled test fixtures and must print
nothing:

```bash
git diff --cached --name-only --diff-filter=ACM | while read f; do
  git diff --cached -U0 -- "$f" | grep -q 'BEGIN .*PRIVATE KEY' || continue
  grep -q 'Test-only fixture' "$f" || echo "UNLABELED KEY MATERIAL: $f"
done
```

### 3. Credential filenames

```bash
git diff --cached --name-only --diff-filter=ACM | grep -iE '(^|/)\.env$|\.pem$|\.key$|id_rsa|credentials\.json$|secrets?\.(json|ya?ml|txt)$'
```

must print nothing.

### 4. Email-like strings

```bash
git diff --cached -U0 -- . | grep -Eo '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | sort -u
```

Every address printed must be the noreply identity, an `example.*`
placeholder, or an obviously dummy value. Anything else blocks the
commit.

For periodic audits, run the same patterns over the tree with
`git grep` and over history with `git log -p`.

## Optional local pre-commit hook

Hooks live in `.git/hooks/` and are never committed. To install,
save the snippet below as `.git/hooks/pre-commit`, make it
executable, and keep it in sync with the checks above:

```bash
#!/bin/sh
set -e
case "$(git config user.email)" in
*@users.noreply.github.com) ;;
*) echo "BLOCKED: user.email is not the noreply identity" >&2; exit 1 ;;
esac
if git diff --cached -U0 -- . | grep -nE 'AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|gho_[A-Za-z0-9]{36}|xox[bap]-[A-Za-z0-9-]+|sk-[A-Za-z0-9]{20,}|aws_secret_access_key|(password|passwd|api[_-]?key|client_secret)[[:space:]]*[:=][[:space:]]*["'"'"']'; then
  echo "BLOCKED: possible credential in staged diff" >&2; exit 1
fi
git diff --cached --name-only --diff-filter=ACM | while read f; do
  git diff --cached -U0 -- "$f" | grep -q 'BEGIN .*PRIVATE KEY' || continue
  grep -q 'Test-only fixture' "$f" || { echo "BLOCKED: unlabeled key material: $f" >&2; exit 1; }
done
if git diff --cached --name-only --diff-filter=ACM | grep -iE '(^|/)\.env$|\.pem$|\.key$|id_rsa|credentials\.json$|secrets?\.(json|ya?ml|txt)$'; then
  echo "BLOCKED: credential filename in staged diff" >&2; exit 1
fi
```

## Incident response

- Unpushed leak on a private repo: unstage or amend the commit so the
  material never becomes history.
- Pushed leak on a private repo: rewrite the branch and force-push
  before the repo goes public; confirm zero traces remain.
- Leak on a public repo: rotate the credential first, because history
  surgery never un-leaks it. Then purge history and ask the host to
  clear cached views. For a personal email, accept the exposure or
  rotate the address; rewriting only stops future scrapes.
- Never "fix" a leak with a follow-up commit that leaves the material
  in history.

## Verifying this skill

After editing the patterns above, run all four checks against the
current tree and confirm they pass, and confirm each pattern still
matches a known fixture (a check that cannot fire proves nothing).
