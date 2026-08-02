# Documentation

Five documents, one question each.

| Read this | To answer |
|---|---|
| [FINDINGS.md](FINDINGS.md) | What was actually wrong, how it was found, and what now makes the same class of thing visible |
| [HARDENING.md](HARDENING.md) | What was applied across the repositories, why each control exists, and how it was verified |
| [PIPELINE.md](PIPELINE.md) | Every workflow and script — what it does, when it runs, and why it earns its place |
| [AUDIT.md](AUDIT.md) | What `scripts/audit.sh` checks, the rules its checks follow, and how to add one |
| [WEEKLY.md](WEEKLY.md) | Running it on a schedule, and the one token it needs |

## If you only read one

**[FINDINGS.md](FINDINGS.md)**, and specifically the two findings that were
*wrong*: a workflow reported as using `pull_request_target` because a comment
in it mentioned the phrase, and a branch reported as unprotected because only
one of the two protection APIs was consulted.

Those are more useful than the successes. They are why the checks now match
structure rather than text, and read the endpoint that owns the answer.

## The three ideas underneath all of it

Everything in these documents reduces to three things, each learned by getting
it wrong first.

### Configuration is intent; only the attempt is evidence

Reading said a branch was protected — pushing to it showed the rules were being
bypassed, and that three of them had never been satisfiable at all. Reading
said the required checks were configured — they could not be, because they were
path-filtered and would never report.

Every control in [HARDENING.md](HARDENING.md) that matters was verified by
making it fail: a direct push refused, a red pull request blocked, a planted
secret caught. Where something was only read back from an API, it says so.

### Green means one of two things

Nothing is wrong, or the check is not looking.

A container scan ran for its entire life with `exit-code: '0'` — reporting
CRITICAL findings faithfully and blocking nothing, while 28 accumulated behind
a passing job. The gate probes in [PIPELINE.md](PIPELINE.md) exist to tell the
two apart, by showing each gate something it must reject.

This applies to the audit itself. `scripts/audit.sh` claimed in its own header
that its exit code was the failure count, and for three commits it was not — so
a failing audit reported a passing job. It is now proven on every run.

### A check that cannot run must not look like a check that passed

An early version of the audit depended on `jq`, which was not installed. Every
check silently evaluated to empty and was read as *disabled*: twelve false
failures.

The same shape, later and in the other direction: the audit could not read a
repository's security settings because the token lacked a permission, and
reported three enabled controls as *off*. It now says which permission is
missing, which is actionable.

The weekly workflow refuses to run at all without its token, for the same
reason — a clean audit that was never performed is worse than no audit.
