# The pipeline

What runs, when, and why — across all five repositories.

Every workflow here earns its place by answering a question nothing else
answers. Where two look similar, the difference is usually *when* they run,
and that difference is the point.

---

## The flow

```
                   ┌──────────────────────────────────────────────┐
   commit ────────▶│  branch                                      │
                   │  (direct push to a protected branch: REFUSED)│
                   └───────────────────┬──────────────────────────┘
                                       │  open a pull request
                                       ▼
    ┌──────────────────────────────────────────────────────────────────┐
    │  REQUIRED CHECKS — all must pass, none may be skipped             │
    │                                                                   │
    │   build + test ......... does it compile, do the tests pass       │
    │   container build/scan . does the image build, any fixable CVEs   │
    │   CodeQL ............... static analysis over the source          │
    │   gitleaks ............. any credential in the whole history      │
    │   gate probes .......... can each of the above actually fail      │
    │   dependency review .... does this PR ADD a vulnerable package    │
    └───────────────────────────────┬──────────────────────────────────┘
                                    │  merge (squash)
                                    ▼
    ┌──────────────────────────────────────────────────────────────────┐
    │  DEPLOY — only from the deploying branch, gated on the same run   │
    │                                                                   │
    │   build → publish → deploy → SMOKE TEST against the live app      │
    └──────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
    ┌──────────────────────────────────────────────────────────────────┐
    │  SCHEDULED — nobody triggers these, which is the point            │
    │                                                                   │
    │   weekly audit ......... has anything drifted, anywhere           │
    │   CodeQL (weekly) ...... new queries against unchanged code       │
    │   container rescan ..... new CVEs against an unchanged Dockerfile │
    │   keep-warm ............ free-tier apps sleep; wake them          │
    │   run cleanup .......... stop retention growing without limit     │
    └──────────────────────────────────────────────────────────────────┘
```

Three properties hold this together, and each was learned by its absence:

- **A direct push to a deploying branch is refused.** Verified by attempting
  one, not by reading the setting — a bypassed push still *succeeds* and only
  says `Bypassed rule violations` in the output.
- **A required check must always report.** A path-filtered check stays pending
  for ever on a pull request that misses its paths, so it cannot be required —
  which is how a red pull request once merged unattended.
- **A gate nobody has watched fail is a claim, not a gate.**

---

## Workflows, by what they answer

### Does it build and pass its tests?

| Repository | Workflow | Job name |
|---|---|---|
| ClaudeChessApp | `ci.yml` | `gate` |
| ToDoApp | `api-ci-cd.yml` | `Build & Test` |
| LotteryApp | `ci.yml`, `ci-frontend.yml` | backend and frontend |
| Net10Sudoku | `ci.yml` | `build-and-test`, `smoke-test` |

ClaudeChessApp's is a single `gate` job running `scripts/test-gate.ps1`, which
chains typecheck → tests → audit → build → smoke → layout → behaviour →
accessibility → gitleaks, and then the probes. One required check covering
everything, rather than ten.

**Path filters were removed from `pull_request`** on ToDoApp's build workflows.
They remain on `push`, where nothing gates and there is no reason to rebuild on
a docs edit. That asymmetry is deliberate and is what makes the check
requireable.

### Does the container image build, and is anything in it fixable?

`container-build.yml` — ToDoApp (`main`, `dapper`, `frontend`).

Builds the image and scans with Trivy at `severity: CRITICAL,HIGH`,
`ignore-unfixed: true`, **`exit-code: '1'`**.

That last value is the whole story. It was `'0'` for the workflow's entire
life: findings reported faithfully, build blocked never, 28 accumulated behind
a passing job. The documented reasoning — base-image CVEs move on the vendor's
schedule, so blocking would only train people to ignore a red X — does not
survive `ignore-unfixed` on the same step. Trivy drops everything without a
patch, so **whatever it still reports is fixable by definition**.

Also runs weekly: a base image picks up CVEs without the Dockerfile changing,
so a scan that only runs on commit will miss them indefinitely.

### Is there anything wrong in the source?

`codeql.yml` — all four application repositories.

`security-and-quality`, which is a superset of the default security queries.
Configured as a workflow rather than through the GitHub UI's default setup: a
UI setting cannot be diffed, does not travel to a fork, and can be turned off
without leaving a trace in git history.

Weekly as well as on push, because new queries are published against code that
has not changed.

### Is there a credential anywhere in the history?

