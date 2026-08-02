# Findings

Everything the review turned up across four repositories, what caused it, and
what changed. Kept because the fix is rarely the interesting part — the
interesting part is why nobody had noticed, and what now makes the same class
of thing visible.

Ordered by how much each one was actually worth, not by when it was found.

---

## The pattern behind most of them

Nearly every real finding came from **attempting the thing rather than reading
the configuration**.

Reading said one repository's `main` was protected. Attempting a push showed
the rules were being bypassed, and that three of them had never been satisfiable
at all. Reading said the deprecated Node 20 runtime was gone. A sweep found it
in three more repositories. Reading said the required checks were configured.
They could not be, because they were path-filtered and would never report.

The configuration is a statement of intent. Only the attempt is evidence.

---

## Protection that was not protecting

### Rules that had never once been satisfiable

One repository's ruleset required a Copilot code review, signed commits, a
linear history and one approving review. None had ever been met:

- **Copilot had never reviewed a pull request** in the repository's history.
- **Nothing was signed.** Every commit read `verified: false`.
- **The history contained merge commits**, so `required_linear_history` on
  `~ALL` branches meant no branch cut from `main` could be pushed at all.
- **One approving review, on a solo repository.** GitHub does not let you
  approve your own pull request, so the only reviewer was ineligible.

All five survived because an **admin bypass** was set to `always`. Every merge
in the repository's history had gone through it. Removing the bypass did not
break anything — it revealed that nothing had been working.

**Fixed:** bypass removed, unsatisfiable rules dropped, approvals set to 0, the
ruleset scoped to the default branch. The remaining rules — pull request
required, no force-push, no deletion — were then verified by attempting a
direct push and watching it be refused.

**Prevented by:** `audit.sh` checks both the classic protection endpoint *and*
the rulesets endpoint, because each returns 404 for the other. A repository can
look unprotected while being protected, and vice versa.

### `update` froze three branches at once

The same ruleset carried GitHub's **Restrict updates** rule. It blocks every
update to a matching ref — including a pull request merge. With the admin
bypass removed, three branches became unmergeable by anyone.

It was redundant anyway: the `pull_request` rule already forces changes through
a pull request. `creation` was similar — it blocked creating any branch, which
made the pull request workflow impossible.

**Fixed:** both removed. `pull_request` alone expresses the intent.

---

## Gates that could not fail

### A container scan that reported for its entire life

Trivy ran on every build with `exit-code: '0'`. It found CRITICAL and HIGH
vulnerabilities faithfully, uploaded them to the Security tab, and **blocked
nothing**. Twenty-eight had accumulated behind a job that was passing.

The setting was deliberate, and documented:

> Report rather than block: base-image CVEs appear and are fixed upstream on
> Microsoft's schedule, not ours, so failing the build would just teach
> everyone to ignore a red X.

That reasoning is sound in general and did not survive `ignore-unfixed: true`,
which was set on the same step. Trivy drops everything without a patch, so
whatever it still reports is **fixable by definition**. The 28 findings were
not waiting on Microsoft; Microsoft had already shipped, and nothing was
rebuilding to collect it.

**Fixed:** base images bumped to current digests, then `exit-code: '1'`. In that
order, so the gate turned on against an image that could pass rather than
failing on its first run.

**Prevented by:** `gate-probes.yml`, described below.

### Nothing proved any gate could fail

Green means one of two things — nothing is wrong, or the check is not looking —
and nothing distinguished them.

**Fixed:** a `gate-probes.yml` workflow in each repository shows every gate
something it must reject, and fails if the gate does not:

| Gate | Shown |
|---|---|
| NuGet audit | `System.Net.Http 4.3.0`, a known high-severity advisory |
| The compiler | an unused local, fatal under `TreatWarningsAsErrors` |
| The test runner | a test asserting 1 equals 2 |
| gitleaks | a planted credential, generated at run time |
| Container scan | asserted by configuration — see below |

Three details in those probes are load-bearing:

- **The planted secret is generated at run time**, never written literally. A
  real-looking token committed there would make the probe file the leak its own
  scanner reports. It is PAT-shaped rather than AWS-shaped, because gitleaks
  allowlists AWS's documented example key.
- **A setup failure must not read as a gate failure.** Without the build props
  file the NuGet audit is simply not configured — the advisory arrives as a
  plain warning, restore succeeds, and the probe reports a broken gate that is
  fine. The copy is checked; each log is matched for its specific diagnostic
  rather than for failure in general. A probe that accepts *any* failure proves
  nothing.
- **The container scan is asserted by configuration, not behaviour**, and that
  is deliberate. A behavioural probe needs an image that carries fixable
  CRITICAL findings *and keeps carrying them*, and no such image exists. Two
  were tried. An end-of-life release has nothing fixed for it at all, so
  `ignore-unfixed` skips its whole list. The superseded base image that had 28
  findings that morning scanned clean by the afternoon, because upstream had
  published the fixes. The subject has to be vulnerable today and stay
  vulnerable, and the world keeps patching.

---

## Checks that could not be required

`Build & Test` and `Build API image & scan` were **path-filtered**. A
path-filtered check never reports on a pull request that misses its paths, and
a required check that never reports blocks the merge for ever. So the checks
that mattered most could not be added to the required list.

