# The controls, and what each is for

What was applied across the four repositories, why, and how each is verified.
The order is roughly by how much each one is worth.

A control nobody has watched fail is a claim, not a control. Where something
was verified by making it fail, that is noted — and where it was only read back
from an API, that is noted too, because those are not the same evidence.

---

## Branch protection that holds

**Pull request required, no force-push, no deletion, no owner bypass**, on every
deploying branch.

The last of those is the one that matters. A ruleset with an admin bypass set
to `always` is advisory for exactly the account that does the pushing. Removing
it on one repository revealed that five of its rules had never been satisfiable
at all — nothing was signed, Copilot had never reviewed anything, the history
contained merge commits so linear history was impossible, and a solo maintainer
cannot approve their own pull request. Every merge in that repository's history
had gone through the bypass.

**Verified by attempting a direct push** and confirming it is refused, on every
repository. The API says a branch is protected; a rejected push proves it. Note
the difference in the output — a bypassed push still succeeds and says
`Bypassed rule violations`, which reads as a rejection if you are skimming.

## Required status checks

Between two and six per branch, including the build and the tests.

Auto-merge without these is worse than no auto-merge: it merged two dependency
updates while a container build was failing, because there was nothing for it
to wait on. One branch could not build its image afterwards.

The checks that mattered could not initially be required, because they were
**path-filtered** — a filtered check never reports on a pull request that misses
its paths, and a required check that never reports blocks the merge for ever.
Removing `paths:` from the `pull_request` trigger (keeping it on `push`) made
them requireable, and surfaced a second broken build on the first run.

**Verified by opening a pull request with a deliberately failing test** on each
branch and confirming the merge was refused.

## Gates proven able to fail

`gate-probes.yml` in each repository shows every gate something it must reject,
and fails if the gate does not.

This exists because a container scan ran with `exit-code: '0'` for its entire
life — reporting CRITICAL findings faithfully and blocking nothing, while 28
accumulated behind a passing job. **Green means one of two things: nothing is
wrong, or the check is not looking.** Nothing else distinguishes them.

Three details in the probes are load-bearing:

- The planted secret is **generated at run time**. A real-looking token
  committed there would make the probe file the leak its own scanner reports.
  PAT-shaped rather than AWS-shaped, because gitleaks allowlists AWS's
  documented example key.
- **A setup failure must not read as a gate failure.** Each probe checks its own
  preconditions and matches the log for a specific diagnostic, not for failure
  in general. A probe that accepts *any* failure proves nothing.
- The container scan is asserted **by configuration rather than behaviour**, and
  the workflow says so. A behavioural probe needs an image that carries fixable
  findings and keeps carrying them; no such image exists, because upstream keeps
  publishing fixes. Two were tried and both went clean.

## Supply chain

**Every action pinned to a commit SHA.** A tag is a pointer its owner can move,
and several of these sat in jobs holding deploy credentials. Dependabot still
raises the bumps, which is the point: an upgrade becomes a diff you read rather
than something that happens overnight.

**Dependency review on every pull request.** The package audits already fail the
build on an advisory, but they ask *"is anything vulnerable today?"* — answered
after the change has landed. Dependency review asks *"does this pull request
introduce one?"* and answers before the merge button appears. It diffs base
against head, so it only reports what the change itself brings in, which is what
keeps it from becoming a check people learn to ignore.

**Package audits failing the build.** NuGet audit in `all` mode rather than the
default `direct` — a vulnerable package three levels down ships the same code as
one named in a project file. The audit warnings are named explicitly in
`WarningsAsErrors` rather than left to inherit, because restore-time warnings do
not reliably inherit it, and *probably fails* is not a gate.

**Off the deprecated Node 20 runtime.** Eighteen action references still declared
it, including one repository's entire deploy path, where nothing would have
warned until a job simply stopped working. Verified by reading each action's
`action.yml` **at the exact pinned SHA** rather than trusting a version number.

**Lock files respected.** Installs use the committed lock, so what deploys is
the tree that was reviewed.

## Least privilege

**A `permissions:` block on every workflow.** Otherwise the job inherits the
repository default, which is broader than any of these jobs need.

**`persist-credentials: false` on every checkout.** `actions/checkout` writes
`GITHUB_TOKEN` into `.git/config` unless told not to, and those jobs then run
the repository's own scripts against that workspace. Nothing pushes, so the
credential has no use after the clone.

**`id-token: write` on the deploy job only.** At workflow scope the pull request
build job carried it too, and that job runs on every pull request.

**Deploy credentials scoped to an environment**, not the repository, so a
workflow that does not name the environment cannot read them.

**OIDC federation instead of stored passwords** where the platform supports it.

## Secret hygiene

**No unreferenced secrets.** An unused credential is pure attack surface —
nothing depends on it, so nothing notices if it is abused. Five were removed,
including a deploy token for a resource that no longer existed.

One near-miss worth recording: a token was reported as stale and nearly
rotated. It was in use, by a workflow on a **non-default branch** that the
checking script had not looked at — the branch the deployed site was actually
linked to. Rotating it would have broken the deploy. The audit now sweeps every
branch.

**Secret scanning with push protection**, which stops a credential being
committed rather than reporting it afterwards. **gitleaks over the whole
history**, not just the working tree.

## Disclosure

**A `SECURITY.md` in every repository**, and **private vulnerability reporting
enabled** so the link in it works — without that, `/security/advisories/new` is
a dead end and a finder's realistic options are a public issue or silence.

Each policy is written against what that application actually exposes. The one
for a client-side app with no server says so, and lists the supply chain as the
real risk. The one for an API with accounts and a database names authorisation
bypass as the highest-value finding, and — importantly — names the **seeded demo
account as deliberately not a vulnerability**, because someone would otherwise
reasonably report being able to log into it.

Saying what is *not* a vulnerability is the part that saves everyone time. A
policy that only invites reports invites the useless ones too.

## What is deliberately not done

**Signed commits.** One repository required them while nothing had ever been
signed, so the rule only ever forced a bypass. It was removed rather than left
as theatre. Re-enable it *after* signing works — adding the rule first simply
freezes the repository.

**Major version upgrades held.** Several libraries changed to commercial
licences in a major version, and others need real code changes. Both sets are
held in `dependabot.yml` at `semver-major` only, so patches and minors still
arrive and a security fix inside the current major is not blocked. Held rather
than closed weekly: a decision retaken every Monday is not a decision, it is a
queue nobody reads — which is how the genuinely urgent update gets missed.
