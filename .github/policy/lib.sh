#!/usr/bin/env bash
# Shared functions for check-workflows.sh (sourced, not run).

# Token-revocation ordering, checked structurally from the parsed YAML: in every job that enters
# the source-read environment, a step that revokes the short-lived source token (it calls the
# installation/token endpoint) must exist, must run under `if: always()`, and every step before it
# may only check out, mint the token or run non-project shell.
check_revocation_order() {
  ruby .github/policy/revocation-order.rb "$1"
}

# Root removal ordering (finding H2): every source-read job calls the drop-root composite once,
# after the revoke; only reviewed root-needing steps sit between the two, and nothing after
# drop-root calls sudo (or Docker, unless that job keeps Docker). See drop-root-order.rb.
check_drop_root_order() {
  ruby .github/policy/drop-root-order.rb "$1"
}

# Local composite actions. Held to the same rules as workflows where they apply (the Action
# allow-list and SHA pins run for every file), plus: a composite may not use secrets or variables
# (it receives them as inputs), OIDC, artifacts or any cache; it must be `runs.using: composite`,
# every run step must name its shell, and no run script may contain an inline GitHub expression
# (inputs reach scripts through env: only, so an input can never be interpreted as shell code).
check_composite_action() {
  if grep -nE 'secrets\.|vars\.|id-token:|actions/(upload|download)-artifact|actions/cache' "$1"; then
    echo "A composite action may not use secrets, variables, OIDC, artifacts or a cache: $1" >&2
    return 1
  fi
  check_builtin_cache_off "$1" || return 1
  ruby .github/policy/composite-action.rb "$1"
}