`secret-scan.yml` / `gitleaks.yml` — every repository.

**`fetch-depth: 0`**, so the whole history is scanned rather than the tip. A
credential deleted in a later commit is still in the history and still valid —
deleting the file is not rotating the secret.

Weekly too, because the rules improve: a commit that scanned clean last year
may not now.

### Can each of those gates actually fail?

`gate-probes.yml` — ToDoApp (`main`), LotteryApp, Net10Sudoku.

Each gate is shown something it must reject, and the job fails if the gate does
not notice:

| Gate | Shown |
|---|---|
| NuGet audit | `System.Net.Http 4.3.0`, a known high-severity advisory |
| The compiler | an unused local, fatal under `TreatWarningsAsErrors` |
| The test runner | a test asserting 1 equals 2 |
| gitleaks | a planted credential, generated at run time |
| Container scan | asserted by configuration, deliberately — see below |

Everything happens in scratch directories. The solution is never touched.

Three details are load-bearing rather than incidental:

- **The planted secret is generated at run time**, never written literally — a
  real-looking token committed there would make the probe file the leak its own
  scanner reports. PAT-shaped, not AWS-shaped, because gitleaks allowlists
  AWS's documented example key.
- **A setup failure must not read as a gate failure.** Each probe verifies its
  own preconditions and greps the log for a *specific* diagnostic. A probe that
  accepts any failure proves nothing.
- **The container scan is asserted by configuration**, because a behavioural
  probe needs an image that carries fixable findings *and keeps carrying them*.
  Two were tried: an end-of-life release has nothing fixed for it, so
  `ignore-unfixed` skips its whole list; and the superseded base image with 28
  findings that morning scanned clean by the afternoon. The world keeps
  patching. So the probe asserts `exit-code: '1'` is set, which is the thing
  that actually regressed.

### Does this pull request add a vulnerable dependency?

`dependency-review.yml` — every repository.

The package audits already fail the build on an advisory, but they ask *"is
anything vulnerable today?"* — answered after the change has landed. This asks
*"does this pull request introduce one?"* and answers before the merge button
appears.

It diffs the manifests of base against head, so it only reports what the change
itself brings in. An advisory that was already there is not its business, which
is what keeps it from becoming a check people learn to ignore.

### Did the thing that deployed actually start?

| Repository | Workflow | Verification |
|---|---|---|
| ClaudeChessApp | `azure-static-web-apps.yml` | smoke test in the gate, pre-deploy |
| ToDoApp | `api-ci-cd.yml` | post-deploy smoke test against the live API |
| LotteryApp | `deploy-api.yml`, `deploy-web.yml` | live smoke test in CI |
| Net10Sudoku | `deploy.yml` | `smoke-test` job |

ToDoApp's post-deploy smoke test is the most interesting, because of what it
has to tolerate. Unit and integration tests exercise a process the workflow
starts itself, so they cannot see a missing app setting, a Key Vault the
managed identity can no longer read, or a dependency graph that only fails once
real configuration is bound.

It **wakes before it asserts**. The App Service plan is Free F1 and the
database is serverless with a 60-minute auto-pause, so a deploy after a quiet
hour meets a cold app in front of a paused database. Waking is expected and is
not a failure; conflating the two would fail deploys for being idle, which is
the fastest way to teach everyone to rerun a red job without reading it.

Then it asserts, and retries nothing:

| Check | Expect | A failure means |
|---|---|---|
| `GET /` | 200 | did not boot, or configuration would not bind |
| `GET /api/todos` unauthenticated | 401 | **200 means the API is open to anyone** |
| `POST /api/auth/login`, wrong password | 401 | 500 means the database or DI graph is broken |

**No credentials needed.** A login with a deliberately wrong password still
travels routing, model binding, the user store and the hasher — 401 is the
proof it arrived.

### Housekeeping

- **`keep-warm.yml` / `keep-alive.yml`** — free-tier apps sleep. A ping every
  ten minutes keeps the *app* up. Note it does **not** keep a serverless
  database awake, which is why the smoke test has its own wake loop.
- **`cleanup-runs.yml` / `actions-cleanup.yml`** — workflow run retention grows
  without limit otherwise.
- **`branch-isolation.yml`** (LotteryApp) — refuses a pull request that mixes
  backend and frontend changes across the branch boundary.
- **`era-check.yml`** (LotteryApp) — a domain check on the data, not a security
  control.
