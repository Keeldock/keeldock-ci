#!/usr/bin/env bash
# The reviewed NuGet package cache policy (sourced).

# Finding H1 (2026-10-05), with ref isolation: unprotected SHAs run from the untrusted ref,
# whose cache scope main never reads, and main runs only protected-ancestry SHAs. So the NuGet
# cache runs only on main for a protected source SHA: every restore and save has both exact
# top-level terms below, and no `||` at the top level (which would re-open the gate).
cache_gated_to_protected_main() {
  local cond="$1"
  cond_requires "$cond" "github.ref == 'refs/heads/main'" \
    && cond_requires "$cond" "steps.verified-source.outputs.protected-ancestor == 'true'"
}
GATE_RULE="runs only on main for a protected source SHA (ref isolation, finding H1): the step must have the top-level terms github.ref == 'refs/heads/main' and steps.verified-source.outputs.protected-ancestor == 'true', with no unparenthesised ||"

# Built-in action caches (finding H1 extended). `setup-node` (v5 and later) and the other
# `setup-*` actions restore the package manager's downloads from the same cache scope an
# unprotected run can write, and their restore extracts with absolute paths exactly as
# actions/cache does. So every setup-node step must say `package-manager-cache: false`, and no
# step may turn a setup-* cache on with `cache:`, `cache-dependency-path:` or `cache-read-only:`.
# Prints the offending step and returns 1.
check_builtin_cache_off() {
  local file="$1"
  if grep -nE '^[[:space:]]+(cache|cache-dependency-path|cache-read-only|cache-write-only):' "$file"; then
    echo "A setup action's built-in cache is disabled until ref isolation exists (finding H1): $file" >&2
    return 1
  fi
  if ! awk '
    function flush() { if (need && !off) { print "setup-node step without package-manager-cache: false at line " need; bad = 1 } need = 0; off = 0 }
    /^[[:space:]]*- / { flush() }
    /uses:[[:space:]]*actions\/setup-node@/ { need = NR }
    /^[[:space:]]+package-manager-cache:[[:space:]]*false[[:space:]]*$/ { off = 1 }
    END { flush(); exit bad }
  ' "$file"; then
    echo "Every setup-node step must set package-manager-cache: false (finding H1): $file" >&2
    return 1
  fi
}

