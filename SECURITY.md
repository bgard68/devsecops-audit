# Security

## Reporting a vulnerability

Use GitHub's private reporting:
[**Report a vulnerability**](https://github.com/bgard68/devsecops-audit/security/advisories/new).
It opens a private advisory visible only to the maintainer, so a problem can be
fixed before it is described in public. Please do not open a public issue for
anything exploitable.

Expect a first response within a week. This is a personal project with one
maintainer, not a product with an on-call rotation — that is the honest
expectation to set rather than a service level nobody is paying for.

## What the threat model actually is

This repository is a shell script and its documentation. There is no server, no
application, no user data and nothing deployed anywhere.

What it does have is **a token, and reach**. The weekly workflow runs with a
personal access token that can read four other repositories, and it executes a
script from this repository against them. So the realistic exposure is not that
someone attacks this repository — it is that this repository becomes a path to
the ones it audits.

### Worth reporting

- **Anything that could exfiltrate `AUDIT_TOKEN`.** A workflow change that
  echoes it, writes it to an artifact, sends it anywhere, or passes it to an
  action that might. This is the highest-value finding here by a distance.
- **A path by which an outside contributor's code could run in the audit job.**
  The workflow deliberately does not use `pull_request_target`, and a
  pull request from a fork runs without repository secrets. A way around either
  is a real finding.
- **Command injection in `scripts/audit.sh`.** It interpolates repository and
  branch names into shell commands, and a hostile repository name is a
  plausible vector for anyone auditing repositories they do not own.
- **A check that reports a pass it did not perform.** The script is only useful
  if a clean run means something; a way to make it report clean while skipping
  work is a genuine bug, and the reason the workflow fails outright when its
  token is absent.

### Not vulnerabilities here

- **"The audit reveals which security controls are configured."** Everything it
  reports is visible to anyone with access to those repositories, and the
  controls are strong enough not to depend on being secret.
- **"The token has read access to four repositories."** That is the minimum it
  can do its job with. It is fine-grained, read-only, scoped to those
  repositories, and cannot push, merge or delete. Reporting that a read-only
  token can read is reporting the design.
- **"There is no test suite."** There is not, and that is a real limitation
  rather than a vulnerability. The script's checks are exercised against four
  live repositories weekly, which is a form of coverage but not the same thing.

## How this repository is protected

`main` requires a pull request, refuses force-pushes and deletions, and has
required status checks that are verified by opening a deliberately failing
pull request rather than by reading the configuration back.

Every action is pinned to a commit SHA. Every workflow declares its
permissions. Every checkout sets `persist-credentials: false`. gitleaks scans
the whole history on every pull request, and dependency review refuses one that
adds a vulnerable dependency.

The audit in `scripts/audit.sh` runs against this repository too. It would be a
poor advertisement otherwise.
