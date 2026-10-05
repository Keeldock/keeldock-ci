#!/usr/bin/env bash
# The protected dispatcher and every other public workflow (sourced).

check_dispatcher() {
  local workflow="$1" protected_dispatch dispatch_workflow calls

  protected_dispatch=0
  for dispatch_workflow in "${protected_dispatch_workflows[@]}"; do
    if [[ "$workflow" == "$dispatch_workflow" || "$workflow" == "./$dispatch_workflow" ]]; then
      protected_dispatch=1
      break
    fi
  done
  if (( ! protected_dispatch )); then
    # Any other workflow (the public policy gate) gets no secret, environment, cache, artifact,
    # OIDC or reusable-call surface at all.
    if grep -nE 'pull_request_target:|workflow_run:|workflow_call:|actions/(upload|download)-artifact|actions/cache|id-token:[[:space:]]*write|secrets\.|vars\.|^[[:space:]]+environment:' "$workflow"; then
      echo "Unsafe trigger, artifact/cache path, OIDC grant, secret, variable or environment in a public workflow: $workflow" >&2
      exit 1
    fi
    return 0
  fi
  if ! grep -qE '^on:[[:space:]]*$' "$workflow" || ! grep -qE '^[[:space:]]+workflow_dispatch:[[:space:]]*$' "$workflow"; then
    echo "The protected dispatcher must be workflow_dispatch-only: $workflow" >&2
    exit 1
  fi
  if grep -nE '^[[:space:]]+(pull_request|pull_request_target|push|schedule|workflow_run|repository_dispatch|workflow_call):' "$workflow"; then
    echo "The protected dispatcher has an unapproved trigger: $workflow" >&2
    exit 1
  fi
  if ! grep -qE '^[[:space:]]+source_sha:' "$workflow" || ! grep -qE '\^\[0-9a-fA-F\]\{40\}' "$workflow"; then
    echo "The protected dispatcher must require a full source SHA: $workflow" >&2
    exit 1
  fi
  # The dispatcher passes exactly one secret, the source-reader App key, by name, to the one
  # workflow it calls; it never inherits secrets, and it names its environment exactly once.
  if grep -qE '^[[:space:]]+secrets:[[:space:]]+inherit' "$workflow"; then
    echo "A protected dispatcher must not inherit secrets: $workflow" >&2
    exit 1
  fi
  calls="$(grep -cE '^    uses:' "$workflow")"
  if [[ "${calls}" != 1 ]] || ! grep -qE '^    uses:[[:space:]]+\./\.github/workflows/validation-concern\.yml([[:space:]]|$)' "$workflow"; then
    echo "The protected dispatcher must call exactly the reviewed concern workflow: $workflow" >&2
    exit 1
  fi
  if [[ "$(grep -cE '^      [A-Z_]+:[[:space:]]+\$\{\{ secrets\.' "$workflow")" != 1 ]] \
    || ! grep -qE '^      SOURCE_READER_PRIVATE_KEY:[[:space:]]+\$\{\{ secrets\.SOURCE_READER_PRIVATE_KEY \}\}[[:space:]]*$' "$workflow" \
    || [[ "$(grep -oE 'secrets\.[A-Za-z0-9_]+' "$workflow" | sort -u)" != 'secrets.SOURCE_READER_PRIVATE_KEY' ]]; then
    echo "The protected dispatcher must pass exactly secrets.SOURCE_READER_PRIVATE_KEY, by name: $workflow" >&2
    exit 1
  fi
  if grep -qE 'vars\.' "$workflow"; then
    echo "The protected dispatcher reads no variable (the App id is read in the environment): $workflow" >&2
    exit 1
  fi
  if [[ "$(grep -cE '^[[:space:]]+environment:[[:space:]]+source-read[[:space:]]*(#.*)?$' "$workflow")" != 1 ]] \
    || [[ "$(grep -cE '^[[:space:]]+environment:' "$workflow")" != 1 ]]; then
    echo "The protected dispatcher must name its environment once, as source-read: $workflow" >&2
    exit 1
  fi
  # Before any job enters source-read, the dispatcher proves the environment exists and is
  # limited to protected branches, so a first run can never create it unprotected.
  if ! grep -qF '/environments/source-read' "$workflow" || ! grep -qF 'deployment_branch_policy.protected_branches' "$workflow"; then
    echo "The protected dispatcher must verify the source-read environment before calling the concern: $workflow" >&2
    exit 1
  fi
}
