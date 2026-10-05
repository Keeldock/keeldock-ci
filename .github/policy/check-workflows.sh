#!/usr/bin/env bash
# The workflow-structure policy: reviewed Actions, trust tiers, token revocation order,
# root removal, cache, secrets and dispatcher rules. Run from the repository root.
set -euo pipefail

policy=.github/policy
source "${policy}/workflow-lists.sh"
source "${policy}/lib.sh"
source "${policy}/check-actions.sh"
source "${policy}/check-cache-policy.sh"
source "${policy}/check-concern.sh"
source "${policy}/check-protected.sh"
source "${policy}/check-dispatchers.sh"

# Never cancel or replace a source-bearing run: cancellation can interrupt the step that revokes
# the short-lived source token, and GitHub replaces a pending run in a shared group. Each run
# needs its own group (github.run_id) or none, and cancel-in-progress false (check-concurrency.sh).
bash "${policy}/check-concurrency.sh" >/dev/null || { bash "${policy}/check-concurrency.sh" >&2 || true; exit 1; }

# Every workflow file is in exactly one tier: no unlisted workflow can appear.
while IFS= read -r -d '' workflow; do
  case " ${protected_source_workflows[*]} ${protected_dispatch_workflows[*]} ${public_policy_workflow} " in
    *" ${workflow} "*) ;;
    *) echo "Workflow not in a reviewed trust tier (workflow-lists.sh): ${workflow}" >&2; exit 1 ;;
  esac
done < <(find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)

while IFS= read -r -d '' workflow; do
  check_action_references "$workflow"

  if [[ "$workflow" == .github/actions/*/action.yml ]]; then
    check_composite_action "$workflow" || { echo "Composite action policy violated: $workflow" >&2; exit 1; }
    continue
  fi

  protected_source=0
  for protected_workflow in "${protected_source_workflows[@]}"; do
    if [[ "$workflow" == "$protected_workflow" || "$workflow" == "./$protected_workflow" ]]; then
      protected_source=1
      break
    fi
  done

  if (( protected_source )); then
    check_protected_source "$workflow"
  else
    check_dispatcher "$workflow"
  fi
done < <(find .github/workflows .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)

if find . -type f -not -path './.git' -not -path './.git/*' -not -path './.github/workflows/*' -not -path './.github/actions/*/action.yml' -not -path './.github/policy/*' -not -path './.github/dependabot.yml' -not -path './.github/tool-pins.json' -not -path './.github/egress-allowlist.txt' -not \( -path './docs/*.md' -not -path './docs/*/*' \) -not -name '.gitignore' -print -quit | grep -q .; then
  echo "Only workflows, composites, policy scripts, the tool and egress tables and flat docs may be tracked." >&2
  exit 1
fi
echo "workflow policy: ok"
