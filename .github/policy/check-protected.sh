#!/usr/bin/env bash
# Source-bearing workflow checks (sourced).

check_protected_source() {
  local workflow="$1" reusable_protected reusable_workflow secret_reference variable_reference

  check_revocation_order "$workflow" || { echo "Token revocation ordering violated: $workflow" >&2; exit 1; }
  check_drop_root_order "$workflow" || { echo "Root removal ordering violated: $workflow" >&2; exit 1; }
  reusable_protected=0
  for reusable_workflow in "${reusable_protected_workflows[@]}"; do
    if [[ "$workflow" == "$reusable_workflow" || "$workflow" == "./$reusable_workflow" ]]; then
      reusable_protected=1
      break
    fi
  done
  if (( reusable_protected )); then
    if ! grep -qE '^on:[[:space:]]*$' "$workflow" || ! grep -qE '^[[:space:]]+workflow_call:[[:space:]]*$' "$workflow"; then
      echo "The protected reusable workflow must be workflow_call-only: $workflow" >&2
      exit 1
    fi
    if grep -nE '^[[:space:]]+(pull_request|pull_request_target|push|schedule|workflow_run|repository_dispatch|workflow_dispatch):' "$workflow"; then
      echo "The protected reusable workflow has an unapproved trigger: $workflow" >&2
      exit 1
    fi
  else
    if ! grep -qE '^on:[[:space:]]*$' "$workflow" || ! grep -qE '^[[:space:]]+workflow_dispatch:[[:space:]]*$' "$workflow"; then
      echo "The protected source workflow must be workflow_dispatch-only: $workflow" >&2
      exit 1
    fi
    if grep -nE '^[[:space:]]+(pull_request|pull_request_target|push|schedule|workflow_run|repository_dispatch|workflow_call):' "$workflow"; then
      echo "The source-read workflow has an unapproved trigger: $workflow" >&2
      exit 1
    fi
  fi
  # The concern takes its environment as an input; its dispatcher's value (source-read, named
  # once) is checked in check-dispatchers.sh.
  if ! grep -qE '^    environment:[[:space:]]+(source-read|\$\{\{ inputs\.environment \}\})[[:space:]]*$' "$workflow"; then
    echo "The protected source workflow must use the protected source-read environment: $workflow" >&2
    exit 1
  fi
  if ! grep -qE 'SOURCE_REPOSITORY_ID:[[:space:]]*['"'"']?[0-9]{7,}['"'"']?[[:space:]]*$' "$workflow"; then
    echo "The source-read workflow must pin a numeric source repository ID: $workflow" >&2
    exit 1
  fi
  if ! grep -qE '^[[:space:]]+source_sha:' "$workflow" || ! grep -qE '\^\[0-9a-fA-F\]\{40\}' "$workflow"; then
    echo "The source-read workflow must require and validate a full source SHA: $workflow" >&2
    exit 1
  fi
  if ! grep -qE 'SOURCE_READER_PRIVATE_KEY' "$workflow" || ! grep -qE 'SOURCE_READER_APP_ID' "$workflow"; then
    echo "The protected source workflow must use only the reviewed source-reader settings: $workflow" >&2
    exit 1
  fi
  if grep -nE 'id-token:[[:space:]]*write|actions/(upload|download)-artifact|secrets\[[^]]+\]' "$workflow"; then
    echo "The source-read workflow contains an unsafe secret, OIDC, or artifact pattern: $workflow" >&2
    exit 1
  fi
  check_cache_policy "$workflow"
  while IFS= read -r secret_reference; do
    case "$secret_reference" in
      secrets.SOURCE_READER_PRIVATE_KEY) ;;
      '') ;;
      *)
        echo "The source-read workflow references an unapproved secret: $secret_reference" >&2
        exit 1
        ;;
    esac
  done < <(grep -oE 'secrets\.[A-Za-z0-9_]+' "$workflow" | sort -u)
  while IFS= read -r variable_reference; do
    case "$variable_reference" in
      vars.SOURCE_READER_APP_ID) ;;
      '') ;;
      *)
        echo "The source-read workflow references an unapproved variable: $variable_reference" >&2
        exit 1
        ;;
    esac
  done < <(grep -oE 'vars\.[A-Za-z0-9_]+' "$workflow" | sort -u)
  if ! grep -qE 'skip-token-revoke:[[:space:]]*true' "$workflow" || ! grep -qE 'installation/token' "$workflow"; then
    echo "The source-read workflow must explicitly revoke its token before project code: $workflow" >&2
    exit 1
  fi
  check_concern "$workflow"
}