- **`scripts-lint.yml`** (ToDoApp) — parses every shell and PowerShell script.

---

## This repository's own workflows

Held to the same standard it applies to the others, which is not a courtesy —
a tool exempting itself from its own checks is the failure it exists to find.

### `audit.yml` — the weekly audit

Runs Monday 07:17 UTC, on demand, and on any change to the script or the
workflow. Opens an issue labelled `audit` on failure; a second failure comments
on the open issue rather than opening another, so a problem persisting for a
month is one issue and not four.

It **stops with an error when `AUDIT_TOKEN` is absent**, rather than running and
reporting a clean audit it never performed. See [WEEKLY.md](WEEKLY.md) for the
token.

The step ends with `exit "$status"` and not with an echo. That is not
decoration: the first version ended on an echo, so the job reported *pass*
while the audit printed failures. See [AUDIT.md § The exit code](AUDIT.md#the-exit-code).

### `lint.yml` — the script is the product

| Job | What it proves |
|---|---|
| Parse every script | `bash -n` on each — a syntax error never reaches a run |
| Every script is executable | mode `100755` in the index. A script committed `100644` fails at run time with exit 126, which reads as *ran and failed* rather than *never started* |
| **Probe — a failing audit exits non-zero** | the audit is shown a target it cannot check and required to say so in its exit code |
| shellcheck | `--severity=warning`. `SC2086` excluded deliberately: the repository and branch lists are space-separated words that are *meant* to split |
| Every action is pinned to a SHA | this repository audits others for exactly that |

The probe is the important one. `scripts/audit.sh` promised in its own header
that the exit code was the failure count, and for three commits it was not —
the summary line was the last command, an echo always succeeds, and a failing
audit exited 0. Two earlier fixes aimed at propagating that status were both
correct and neither could help, because the value being propagated was always
zero.

The probe itself then failed on its first run, killed by the non-zero exit it
was written to observe: GitHub runs a `run:` block with `bash -e`. It captures
with `|| status=$?` now.

### `gitleaks.yml` and `dependency-review.yml`

Identical in purpose to the others. This repository holds no credentials by
design, which is exactly why the scan matters — the claim is only worth
something if something checks it.

---

## Scripts

### `scripts/audit.sh` — this repository

The checklist. Full detail in [AUDIT.md](AUDIT.md).

### ClaudeChessApp

The richest set, because a client-side app has no server to smoke-test and so
has to verify differently.

| Script | What it proves |
|---|---|
| `test-gate.ps1` | Chains every check and then the probes. The single required check. |
| `smoke-test.mjs` | The built bundle boots, the board renders, a game starts, and bundled Stockfish answers a real move. Unit tests cannot catch a broken bundle, a missing `.wasm`, or a worker path typo. |
| `layout-check.mjs` | Four screens × three viewports, **presence first**. Written after a release where the suite, the build and the smoke test were all green while the settings panel was absent from every phone — each check asked *"is anything here wrong?"* and none asked *"is everything here?"* |
| `behaviour-check.mjs` | What the app *does*: paging appends, searching replaces, sort reverses, reset clears the sort too. A static render cannot see anything an effect does. |
| `a11y-check.mjs` | axe-core over four screens at two widths. Keeps a `KNOWN` list of faults that are real, not ours, and unfixable from here — **printed every run** rather than filtered out, because a check that quietly drops what it cannot fix is how a known problem becomes a forgotten one. |

### The .NET repositories

| Script | Purpose |
|---|---|
| `todoapp-smoketest.ps1`, `smoke-test.ps1` | Drive the running app end to end |
| `check-azure-posture.sh`, `Check-AzurePosture.ps1` | Cloud-side configuration, which no repository check can see |
| `check-docs-drift.sh` | Documentation that no longer matches the code |
| `provision-azure.ps1`, `azure-provision.ps1` | Infrastructure, kept as code rather than as portal clicks |

---

## Why the schedule matters as much as the trigger

Most of what goes wrong here does not arrive in a commit.

An action publishes a new major. A runtime is deprecated. A ruleset is edited
in the UI. A base image picks up a CVE. A secret is added and never wired up. A
CodeQL query is published for a pattern that has been in the code for a year.

None of that produces a diff, so nothing triggered by a diff will ever notice.
That is the entire argument for the weekly audit, the weekly rescan, and the
weekly CodeQL run — and the reason the audit's own failure opens an issue
rather than a red tick nobody was watching on a Monday morning.