That is not academic. Auto-merge was enabled to drain a dependency queue and
merged two updates **while the container build was failing**, because there
were no required checks for it to wait on. One branch could no longer build its
image.

**Fixed:** `paths:` removed from `pull_request` only — the `push` trigger keeps
its filter, since there is no reason to rebuild on a docs edit. The checks then
became requireable, and were required.

Removing the filter surfaced a **second** breakage on its first run: another
branch's container build had been failing for days, from a dependency bump that
updated one project's lock file and left three others behind. Nothing had
caught it because no pull request since had touched the filtered paths.

**Verified:** by opening a pull request with a deliberately failing test on each
branch and confirming the merge was refused, then closing it.

---

## One branch's tests had never run

`api-ci-cd.yml` triggered on pull requests to `main` only. The branch holding an
**alternative implementation of the same API** had never run the unit or
integration suites on any proposed change — which is precisely where a
behavioural difference between the two implementations would appear.

Found while working out which checks could safely be required there: `Build &
Test` could not be, because it never ran.

**Fixed:** the trigger now covers that branch too. It has no deploy job, so the
change adds building and testing and nothing else.

---

## Two name lookups destroying the same accent

Player names were matched against two ASCII tables — a hand-kept list, and a
fetched directory of 120 keys with no accented character in any of them. The
source files are under no such discipline: the same person is "Ljubojevic" in
one collection and "Ljubojević" in another.

Both lookups handled the difference by throwing the accented letter away, and
each did it differently:

| | Did this | `Ljubojević` became |
|---|---|---|
| Lookup A | deleted it | `ljubojevi` |
| Lookup B | replaced it with a space | `ljubojevi` |

Neither matches `ljubojevic`, which is what both tables hold.

The first cost a flag. The second was worse and less visible: that function
decides which spellings are *the same person*, so an accented name was filed
apart from its own plain spelling — one player appearing as two, each holding
part of their games. It was failing at the one job it exists to do.

Neither was ever reported, and neither could have been: every bundled file
spells names in ASCII, so nothing on screen was wrong. Only imported files —
precisely where diacritics arrive — would have shown it.

**Fixed:** both fold through one function. NFD splits an accented letter into
base plus combining mark and the mark is dropped; a small table covers the
letters NFD cannot split, because **Ólafsson decomposes and Đurić does not**. A
fold built on `normalize('NFD')` alone looks complete and silently misses every
stroked letter — ø, đ, ł, ß, æ.

**Found by:** writing tests for a file that had none.

---

## Smaller, still real

- **A live deploy token reported as stale.** An audit script scanned only the
  default branch and called a credential unreferenced. It was in use — by a
  workflow on a different branch, which was exactly what the deployed site was
  linked to. Rotating it would have broken the deploy. *The script now sweeps
  every branch.*
- **Node 20 across four repositories.** GitHub is retiring it on the runners.
  Eighteen action references still declared it, including one repository's
  entire deploy path, where nothing would have warned until it simply stopped
  working. *Every pinned SHA is now checked by reading its `action.yml` at that
  exact commit — not by trusting the version number.*
- **`AllowedHosts: "*"`** on a public API, permitting host-header injection and
  cache poisoning. A sibling repository had fixed exactly this and written down
  why; this one had not. *Now an explicit allow-list, verified by the CI smoke
  test which boots with production configuration.*
- **`id-token: write` at workflow scope**, so the pull request build job carried
  the ability to mint an Azure OIDC token. *Moved to the deploy job.*
- **Five stale secrets**, including a deploy token for a resource that no longer
  existed. *Deleted, after checking every branch.*
- **Checkout leaving the job token in the workspace.** `actions/checkout` writes
  `GITHUB_TOKEN` into `.git/config` unless told not to, and those jobs then run
  the repository's own scripts against that workspace. *Fourteen call sites
  across two repositories now set `persist-credentials: false`.*
- **No disclosure policy** on two public repositories. GitHub's Security tab
  showed nothing, so a finder's realistic options were a public issue or
  silence. *Both now have a `SECURITY.md` written against what that app
  actually exposes, and private vulnerability reporting is enabled so the links
  in them work.*

---

## Two false findings, kept here on purpose

Both were reported confidently and both were wrong. They are the reason the
script matches structurally and reads the endpoint that owns the answer.

**"This workflow uses `pull_request_target`."** It did not. A comment in it read
*"this uses pull_request, not pull_request_target"*, and the check was matching
text anywhere in the file. `pull_request_target` with a checkout of untrusted
code is one of the most serious things you can find in a workflow, so a false
positive there costs real time.

**"This branch is unprotected."** It was protected — by a ruleset, which the
classic `branches/*/protection` endpoint reports as 404. The reverse also
happened later: a branch protected classically looked unprotected to the
rulesets endpoint. Both endpoints are now consulted.

A third is worth recording because the tool was right and the alert was not: a
CodeQL `cs/log-forging` finding stayed open on code that was already sanitised,
because CodeQL models only built-in sanitizers and could not see the custom
one. Dismissed as a false positive **with the reason recorded** — not silently
suppressed, and not "fixed" by changing working code to satisfy a scanner.
