#!/usr/bin/env bash
# Mutation tests: each weakening below once passed the policy (an independent review showed it).
# The repository's .github/ and docs/ are copied, one weakening is applied as a literal edit, and
# the offline policy (every check that needs no network) must reject it. The last case proves the
# base-policy pass of validate-public-changes.yml: a pull request that weakens a check and
# exploits it in the same change passes its own copy of the policy, and fails the base's.
# Run from the repository root.
#
# MUTATION_POLICY=<dir> runs every case against another copy of .github/policy (for example an
# older commit's) and MUTATION_REPORT=1 lists each verdict instead of stopping at the first
# mutation that is not rejected.
set -euo pipefail

src="${PWD}"
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
policy_source="${MUTATION_POLICY:-${src}/.github/policy}"
missed=0

# The offline policy, in the order the cheap checks fail first. Prints the first check that
# rejects the tree and returns non-zero; returns zero when every check passes.
offline_policy() {
  local check
  for check in check-universal.rb test-revoke.sh test-preflight.sh check-workflows.sh check-sizes.sh test-policy.sh test-vuln-gate.sh check-tools.sh check-egress-allowlist.sh; do
    [[ -f ".github/policy/${check}" ]] || continue
    case "${check}" in
      *.rb) ruby ".github/policy/${check}" >>"${dir}/log" 2>&1 ;;
      *) bash ".github/policy/${check}" >>"${dir}/log" 2>&1 ;;
    esac || { printf '%s' "${check}"; return 1; }
  done
}
# fresh_tree [policy-dir]: a copy of this repository's tree with the given policy (default: the
# policy under test).
fresh_tree() {
  rm -rf "${dir}/tree"; mkdir -p "${dir}/tree"
  cp -R "${src}/.github" "${src}/docs" "${dir}/tree/"
  rm -rf "${dir}/tree/.github/policy"; cp -R "${1:-${policy_source}}" "${dir}/tree/.github/policy"
}
# swap FILE OLD NEW: replace the first occurrence of OLD, failing if it is not there (a stale
# mutation must not pass by testing nothing).
swap() {
  OLD="$2" NEW="$3" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("mutation text not found in #{ARGV[0]}: #{ENV["OLD"][0, 80]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "${dir}/tree/$1"
}
verdict() {
  local label="$1" by="$2"
  if [[ -n "${by}" ]]; then
    echo "rejected  ${label}  (by ${by})"
  else
    echo "PASSED    ${label}" >&2
    missed=$((missed + 1))
    [[ -n "${MUTATION_REPORT:-}" ]] || { tail -n 20 "${dir}/log" >&2; exit 1; }
  fi
}
# mutation LABEL FILE OLD NEW [FILE OLD NEW ...]: apply every edit, then expect a rejection.
mutation() {
  local label="$1" by=''; shift
  fresh_tree
  while (( $# )); do swap "$1" "$2" "$3"; shift 3; done
  : > "${dir}/log"
  by="$(cd "${dir}/tree" && offline_policy)" || true
  verdict "${label}" "${by}"
}

# The unmutated tree must pass, or every rejection below would prove nothing.
fresh_tree; : > "${dir}/log"
if ! (cd "${dir}/tree" && offline_policy >/dev/null); then
  echo 'the unmutated tree fails the offline policy:' >&2; tail -n 20 "${dir}/log" >&2; exit 1
fi

concern=.github/workflows/validation-concern.yml
dispatcher=.github/workflows/validation.yml
public=.github/workflows/validate-public-changes.yml
revoke_curl='          if ! curl --fail --silent --show-error --retry 5 --retry-delay 2 --retry-max-time 60 --retry-all-errors -X DELETE'

mutation '1. the concern no longer needs the pre-flight job' "${dispatcher}" '    needs: validate-input
' ''
mutation '1. the concern runs past a failed pre-flight' "${dispatcher}" '    needs: validate-input
' '    needs: validate-input
    if: always()
'
mutation '2. exit 0 at the start of verify-and-revoke' "${concern}" '          set +x
          failed=0
' '          set +x
          exit 0
          failed=0
'
mutation '2. exit 0 just before the revoke' "${concern}" "${revoke_curl}" "          exit 0
${revoke_curl}"
mutation '2. the revoke made best-effort' "${concern}" "            echo 'Source token revocation failed; refusing to execute project code' >&2
            failed=1" "            echo 'Source token revocation failed; refusing to execute project code' >&2"
mutation '3. main refusal disabled (ref test)' "${concern}" '          if [[ "${GITHUB_REF}" == refs/heads/main && "${failed}" -eq 0 && "${protected_ancestor}" != true ]]; then' \
  '          if [[ "${GITHUB_REF}" == refs/heads/never && "${failed}" -eq 0 && "${protected_ancestor}" != true ]]; then'
mutation '3. protected ancestry assumed' "${concern}" '          protected_ancestor=false
' '          protected_ancestor=true
'
mutation '4. identity read from another endpoint' "${concern}" '"${GITHUB_API_URL}/repositories/${SOURCE_REPOSITORY_ID}"' '"${GITHUB_API_URL}/repos/${SOURCE_REPOSITORY_OWNER}/${SOURCE_REPOSITORY_NAME}"'
mutation '4. identity id compared with itself' "${concern}" "\"\$(jq -r '.id' <<<\"\${identity}\")\" != \"\${SOURCE_REPOSITORY_ID}\"" "\"\$(jq -r '.id' <<<\"\${identity}\")\" != \"\$(jq -r '.id' <<<\"\${identity}\")\""
mutation '5. an extra permission on the mint' "${concern}" '          permission-contents: read
' '          permission-contents: read
          permission-secrets: read
'
mutation '5. an unreviewed key on the mint' "${concern}" '          permission-contents: read
' '          permission-contents: read
          github-api-url: https://example.invalid
'
mutation '6. toJSON(secrets) in the concern' "${concern}" '      - name: Report concern duration
        if: ${{ always() }}
        shell: bash
' '      - name: Report concern duration
        if: ${{ always() }}
        shell: bash
        env:
          ALL: ${{ toJSON(secrets) }}
'
mutation '6. toJSON(vars) in the public policy workflow' "${public}" '        run: bash .github/policy/check-repository.sh' '        env:
          ALL: ${{ toJSON(vars) }}
        run: bash .github/policy/check-repository.sh'
mutation '6. a bare secrets context in the dispatcher' "${dispatcher}" '      apphost: ${{ inputs.apphost }}' "      apphost: \${{ inputs.apphost && format('{0}', secrets) != '' }}"
mutation '7. an unconditional keep-docker' "${concern}" "keep-docker: \${{ inputs.concern == 'db-containers' || inputs.concern == 'apphost-cold-start' }}" "keep-docker: 'true'"
mutation '8. dispatcher vulnerability_gate default none' "${dispatcher}" '        default: high
        type: choice' '        default: none
        type: choice'
mutation '8. concern vulnerability_gate default none' "${concern}" '        default: high
        type: string' '        default: none
        type: string'
mutation '9. exit 0 at the start of the environment pre-flight' "${dispatcher}" '          set -euo pipefail
' '          set -euo pipefail
          exit 0
'
mutation '9. a missing environment accepted' "${dispatcher}" "Refusing before any job enters it.' >&2
            exit 1" "Refusing before any job enters it.' >&2
            exit 0"
mutation '9. protected branches only accepted' "${dispatcher}" "!= \$'false\\ttrue' ]]; then" "== never ]]; then"
mutation '9. any branch-policy list accepted' "${dispatcher}" "!= 'branch:main,branch:untrusted' ]]; then" "== never ]]; then"
mutation 'untrusted behind main with a later .github/ change accepted' "${concern}" '                if [[ "${github_changes}" != 0 ]]; then' '                if [[ "${github_changes}" == never ]]; then'
mutation 'vulnerability exception review-by cap lifted' .github/actions/supply-chain/action.yml 'VG_MAX_REVIEW_DAYS=90' 'VG_MAX_REVIEW_DAYS=3650000'
mutation 'vulnerability exception calendar check loosened' .github/actions/supply-chain/action.yml '(( y >= 1970 && d >= 1 && d <= last )) || return 1' '(( y >= 1970 && d >= 1 && d <= 31 )) || return 1'

# 10. Self-editing policy. A pull request quietly exempts the concern from rule 6 in its own copy
# of the policy (the rule's fixtures, which use other files, still pass) and adds a
# toJSON(secrets) read to the concern in the same change: its own policy passes, and the base
# policy (this commit's, which the pull_request run checks out from the base SHA) rejects it.
if [[ -z "${MUTATION_POLICY:-}" ]]; then
  cp -R "${src}/.github/policy" "${dir}/base-policy"
  fresh_tree
  swap .github/policy/check-universal.rb '  expressions(doc).each do |expr|
' "  expressions(doc).each do |expr|
    next if rel == '${concern}'
"
  swap "${concern}" '      - name: Report concern duration
        if: ${{ always() }}
        shell: bash
' '      - name: Report concern duration
        if: ${{ always() }}
        shell: bash
        env:
          ALL: ${{ toJSON(secrets) }}
'
  : > "${dir}/log"
  if ! own="$(cd "${dir}/tree" && offline_policy)"; then
    echo "10. the weakened pull request should pass its own policy, but ${own} rejected it" >&2; tail -n 20 "${dir}/log" >&2; exit 1
  fi
  rm -rf "${dir}/tree/.github/policy"; cp -R "${dir}/base-policy" "${dir}/tree/.github/policy"
  : > "${dir}/log"
  by="$(cd "${dir}/tree" && offline_policy)" || true
  verdict '10. a pull request that weakens its own policy (own policy passes; base policy run)' "${by}"
fi

(( missed == 0 )) || { echo "${missed} mutation(s) passed the policy" >&2; exit 1; }
echo 'mutation tests: every reviewed weakening is rejected by the offline policy'
