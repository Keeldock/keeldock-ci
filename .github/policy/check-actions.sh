#!/usr/bin/env bash
# Action references: every `uses:` is a full commit SHA and an exact reviewed reference (sourced).

check_action_references() {
  local workflow="$1" reference

  if grep -nE '^\s*uses:\s*[^#[:space:]]+@(v[0-9]|main|master|stable|latest|[[:alnum:]_.-]+)$' "$workflow"; then
    echo "Every Action reference must use a full 40-character commit SHA: $workflow" >&2
    exit 1
  fi

  while IFS= read -r reference; do
    case "$reference" in
      actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1) ;;
      # The one reviewed cache exception (actions/cache v6.1.0), split into restore and save so
      # each use is explicit. check-cache-policy.sh limits both to the NuGet package folder.
      actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9) ;;
      actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9) ;;
      actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1) ;;
      actions/setup-node@820762786026740c76f36085b0efc47a31fe5020) ;;
      actions/setup-dotnet@a98b56852c35b8e3190ac28c8c2271da59106c68) ;;
      ./.github/workflows/validation-concern.yml) ;;
      # Local composite actions are reviewed in this repository; each one is added here
      # deliberately and held to the composite rules in lib.sh.
      ./.github/actions/restore) ;;
      ./.github/actions/nuget-verify) ;;
      ./.github/actions/postgres-start) ;;
      ./.github/actions/build-format) ;;
      ./.github/actions/test-suites) ;;
      ./.github/actions/supply-chain) ;;
      ./.github/actions/apphost) ;;
      ./.github/actions/contracts-publish) ;;
      ./.github/actions/summary) ;;
      ./.github/actions/proof) ;;
      ./.github/actions/timings) ;;
      ./.github/actions/egress-audit) ;;
      # Finding H2: the removal of root before project code.
      ./.github/actions/drop-root) ;;
      '') ;;
      *)
        echo "Unreviewed or mutable Action reference in $workflow: $reference" >&2
        exit 1
        ;;
    esac
  done < <(sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^#[:space:]]+).*/\1/p' "$workflow")
}
