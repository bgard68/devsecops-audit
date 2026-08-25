# devsecops-audit

One checklist, run against several repositories, every week.

`scripts/audit.sh` checks branch protection, workflow hardening, action
pinning, runtime deprecation and secret hygiene across every repository and
every deploying branch. It prints a line per failure and nothing at all when
everything passes.

```bash
./scripts/audit.sh
```

```
=== repo-level ===
=== branch-level ===
=== secrets ===

AUDIT CLEAN - 0 failures
```

## Why this exists

It came out of hardening four repositories in a single sitting. The same
question — *"is this secure now?"* — was asked five times, and five times the
answer was yes, and five times looking again found something the previous look
had not thought to check.

None of those answers was careless. Each was true about what had been examined
and silent about what had not, which is the failure mode of working from
memory: you check what comes to mind, and what comes to mind is what you fixed
most recently.

So the checklist is written down and runs whole, every time. It cannot get
bored, cannot decide a category is probably fine, and cannot quietly stop
looking at something because it was clean last week.

The second thing it encodes is harder-won: **almost every real finding came
from attempting the thing rather than reading the configuration.**

- Reading said a branch was protected. Pushing to it showed the rules were
  being bypassed, and that three of them had never been satisfiable at all.
- Reading said the deprecated Node 20 runtime was gone. A sweep found it in
  three more repositories, including one whose entire deploy path used it.
- Reading said the required checks were configured. They could not be — they
  were path-filtered, so they would never report, and a required check that
  never reports blocks the merge for ever.

Configuration is a statement of intent. Only the attempt is evidence.

## Repositories under audit

| Repository | What it is |
|---|---|
| [ClaudeChessApp](https://github.com/bgard68/ClaudeChessApp) | Client-side chess app — React, TypeScript, Stockfish in a worker, SQLite in OPFS |
| [ToDoApp](https://github.com/bgard68/ToDoApp) | .NET 10 API and React frontend — JWT auth, refresh-token revocation, Google sign-in |
| [LotteryApp](https://github.com/bgard68/LotteryApp) | .NET API with an Angular frontend |
| [Net10Sudoku](https://github.com/bgard68/Net10Sudoku) | Blazor Interactive Server sudoku generator and solver |
| [DevSecOpsSentinel](https://github.com/bgard68/DevSecOpsSentinel) | GitHub Actions supply-chain analyzer — deterministic rules, model-written explanations |
| [WidgetWorks](https://github.com/bgard68/WidgetWorks) | E-commerce store — rotating refresh tokens, TOTP 2FA, server-side re-priced checkout |
| **this repository** | audits itself, on the same checklist |

Ten deploying branches between them. Several of these projects deploy from
more than one branch, which is why the audit takes `repo:branch` pairs rather
than assuming the default.

## Documentation

| | |
|---|---|
| [docs/FINDINGS.md](docs/FINDINGS.md) | What the review actually found — cause, fix, and what now makes it visible |
| [docs/HARDENING.md](docs/HARDENING.md) | The controls applied across the repositories, and how each was verified |
| [docs/PIPELINE.md](docs/PIPELINE.md) | Every workflow and script — what it does, when it runs, and why it earns its place |
| [docs/AUDIT.md](docs/AUDIT.md) | Every check, why it is on the list, and the rules the checks follow |
| [docs/WEEKLY.md](docs/WEEKLY.md) | Running it on a schedule, and the one token it needs |

[docs/README.md](docs/README.md) indexes these and states the three ideas they
all reduce to.

[FINDINGS.md](docs/FINDINGS.md) is the one worth reading if you only read one.
It includes the two findings that were **wrong** — a workflow reported as using
`pull_request_target` because a comment mentioned it, and a branch reported as
unprotected because only one of the two protection APIs was consulted. Both are
why the checks now match structure rather than text, and read the endpoint that
owns the answer.

## What is not here

No deployment, no cloud resources, no credentials. This repository holds a
shell script and its documentation.

The weekly run needs a token to read the repositories it audits, because
`GITHUB_TOKEN` is scoped to the repository it runs in. That token lives in
GitHub's encrypted secret store and is referred to **by name** — see
[docs/WEEKLY.md](docs/WEEKLY.md). Nothing sensitive is committed here, and the
`.gitignore` names the categories explicitly rather than relying on nobody
making a mistake.

## Requirements

`gh` (authenticated), `bash`, `base64`, `awk`.

Not `jq` — an earlier version used it and produced twelve false failures on a
machine without it, each check evaluating to empty and being read as
*disabled*. `gh api --jq` does the same work with the `jq` built into `gh`.

Most checks need admin rights on the repository being audited: branch
protection, rulesets, security settings and secret lists are not public, even
for a public repository.

## Licence

[MIT](LICENSE).
