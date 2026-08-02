# Running it weekly

`.github/workflows/audit.yml` runs the checklist every Monday at 07:17 UTC,
and on demand from the Actions tab. It also runs on any change to the script
itself, so a broken audit is caught by the audit rather than a week later.

If anything fails it opens an issue labelled `audit`. A failing scheduled job
is easy to miss — nobody is watching Actions on a Monday morning — and an issue
is not. A second failure comments on the open issue rather than opening
another, so a problem that persists for a month is one issue and not four.

## The one thing it needs from you

The audit reads **other** repositories' branch protection, rulesets, security
settings and secret lists. `GITHUB_TOKEN` cannot do that: it is scoped to the
repository it runs in. So the workflow needs a token with read access to the
targets.

**Nothing goes in this repository.** The workflow refers to the secret by name;
GitHub substitutes the value at run time and masks it in logs. That is the same
distinction that applies everywhere: a workflow holds the *name* of a secret,
never the value.

### Creating it

1. **[Create a fine-grained personal access token](https://github.com/settings/personal-access-tokens/new)**
2. **Repository access** → *Only select repositories* → pick exactly the ones
   listed in `scripts/audit.sh`, and nothing else. That includes this
   repository, which audits itself. The picker is multi-select even though the
   dropdown closes after each choice — reopen it and add the next.
3. **Repository permissions**, all read-only:

   | Permission | Access | Needed for |
   |---|---|---|
   | Administration | Read | branch protection, rulesets |
   | Metadata | Read | mandatory, granted automatically |
   | Contents | Read | reading workflow files |
   | Secrets | Read | listing secret *names* — never values |
   | Dependabot alerts | Read | open alert counts |
   | Code scanning alerts | Read | open alert counts |
   | Secret scanning alerts | Read | open alert counts |

4. Set an expiry you will actually notice — 90 days is reasonable. Do not
   choose *No expiration*; a token that never expires is one nobody ever
   reconsiders.
5. Add it here as an Actions secret named **`AUDIT_TOKEN`**:
   `Settings → Secrets and variables → Actions → New repository secret`

Fine-grained rather than classic, deliberately. A classic PAT with `repo` scope
can **write** to every repository you can reach; this one can only read the
handful named, and cannot push, merge or delete anything.

### If it is missing

The job stops with an error saying so, rather than running and reporting a
clean audit it never performed.

That is deliberate and it is the same mistake this project has already made
once: an earlier version of the script depended on a tool that was not
installed, and every check silently evaluated to empty and was read as
*disabled* — twelve false failures. **A check that cannot run must never look
like a check that passed**, in either direction.

## Changing what gets audited

The repositories and branches live at the top of `scripts/audit.sh` and are
overridable by environment variable, so a one-off run needs no commit:

```bash
OWNER=someone REPOS="alpha beta" BRANCHES="alpha:main beta:main" ./scripts/audit.sh
```

`BRANCHES` is `repo:branch` pairs, and a repository may appear more than once.
That matters more than it looks: a project deploying from several branches
needs each of them checked, and a script that only looked at default branches
is exactly how a live deploy token was once reported as unused.

## Cost

Free. Public repositories get Actions minutes at no charge, and the audit is
API calls — about a minute per run.
