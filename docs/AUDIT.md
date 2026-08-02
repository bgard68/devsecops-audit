# The audit script

`scripts/audit.sh` runs one checklist against every repository and every
deploying branch, every time. It prints a line per failure and exits with the
count, so it can gate a job.

```bash
./scripts/audit.sh
```

```
=== repo-level ===
=== branch-level ===
=== secrets ===

AUDIT CLEAN - 0 failures
```

Silence under a heading means every check in it passed everywhere. That is the
whole design: a clean run is boring, and anything worth reading is a `FAIL`
line naming the repository, the branch and the file.

## Why it exists

The review that produced it answered *"is this secure now?"* five times. Each
answer was true about what had been looked at and silent about what had not,
and each following round found something the previous one had not thought to
check.

The problem was not diligence, it was working from memory. A checklist that
runs the same twenty checks every time cannot get bored, cannot decide a
category is probably fine, and cannot quietly stop looking at the thing it
fixed last week.

## What it checks

**Per repository**

| Check | Why it is on the list |
|---|---|
| Secret scanning | Free on public repositories; off by default on older ones |
| Push protection | Stops a credential being committed rather than reporting it after |
| Dependabot security updates | The only thing watching dependencies between releases |
| Private vulnerability reporting | A `SECURITY.md` linking to `/security/advisories/new` is a dead link without it |
| `SECURITY.md` present | Otherwise a finder's options are a public issue or silence |
| `dependency-review.yml` present | Refuses a pull request that *adds* a vulnerable dependency, upstream of the audit that catches it after merge |
| Zero open alerts | Dependabot, code scanning and secret scanning, counted separately |

**Per deploying branch**

| Check | Why |
|---|---|
| Required status checks exist | Without them a red pull request can merge, and auto-merge will do it unattended |
| Pull request required | Both the classic endpoint and rulesets are consulted |

**Per workflow file**

| Check | Why |
|---|---|
| A `permissions:` block | Otherwise the job inherits whatever the repository default is |
| No `pull_request_target` | Combined with a checkout of untrusted code it is the most serious workflow finding there is |
| No `github.event.*` interpolated into `run:` | Script injection from a title or branch name someone else controls |
| `persist-credentials: false` on every checkout | Otherwise the job token sits in `.git/config` while the repository's own scripts run |
| Every action pinned to a commit SHA | A tag is a pointer its owner can move |
| No action on the Node 20 runtime | GitHub is retiring it; nothing warns until a job stops working |

**Per secret**

Every secret is checked for a reference in some workflow on some branch.
Unreferenced ones are reported, because an unused credential is pure attack
surface — nothing depends on it, so nothing notices if it is abused.

## Two rules the checks follow

Both were learned by getting them wrong. They are why the script is shaped the
way it is, and worth keeping in mind before adding a check.

### Ask the API that owns the answer

Branch protection lives in two places. Classic protection is at
`repos/{r}/branches/{b}/protection`; rulesets are at `repos/{r}/rules/branches/{b}`.
**Each returns nothing for the other.** A repository protected by a ruleset
reports `404 Branch not protected`, and a repository protected classically
returns an empty rules list.

Reading one and concluding is how a protected branch got reported as
unprotected, and — later, in the other direction — how an unprotected one got
reported as fine. Both are consulted.

The same applies to private vulnerability reporting: the `security_and_analysis`
block does not carry it, and reading that block says `unset` even immediately
after enabling it succeeds. The dedicated endpoint is the one that knows.

### Match structure, not text

An early version flagged a workflow for `pull_request_target` because a comment
in it read *"this uses pull_request, **not** pull_request_target"*. Triggers are
matched at line start (`^\s*pull_request_target:`) so a discussion of a pattern
is not mistaken for the pattern.

## Dependencies, and one that was removed

`gh` (authenticated), `bash`, `base64`, `awk`. That is all.

**Not `jq`.** An earlier version used it and reported twelve false failures on a
machine that did not have it — each check silently evaluating to empty and
being read as "disabled". `gh api --jq` does the same work using the `jq`
built into `gh`, with no separate install.

That failure is worth remembering for any check added later: a check that
cannot run should say so, not report a failure. Anything that shells out needs
to distinguish *the answer was no* from *the question could not be asked*.

## Running it against other repositories

Owner and targets are overridable, so it is not welded to one account:

```bash
OWNER=someone REPOS="alpha beta" BRANCHES="alpha:main beta:main beta:release" ./scripts/audit.sh
```

`BRANCHES` is `repo:branch` pairs — a repository can appear more than once,
which is how a project that deploys from several branches gets each of them
checked. That matters: the finding that a "stale" deploy token was actually in
use came from a script that only looked at default branches.

## Permissions

Most checks need **admin rights on the repository being audited** — branch
protection, rulesets, the security settings and the secret list are not public,
even for a public repository.

Locally the script uses whatever `gh auth` already has. In CI it needs a token
supplied explicitly; see [WEEKLY.md](WEEKLY.md).

## Adding a check

Keep to the existing shape:

1. Put it in the section it belongs to — repository, branch, workflow, secret.
2. Call `note "..."` on failure and say **where**: repository, branch, file.
3. Print nothing on success. The value of a clean run is that it is empty.
4. Ask the endpoint that owns the answer, and match structure rather than text.
5. Make sure a check that *cannot run* is distinguishable from one that failed.