# The top-level conjuncts of an `if:` condition, one per line. The `${{ }}` wrapper is
# dropped, every parenthesised group (a call's arguments, an `(a || b)` alternative, a
# negated `!(...)`) is removed whole, and what remains is split on `&&`. A required term
# therefore counts only when it stands alone at the top level: `(x == 'true' || true)`,
# `!(x == 'true')` and `x == 'true' || true` do not yield the exact term `x == 'true'`.
# Returns 1 (no output) when an `||` remains at the top level.
cond_top_terms() {
  local flat="$1" term
  flat="${flat#*if:}"
  flat="${flat#"${flat%%[![:space:]]*}"}"
  flat="${flat%"${flat##*[![:space:]]}"}"
  if [[ "$flat" == '${{'*'}}' ]]; then
    flat="${flat#'${{'}"; flat="${flat%'}}'}"
  fi
  while [[ "$flat" =~ \([^()]*\) ]]; do
    flat="${flat//"${BASH_REMATCH[0]}"/}"
  done
  [[ "$flat" != *'||'* ]] || return 1
  while IFS= read -r term; do
    term="${term#"${term%%[![:space:]]*}"}"
    term="${term%"${term##*[![:space:]]}"}"
    printf '%s\n' "$term"
  done <<<"${flat//&&/$'\n'}"
}

# True when the condition has the exact top-level conjunct $2.
cond_requires() {
  local terms
  terms="$(cond_top_terms "$1")" || return 1
  grep -qxF -- "$2" <<<"$terms"
}

check_cache_policy() {
  local workflow="$1" cache_line save_if cond key

  # A setup action's built-in cache is off as well (check_builtin_cache_off).
  check_builtin_cache_off "$workflow" || exit 1

  # Cache policy (a deliberate, narrow exception). Source-bearing jobs may use ONLY
  # actions/cache/restore and actions/cache/save (never the combined actions/cache, whose implicit
  # post-step save cannot be conditioned or audited), and ONLY for NuGet's downloaded third-party
  # package folder (~/.nuget/packages): never bin/, obj/, publish output or anything under the
  # checked-out private source. Each restored .nupkg is re-hashed against the private
  # packages.lock.json contentHash and the extracted folders are discarded before use.
  if grep -nE 'actions/cache([^/]|$)|actions/cache/(restore|save)@' "$workflow" | grep -vE 'actions/cache/(restore|save)@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6\.1\.0$'; then
    echo "Only the reviewed pinned actions/cache/restore and actions/cache/save are allowed in source-bearing workflows: $workflow" >&2
    exit 1
  fi
  grep -qE 'actions/cache/' "$workflow" || return 0
  while IFS= read -r cache_line; do
    # shellcheck disable=SC2088 # the literal text of the workflow's path line, not a path to expand
    if [[ "$cache_line" != '~/.nuget/packages' ]]; then
      echo "Disallowed cache path line (only ~/.nuget/packages): $cache_line" >&2
      exit 1
    fi
  done < <(awk '
    /^      - name:/ { in_cache = 0; in_path = 0 }
    /uses:[[:space:]]*actions\/cache\// { in_cache = 1; next }
    in_cache && /^[[:space:]]+path:/ { in_path = 1; next }
    in_cache && in_path && /^[[:space:]]+(key|restore-keys|enableCrossOsArchive|fail-on-cache-miss|lookup-only):/ { in_path = 0 }
    in_cache && in_path && NF { sub(/^[[:space:]]+/, ""); print }
  ' "$workflow")
  if grep -nE 'enableCrossOsArchive|fail-on-cache-miss|lookup-only' "$workflow"; then
    echo "Unexpected cache option in $workflow" >&2
    exit 1
  fi
  if ! grep -q 'Verify restored NuGet packages against the lock files' "$workflow"; then
    echo "A restored NuGet cache must be verified against packages.lock.json before use: $workflow" >&2
    exit 1
  fi
  # Every save: on main, on a miss, with the protected-ancestry answer, all as exact top-level
  # terms (an `||` outside parentheses would let one alternative skip a guard).
  if ! grep -qE "github\.ref == 'refs/heads/main' &&.*cache-hit != 'true'" "$workflow"; then
    echo "actions/cache/save must be guarded by the main branch and a cache miss: $workflow" >&2
    exit 1
  fi
  while IFS= read -r save_if; do
    if ! cond_requires "$save_if" "github.ref == 'refs/heads/main'"; then
      echo "The cache save condition must require the main branch as a top-level term, with no unparenthesised ||: $save_if" >&2
      exit 1
    fi
    if ! cond_requires "$save_if" "steps.verified-source.outputs.protected-ancestor == 'true'"; then
      echo "A cache save must require the protected-ancestry answer as an exact top-level term: $save_if" >&2
      exit 1
    fi
  done < <(awk '/^      - name:/ { cond = "" } /^[[:space:]]+if:/ { cond = $0 } /uses:[[:space:]]*actions\/cache\/save@/ { print cond }' "$workflow")
  # Every restore and save runs only on main for a protected source SHA, and the save key is the
  # restore step's primary key (computed before project code), never a hashFiles evaluated after.
  while IFS='|' read -r cond key; do
    if ! cache_gated_to_protected_main "$cond"; then
      echo "The NuGet cache ${GATE_RULE}: $cond" >&2
      exit 1
    fi
    if [[ -n "$key" && "$key" != *'key: ${{ steps.nuget-packages.outputs.cache-primary-key }}' ]]; then
      echo "The NuGet cache save key must be the restore step's cache-primary-key: $key" >&2
      exit 1
    fi
  done < <(awk '
    function flush() { if (cache) print (cond == "" ? "<no if>" : cond) "|" (kind == "save" ? key : ""); cache = 0; key = ""; cond = ""; kind = "" }
    /^      - name:/ { flush() }
    /^[[:space:]]+if:/ { cond = $0 }
    /uses:[[:space:]]*actions\/cache\/save@/ { cache = 1; kind = "save" }
    /uses:[[:space:]]*actions\/cache\/restore@/ { cache = 1; kind = "restore" }
    /^[[:space:]]+key:/ { key = $0 }
    END { flush() }
  ' "$workflow")
  if grep -nE '^[[:space:]]+path:.*(bin|obj|publish|artifacts)([/[:space:]]|$)' "$workflow"; then
    echo "The NuGet cache must never name build or publish output: $workflow" >&2
    exit 1
  fi
}
