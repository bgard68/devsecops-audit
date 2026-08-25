#!/usr/bin/env bash
#
# One DevSecOps audit across several repositories, run from a checklist rather
# than from memory.
#
# It exists because of how the review that produced it actually went: the same
# question — "is this secure now?" — was answered five times, and each answer
# was true about what had been looked at and silent about what had not. Every
# round found something the previous round had not thought to check. The fix
# was not more diligence, it was writing the list down.
#
# So: every check below runs against every repository and every deploying
# branch, every time. Silence on a check means it passed everywhere.
#
# Two rules the checks follow, both learned by getting them wrong:
#
#   Ask the API that owns the answer. Branch protection lives in two places —
#   classic protection and rulesets — and each returns 404 for the other. A
#   repository can look unprotected while being protected, and reading only one
#   endpoint says so with confidence.
#
#   Match structure, not text. An earlier version flagged a workflow for using
#   pull_request_target because a comment in it said "this uses pull_request,
#   NOT pull_request_target". Triggers are matched at line start now.
#
# Usage:
#   ./scripts/audit.sh                       # audit the defaults below
#   OWNER=someone REPOS="a b" ./scripts/audit.sh
#   BRANCHES="a:main a:dev b:main" ./scripts/audit.sh
#
# Requires: gh (authenticated), bash, base64, awk. No jq — an early version
# depended on it and reported twelve false failures on a machine without it.
#
# Reading other repositories' protection settings needs admin rights on them,
# so in CI this runs with a token supplied through the workflow. Locally it
# uses whatever `gh auth` already has.
#
# Exit code is the number of failures, so it can gate a job.
# Owner and targets are overridable so this is not welded to one account.
#   OWNER=someone REPOS="a b" BRANCHES="a:main b:main b:dev" ./scripts/audit.sh
OWNER="${OWNER:-bgard68}"
# devsecops-audit audits itself. A tool that exempts itself from its own checks
# is the failure this exists to prevent, in miniature: the checklist was written
# because "is it secure?" kept being answered from memory, and a list with a
# hole in it where the auditor sits is the same gap wearing a different hat.
REPOS="${REPOS:-ClaudeChessApp ToDoApp LotteryApp Net10Sudoku DevSecOpsSentinel WidgetWorks devsecops-audit}"
BRANCHES="${BRANCHES:-ClaudeChessApp:main ToDoApp:main ToDoApp:dapper ToDoApp:frontend LotteryApp:main LotteryApp:frontend Net10Sudoku:main DevSecOpsSentinel:main WidgetWorks:main devsecops-audit:main}"
case "${1:-}" in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

fails=0
note() { echo "  FAIL  $*"; fails=$((fails+1)); }

# gh prints the JSON error body to STDOUT on a non-2xx and exits non-zero, so
# the exit status is the only thing separating an answer from an error wearing
# an answer's clothes. Reading only the text turned one deleted branch into
# eight findings: the missing ref returned
#   {"message":"No commit found for the ref frontend",...,"status":"404"}
# an unquoted expansion split it into seven words, and each word was audited as
# though it were a workflow file - printing a fragment of the 404 where a file
# name belongs.
#
# The same lesson as the missing-jq run that reported twelve controls disabled:
# a check that could not run must never be reported as a check that ran.
api() { api_out=$(gh api "$@" 2>/dev/null) || return 1; printf '%s\n' "$api_out"; }

wf()  { api "repos/${OWNER}/$1/contents/.github/workflows/$3?ref=$2" --jq '.content' | tr -d '\n' | base64 -d 2>/dev/null; }
wfs() { api "repos/${OWNER}/$1/contents/.github/workflows?ref=$2" --jq '.[].name'; }
# Own names for the temporaries: rt is only ever called inside $( ), which is
# what currently keeps b, s and p from leaking over the branch loop's own b.
rt()  { rt_b=$(echo "$1"|cut -d/ -f1,2); rt_s=$(echo "$1"|cut -d/ -f3-); rt_p="action.yml"; [ -n "$rt_s" ] && rt_p="$rt_s/action.yml"
        api "repos/${OWNER}/$rt_b/contents/$rt_p?ref=$2" --jq '.content' | tr -d '\n' | base64 -d 2>/dev/null | grep -oE "node[0-9]+" | head -1; }

