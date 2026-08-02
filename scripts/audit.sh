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
REPOS="${REPOS:-ClaudeChessApp ToDoApp LotteryApp Net10Sudoku devsecops-audit}"
BRANCHES="${BRANCHES:-ClaudeChessApp:main ToDoApp:main ToDoApp:dapper ToDoApp:frontend LotteryApp:main LotteryApp:frontend Net10Sudoku:main devsecops-audit:main}"
case "${1:-}" in
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

fails=0
note() { echo "  FAIL  $*"; fails=$((fails+1)); }

wf()  { gh api "repos/${OWNER}/$1/contents/.github/workflows/$3?ref=$2" --jq '.content' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null; }
wfs() { gh api "repos/${OWNER}/$1/contents/.github/workflows?ref=$2" --jq '.[].name' 2>/dev/null; }
rt()  { b=$(echo "$1"|cut -d/ -f1,2); s=$(echo "$1"|cut -d/ -f3-); p="action.yml"; [ -n "$s" ] && p="$s/action.yml"
        gh api "repos/${OWNER}/$b/contents/$p?ref=$2" --jq '.content' 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null | grep -oE "node[0-9]+" | head -1; }

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
  c=$(gh api "repos/${OWNER}/$r/branches/$b/protection" --jq '[.required_status_checks.contexts[]?]|length' 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
  k=$(gh api "repos/${OWNER}/$r/rules/branches/$b" --jq '[.[]|select(.type=="required_status_checks")|.parameters.required_status_checks[].context]|length' 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
  [ $((c+k)) -gt 0 ] || note "$r/$b no required status checks"
  types=$(gh api "repos/${OWNER}/$r/rules/branches/$b" --jq '[.[].type]|join(",")' 2>/dev/null)
  cls=$(gh api "repos/${OWNER}/$r/branches/$b/protection" --jq '"classic"' 2>/dev/null)
  echo "$types" | grep -q pull_request || [ -n "$cls" ] || note "$r/$b no PR requirement"

  for f in $(wfs "$r" "$b"); do
    c2=$(wf "$r" "$b" "$f")
    echo "$c2" | grep -qE "^permissions:|^\s+permissions:" || note "$r/$b $f no permissions block"
    echo "$c2" | grep -qE "^\s*pull_request_target:" && note "$r/$b $f uses pull_request_target"
    echo "$c2" | grep -qE '\$\{\{ *github\.event\.(issue|pull_request|comment|review|head_commit)' && note "$r/$b $f interpolates untrusted input"
    nco=$(echo "$c2" | grep -c "actions/checkout@"); npc=$(echo "$c2" | grep -c "persist-credentials")
    [ "$nco" -gt 0 ] && [ "$npc" -lt "$nco" ] && note "$r/$b $f checkout without persist-credentials"
    for ref in $(echo "$c2" | grep -ohE "uses: [a-zA-Z0-9._-]+/[a-zA-Z0-9._/-]+@[^ ]+" | sed 's/uses: //'); do
      echo "$ref" | grep -qE "@[0-9a-f]{40}" || { note "$r/$b $f unpinned: $ref"; continue; }
      [ "$(rt "$(echo $ref|cut -d@ -f1)" "$(echo $ref|cut -d@ -f2)")" = "node20" ] && note "$r/$b $f node20: $(echo $ref|cut -d@ -f1)"
    done
  done
done

echo "=== secrets ==="
for r in $REPOS; do
  for s in $(gh secret list -R ${OWNER}/$r 2>/dev/null | awk '{print $1}'); do
    hit=0
    for e in $BRANCHES; do
      [ "${e%%:*}" = "$r" ] || continue
      for f in $(wfs "$r" "${e##*:}"); do wf "$r" "${e##*:}" "$f" | grep -q "$s" && hit=1; done
    done
    [ "$hit" -eq 0 ] && note "$r stale secret: $s"
  done
done

echo
[ "$fails" -eq 0 ] && echo "AUDIT CLEAN - $fails failures" || echo "AUDIT: $fails failure(s)"