echo "=== repo-level ==="
for r in $REPOS; do
  # security_and_analysis is only returned to a token with admin rights on the
  # repository. A token without them gets the field omitted entirely, which is
  # indistinguishable from "disabled" unless you look — and reporting a control
  # as off because the question could not be asked is the same failure as the
  # missing-jq run that produced twelve false failures.
  sa=$(gh api repos/${OWNER}/$r --jq '.security_and_analysis // "MISSING"' 2>/dev/null)
  if [ "$sa" = "MISSING" ] || [ -z "$sa" ]; then
    note "$r cannot read security settings - the token needs Administration: Read on this repository"
  else
    [ "$(gh api repos/${OWNER}/$r --jq '.security_and_analysis.secret_scanning.status' 2>/dev/null)" = "enabled" ] || note "$r secret scanning off"
    [ "$(gh api repos/${OWNER}/$r --jq '.security_and_analysis.secret_scanning_push_protection.status' 2>/dev/null)" = "enabled" ] || note "$r push protection off"
    [ "$(gh api repos/${OWNER}/$r --jq '.security_and_analysis.dependabot_security_updates.status' 2>/dev/null)" = "enabled" ] || note "$r dependabot off"
  fi
  [ "$(gh api repos/${OWNER}/$r/private-vulnerability-reporting --jq .enabled 2>/dev/null)" = "true" ] || note "$r private vuln reporting off"
  gh api repos/${OWNER}/$r/contents/SECURITY.md >/dev/null 2>&1 || note "$r no SECURITY.md"
  for kind in dependabot/alerts code-scanning/alerts secret-scanning/alerts; do
    n=$(gh api "repos/${OWNER}/$r/$kind" --paginate --jq '[.[]|select(.state=="open")]|length' 2>/dev/null | awk '{s+=$1} END{print s+0}')
    [ "${n:-0}" -eq 0 ] || note "$r $n open $kind"
  done
  gh api "repos/${OWNER}/$r/contents/.github/workflows/dependency-review.yml" >/dev/null 2>&1 || note "$r no dependency-review"
done

echo "=== branch-level ==="
for e in $BRANCHES; do
  r=${e%%:*}; b=${e##*:}

  # A branch that is not there cannot be audited, and must not be reported as
  # though it were. Asked once, up front: every check below reads this ref, so
  # without this its absence is rediscovered by each of them in turn and filed
  # as a separate finding against a file that never existed.
  if ! api "repos/${OWNER}/$r/branches/$b" --jq '.name' >/dev/null; then
    note "$r/$b branch not found - restore it, or drop it from BRANCHES"
    continue
  fi

  c=$(gh api "repos/${OWNER}/$r/branches/$b/protection" --jq '[.required_status_checks.contexts[]?]|length' 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
  k=$(gh api "repos/${OWNER}/$r/rules/branches/$b" --jq '[.[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|length' 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
  [ $((c+k)) -gt 0 ] || note "$r/$b no required status checks"
  types=$(gh api "repos/${OWNER}/$r/rules/branches/$b" --jq '[.[].type]|join(",")' 2>/dev/null)
  cls=$(gh api "repos/${OWNER}/$r/branches/$b/protection" --jq '"classic"' 2>/dev/null)
  echo "$types" | grep -q pull_request || [ -n "$cls" ] || note "$r/$b no PR requirement"

  if ! names=$(wfs "$r" "$b"); then
    note "$r/$b cannot list workflows - the token needs Contents: Read on this repository"
    continue
  fi

  # read -r over a here-string, not $(...): a file name is a line, and word
  # splitting is what let a 404 body pose as seven of them.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    c2=$(wf "$r" "$b" "$f")
    if [ -z "$c2" ]; then
      note "$r/$b $f could not be read - reporting that rather than auditing an empty file"
      continue
    fi
    echo "$c2" | grep -qE "^permissions:|^\s+permissions:" || note "$r/$b $f no permissions block"
    echo "$c2" | grep -qE "^\s*pull_request_target:" && note "$r/$b $f uses pull_request_target"
    echo "$c2" | grep -qE '\$\{\{ *github\.event\.(issue|pull_request|comment|review|head_commit)' && note "$r/$b $f interpolates untrusted input"
    nco=$(echo "$c2" | grep -c "actions/checkout@"); npc=$(echo "$c2" | grep -c "persist-credentials")
    [ "$nco" -gt 0 ] && [ "$npc" -lt "$nco" ] && note "$r/$b $f checkout without persist-credentials"
    for ref in $(echo "$c2" | grep -ohE "uses: [a-zA-Z0-9._-]+/[a-zA-Z0-9._/-]+@[^ ]+" | sed 's/uses: //'); do
      echo "$ref" | grep -qE "@[0-9a-f]{40}" || { note "$r/$b $f unpinned: $ref"; continue; }
      [ "$(rt "$(echo $ref|cut -d@ -f1)" "$(echo $ref|cut -d@ -f2)")" = "node20" ] && note "$r/$b $f node20: $(echo $ref|cut -d@ -f1)"
    done
  done <<< "$names"
done

echo "=== secrets ==="
for r in $REPOS; do
  for s in $(gh secret list -R ${OWNER}/$r 2>/dev/null | awk '{print $1}'); do
    hit=0
    for e in $BRANCHES; do
      [ "${e%%:*}" = "$r" ] || continue
      names=$(wfs "$r" "${e##*:}") || continue
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        wf "$r" "${e##*:}" "$f" | grep -q "$s" && hit=1
      done <<< "$names"
    done
    [ "$hit" -eq 0 ] && note "$r stale secret: $s"
  done
done

echo
if [ "$fails" -eq 0 ]; then
  echo "AUDIT CLEAN - $fails failures"
else
  echo "AUDIT: $fails failure(s)"
fi

# The header promises the exit code is the failure count, and for three
# commits it was not: the summary line above was the last command, and an echo
# always succeeds, so a failing audit exited 0 and every job using it passed.
#
# A claim about behaviour that nothing verifies is the fault this whole
# repository was written to find. It was written into the script's own
# documentation and went unchecked for exactly as long as it took someone to
# read the output instead of the status. The lint job now proves this line
# works by running the audit against a target that cannot pass.
exit "$fails"
