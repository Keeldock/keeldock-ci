#!/usr/bin/env bash
# Fixture tests for the universal rules (check-universal.rb) and the size limits
# (check-sizes.sh): each rule is shown to accept a compliant tree and to reject a tree that
# breaks only that rule. Run from the repository root.
set -euo pipefail

policy="${PWD}/.github/policy"
base="$(mktemp -d)"
trap 'rm -rf "${base}"' EXIT
sha=3d3c42e5aac5ba805825da76410c181273ba90b1

# A compliant tree: one ordinary workflow, the reviewed protected job, one composite.
good_tree() {
  local root="$1"
  mkdir -p "${root}/.github/workflows" "${root}/.github/actions/demo"
  cat > "${root}/.github/workflows/ordinary.yml" <<YAML
name: ordinary
on:
  workflow_dispatch:
permissions: {}
jobs:
  build:
    runs-on: ubuntu-24.04
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@${sha}
YAML
  cat > "${root}/.github/workflows/validation-concern.yml" <<YAML
name: protected
on:
  workflow_call:
    inputs:
      vulnerability_gate:
        type: string
        default: high
permissions: {}
jobs:
  validate:
    runs-on: ubuntu-24.04
    environment: \${{ inputs.environment }}
    steps:
      - uses: actions/checkout@${sha}
      - name: Mint read-only private-source token
        uses: actions/create-github-app-token@${sha}
        with:
          client-id: \${{ vars.SOURCE_READER_APP_ID }}
          private-key: \${{ secrets.SOURCE_READER_PRIVATE_KEY }}
          owner: \${{ env.SOURCE_REPOSITORY_OWNER }}
          repositories: \${{ env.SOURCE_REPOSITORY_NAME }}
          permission-contents: read
          skip-token-revoke: true
      - uses: ./.github/actions/drop-root
        with:
          keep-docker: \${{ inputs.concern == 'db-containers' || inputs.concern == 'apphost-cold-start' }}
      - uses: ./.github/actions/supply-chain
        with:
          vulnerability-gate: \${{ inputs.vulnerability_gate }}
YAML
  cat > "${root}/.github/workflows/validation.yml" <<YAML
name: dispatcher
on:
  workflow_dispatch:
    inputs:
      vulnerability_gate:
        type: choice
        default: high
        options: [none, high, critical]
permissions: {}
jobs:
  validate-input:
    runs-on: ubuntu-24.04
    steps:
      - run: echo checked
  validate:
    needs: validate-input
    uses: ./.github/workflows/validation-concern.yml
    secrets:
      SOURCE_READER_PRIVATE_KEY: \${{ secrets.SOURCE_READER_PRIVATE_KEY }}
    with:
      vulnerability_gate: \${{ inputs.vulnerability_gate }}
YAML
  cat > "${root}/.github/actions/demo/action.yml" <<YAML
name: demo
description: demo
runs:
  using: composite
  steps:
    - uses: actions/checkout@${sha}
YAML
}

expect_pass() {
  local label="$1" root="$2"
  ruby "${policy}/check-universal.rb" "${root}" >/dev/null 2>"${base}/err" || { echo "fixture '${label}' should pass but failed:" >&2; cat "${base}/err" >&2; exit 1; }
}
expect_fail() {
  local label="$1" root="$2" needle="$3"
  if ruby "${policy}/check-universal.rb" "${root}" >/dev/null 2>"${base}/err"; then
    echo "fixture '${label}' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "${needle}" "${base}/err" || { echo "fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
fresh() { local root="${base}/$1"; rm -rf "${root}"; good_tree "${root}"; echo "${root}"; }
# Applies a perl substitution to one file of a fixture tree.
mutate() { perl -0pi -e "$3" "$1/$2"; }

root="$(fresh good)"; expect_pass 'compliant tree' "${root}"

root="$(fresh unpinned-tag)"; mutate "${root}" .github/workflows/ordinary.yml "s/actions\/checkout\@${sha}/actions\/checkout\@v4/"
expect_fail 'a tag reference' "${root}" 'not pinned to a full 40-character commit SHA'

root="$(fresh unpinned-branch)"; mutate "${root}" .github/workflows/ordinary.yml "s/actions\/checkout\@${sha}/actions\/checkout\@main/"
expect_fail 'a branch reference' "${root}" 'not pinned'

root="$(fresh short-sha)"; mutate "${root}" .github/workflows/ordinary.yml "s/actions\/checkout\@${sha}/actions\/checkout\@3d3c42e/"
expect_fail 'an abbreviated SHA' "${root}" 'not pinned'

root="$(fresh docker-ref)"; mutate "${root}" .github/workflows/ordinary.yml "s/actions\/checkout\@${sha}/docker:\/\/alpine:3.20/"
expect_fail 'a docker reference' "${root}" 'not pinned'

root="$(fresh composite-unpinned)"; mutate "${root}" .github/actions/demo/action.yml "s/actions\/checkout\@${sha}/actions\/checkout\@v4/"
expect_fail 'an unpinned composite step' "${root}" 'actions/demo/action.yml'

root="$(fresh no-permissions)"; mutate "${root}" .github/workflows/ordinary.yml 's/permissions: \{\}\n//'
expect_fail 'no top-level permissions' "${root}" 'no top-level `permissions: {}`'

root="$(fresh broad-permissions)"; mutate "${root}" .github/workflows/ordinary.yml 's/^permissions: \{\}/permissions: read-all/m'
expect_fail 'broad top-level permissions' "${root}" 'no top-level `permissions: {}`'

root="$(fresh prt)"; mutate "${root}" .github/workflows/ordinary.yml 's/  workflow_dispatch:/  pull_request_target:/'
expect_fail 'pull_request_target' "${root}" 'pull_request_target'

root="$(fresh prt-flow)"; mutate "${root}" .github/workflows/ordinary.yml 's/on:\n  workflow_dispatch:/on: [push, pull_request_target]/'
expect_fail 'pull_request_target in a list' "${root}" 'pull_request_target'

root="$(fresh inherit)"
cat >> "${root}/.github/workflows/ordinary.yml" <<'YAML'
  call:
    uses: ./.github/workflows/protected.yml
    secrets: inherit
YAML
expect_fail 'secrets: inherit' "${root}" 'secrets: inherit'

root="$(fresh other-environment)"; mutate "${root}" .github/workflows/ordinary.yml 's/    runs-on: ubuntu-24.04\n    permissions:/    runs-on: ubuntu-24.04\n    environment: source-read\n    permissions:/'
expect_fail 'another job entering source-read' "${root}" 'enters an environment'

root="$(fresh renamed-job)"; mutate "${root}" .github/workflows/validation-concern.yml 's/^  validate:/  other:/m'
expect_fail 'the protected job renamed' "${root}" 'enters an environment'

# Literal edits for the rules below (no regex escaping): swap replaces the first occurrence of
# OLD with NEW, add_after inserts TEXT after the first occurrence of ANCHOR; both fail loudly
# when the text is not found, so a fixture can never silently test nothing.
swap() { OLD="$3" NEW="$4" ruby -e 's = File.read(ARGV[0]); i = s.index(ENV["OLD"]) or abort("fixture text not found: #{ENV["OLD"]}"); s[i, ENV["OLD"].length] = ENV["NEW"]; File.write(ARGV[0], s)' "$1/$2"; }
add_after() { swap "$1" "$2" "$3" "$3$4"; }
checkout_line="      - uses: actions/checkout@${sha}
"

# Whole-context reads (rule 6).
for leak in '${{ toJSON(secrets) }}' '${{ toJSON(vars) }}' '${{ toJSON(github) }}' "\${{ format('{0}', secrets) }}" '${{ secrets[matrix.name] }}' '${{ secrets.* }}' '${{ join(vars) }}'; do
  root="$(fresh whole-context)"; add_after "${root}" .github/workflows/ordinary.yml "${checkout_line}" "        env:
          LEAK: ${leak}
"
  expect_fail "a whole-context read (${leak})" "${root}" 'reads a whole secrets, vars or github context'
done
root="$(fresh bare-if)"; add_after "${root}" .github/workflows/ordinary.yml '  build:
' "    if: toJSON(vars) != '{}'
"
expect_fail 'a whole-context read in a bare if' "${root}" 'reads a whole secrets, vars or github context'
root="$(fresh whole-context-composite)"; add_after "${root}" .github/actions/demo/action.yml "    - uses: actions/checkout@${sha}
" '      with:
        token: ${{ toJSON(secrets) }}
'
expect_fail 'a whole-context read in a composite' "${root}" 'actions/demo/action.yml: an expression reads a whole'
root="$(fresh named-member)"; add_after "${root}" .github/workflows/ordinary.yml "${checkout_line}" "        env:
          OK: \${{ vars.SOURCE_READER_APP_ID }} \${{ matrix.vars }} \${{ format('secrets') }}
"
expect_pass 'named members and a quoted word are not whole-context reads' "${root}"

# The token mint is an exact allow-list (rule 7).
mint_case() {
  local label="$1" old="$2" new="$3"
  root="$(fresh mint)"; swap "${root}" .github/workflows/validation-concern.yml "${old}" "${new}"
  expect_fail "a token mint outside the allow-list (${label})" "${root}" 'is not a reviewed `with:` map'
}
mint_case 'an extra permission' '          permission-contents: read
' '          permission-contents: read
          permission-actions: write
'
mint_case 'contents write' 'permission-contents: read' 'permission-contents: write'
mint_case 'another owner' 'owner: ${{ env.SOURCE_REPOSITORY_OWNER }}' 'owner: Moh-Bakr'
mint_case 'another repository' 'repositories: ${{ env.SOURCE_REPOSITORY_NAME }}' 'repositories: keeldock-cloud,other'
mint_case 'no skip-token-revoke' '          skip-token-revoke: true
' ''
mint_case 'an unreviewed key' '          permission-contents: read
' '          permission-contents: read
          github-api-url: https://example.invalid
'
root="$(fresh app-id)"; swap "${root}" .github/workflows/validation-concern.yml 'client-id:' 'app-id:'
expect_pass 'app-id is the reviewed alias of client-id' "${root}"
root="$(fresh mint-elsewhere)"; add_after "${root}" .github/workflows/ordinary.yml "${checkout_line}" "      - uses: actions/create-github-app-token@${sha}
"
expect_fail 'a mint in an unreviewed file' "${root}" 'ordinary.yml: token mint'
root="$(fresh no-mint)"; swap "${root}" .github/workflows/validation-concern.yml "uses: actions/create-github-app-token@${sha}" "uses: actions/checkout@${sha}"
expect_fail 'the reviewed mint removed' "${root}" 'the reviewed token mint is missing'

# keep-docker is absent or the reviewed expression (rule 8).
reviewed_keep="\${{ inputs.concern == 'db-containers' || inputs.concern == 'apphost-cold-start' }}"
for keep in "'true'" 'true' '${{ true }}' "\${{ inputs.concern != 'unit' }}" "${reviewed_keep} || true"; do
  root="$(fresh keep-docker)"; swap "${root}" .github/workflows/validation-concern.yml "keep-docker: ${reviewed_keep}" "keep-docker: ${keep}"
  expect_fail "keep-docker ${keep}" "${root}" 'keep-docker must be absent or the reviewed expression'
done
root="$(fresh keep-docker-absent)"; swap "${root}" .github/workflows/validation-concern.yml "        with:
          keep-docker: ${reviewed_keep}
" ''
expect_pass 'keep-docker absent' "${root}"

# The dispatcher's pre-flight gates the concern (rule 9).
root="$(fresh no-needs)"; swap "${root}" .github/workflows/validation.yml '    needs: validate-input
' ''
expect_fail 'the concern no longer needs the pre-flight' "${root}" 'must need the pre-flight job validate-input directly'
root="$(fresh needs-other)"; swap "${root}" .github/workflows/validation.yml 'needs: validate-input' 'needs: [other]'
expect_fail 'the concern needs another job' "${root}" 'must need the pre-flight job'
for past in '${{ always() }}' 'always()' '${{ !cancelled() }}' 'failure() || success()'; do
  root="$(fresh needs-always)"; add_after "${root}" .github/workflows/validation.yml '    needs: validate-input
' "    if: ${past}
"
  expect_fail "the concern runs past a failed pre-flight (${past})" "${root}" 'may not run past a failed pre-flight'
done
root="$(fresh preflight-continue)"; add_after "${root}" .github/workflows/validation.yml '  validate-input:
' '    continue-on-error: true
'
expect_fail 'the pre-flight continues on error' "${root}" 'must not continue on error'
root="$(fresh preflight-gone)"; swap "${root}" .github/workflows/validation.yml '  validate-input:' '  checks:'
expect_fail 'the pre-flight job renamed away' "${root}" 'the reviewed pre-flight job validate-input is missing'

# The vulnerability gate defaults to high and is passed through (rule 10).
for file in validation.yml validation-concern.yml; do
  for gate in none critical "''"; do
    root="$(fresh gate-default)"; swap "${root}" ".github/workflows/${file}" 'default: high' "default: ${gate}"
    expect_fail "${file} vulnerability_gate default ${gate}" "${root}" 'input vulnerability_gate must default to "high"'
  done
done
root="$(fresh gate-pass)"; swap "${root}" .github/workflows/validation.yml 'vulnerability_gate: ${{ inputs.vulnerability_gate }}' 'vulnerability_gate: none'
expect_fail 'the dispatcher hard-codes the gate' "${root}" 'must pass vulnerability_gate'
root="$(fresh gate-pass-composite)"; swap "${root}" .github/workflows/validation-concern.yml 'vulnerability-gate: ${{ inputs.vulnerability_gate }}' 'vulnerability-gate: none'
expect_fail 'the concern hard-codes the gate' "${root}" 'must pass vulnerability-gate'
echo 'hardening fixtures: whole-context reads, unreviewed mints, keep-docker, an ungated concern and a weaker gate default are rejected'

# Size limits.
size_root="${base}/sizes"
mkdir -p "${size_root}/.github/workflows" "${size_root}/.github/actions"
printf 'name: x\n' > "${size_root}/.github/workflows/small.yml"
bash "${policy}/check-sizes.sh" "${size_root}" >/dev/null
awk 'BEGIN { for (i = 0; i < 450; i++) print "# line " i }' > "${size_root}/.github/workflows/medium.yml"
out="$(bash "${policy}/check-sizes.sh" "${size_root}")"
grep -qF 'large workflow file' <<<"${out}" || { echo 'a file over 400 lines should warn' >&2; exit 1; }
awk 'BEGIN { for (i = 0; i < 850; i++) print "# line " i }' > "${size_root}/.github/workflows/large.yml"
if bash "${policy}/check-sizes.sh" "${size_root}" >/dev/null 2>&1; then
  echo 'a file over 800 lines should fail' >&2
  exit 1
fi

echo 'policy fixtures: every universal rule and size limit accepts a compliant tree and rejects its violation'

# A built-in setup cache: setup-node without the opt-out, or a `cache:` input.
node_fixture="${base}/node-cache.yml"
printf '      - name: Set up Node\n        uses: actions/setup-node@x\n        with:\n          package-manager-cache: false\n' > "${base}/node-good.yml"
(source "${policy}/check-cache-policy.sh"; check_builtin_cache_off "${base}/node-good.yml") >/dev/null || { echo 'a setup-node step with the opt-out should pass' >&2; exit 1; }
for mutation in 's/^( +)package-manager-cache: false\n//m' 's/^( +)package-manager-cache: false$/$1package-manager-cache: false\n$1cache: npm/m'; do
  perl -0pe "${mutation}" "${base}/node-good.yml" > "${node_fixture}"
  if (source "${policy}/check-cache-policy.sh"; check_builtin_cache_off "${node_fixture}") >/dev/null 2>&1; then
    echo "a setup-node built-in cache fixture should fail but passed" >&2
    exit 1
  fi
done

# The NuGet cache: the reviewed concern passes; a restore outside protected main, a save
# without the protected-ancestry answer and a save key evaluated after project code fail. The
# policy recognises the concern by its repository path, so each fixture is checked from its own
# root under that path.
nuget_root="${base}/nuget"
mkdir -p "${nuget_root}/.github/workflows"
nuget_expect_fail() {
  local label="$1" needle="$2" expr="$3"
  perl -0pe "${expr}" .github/workflows/validation-concern.yml > "${nuget_root}/.github/workflows/validation-concern.yml"
  if (cd "${nuget_root}" && source "${policy}/check-cache-policy.sh" && check_cache_policy .github/workflows/validation-concern.yml) >/dev/null 2>"${base}/err"; then
    echo "NuGet fixture '${label}' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "${needle}" "${base}/err" || { echo "NuGet fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
(source "${policy}/check-cache-policy.sh"; check_cache_policy .github/workflows/validation-concern.yml) || { echo 'the reviewed NuGet cache steps should pass' >&2; exit 1; }
nuget_expect_fail 'NuGet restore without the main guard' 'NuGet cache runs only on main' \
  's/if: \$\{\{ github\.ref == .refs\/heads\/main. && (steps\.verified-source\.outputs\.protected-ancestor == .true. && steps\.verified-source\.outcome)/if: \$\{\{ $1/'
nuget_expect_fail 'NuGet restore gate re-opened by ||' 'NuGet cache runs only on main' \
  's/(if: \$\{\{ github\.ref == [^\n]*steps\.verified-source\.outcome == .success.) \}\}/$1 || true }}/'
nuget_expect_fail 'NuGet save without protected ancestry' 'protected-ancestry answer' \
  's/ && steps\.verified-source\.outputs\.protected-ancestor == .true.( && steps\.nuget-packages\.outputs\.cache-hit)/$1/'
nuget_expect_fail 'a cache path outside the NuGet folder' 'Disallowed cache path line' \
  's#(            ~/\.nuget/packages\n)#$1            src/obj\n#'
nuget_expect_fail 'NuGet save key after project code' 'cache-primary-key' \
  's/key: \$\{\{ steps\.nuget-packages\.outputs\.cache-primary-key \}\}/key: nuget-\$\{\{ runner.os \}\}-\$\{\{ hashFiles(\x27**\/packages.lock.json\x27) \}\}/'
echo 'cache policy fixtures: the NuGet guards reject a cache step outside protected main, an unprotected save and a late save key'

# Root removal (finding H2): the reviewed protected workflows pass, and each drop-root rule
# rejects the one mutation it exists for. The fixture sits in a tree whose composites are this
# repository's own, so the composite sudo scan reads the real actions.
drop_root="${base}/drop-root"
mkdir -p "${drop_root}/.github/workflows"
cp -R "${PWD}/.github/actions" "${drop_root}/.github/actions"
mkdir -p "${drop_root}/.github/actions/fake-sudo"
printf 'name: f\ndescription: f\nruns:\n  using: composite\n  steps:\n    - shell: bash\n      run: sudo true\n' > "${drop_root}/.github/actions/fake-sudo/action.yml"
drop_expect_fail() {
  local label="$1" source="$2" needle="$3" expr="$4"
  perl -0pe "${expr}" "${source}" > "${drop_root}/.github/workflows/fixture.yml"
  if ruby "${policy}/drop-root-order.rb" "${drop_root}/.github/workflows/fixture.yml" >/dev/null 2>"${base}/err"; then
    echo "drop-root fixture '${label}' should fail but passed" >&2
    exit 1
  fi
  grep -qF -- "${needle}" "${base}/err" || { echo "drop-root fixture '${label}' failed with the wrong message:" >&2; cat "${base}/err" >&2; exit 1; }
}
ruby "${policy}/drop-root-order.rb" .github/workflows/validation-concern.yml || { echo 'the reviewed concern should pass the drop-root rules' >&2; exit 1; }
drop_expect_fail 'no drop-root step' .github/workflows/validation-concern.yml 'exactly once' \
  's/        uses: \.\/\.github\/actions\/drop-root[^\n]*\n//'
drop_expect_fail 'a project command before drop-root' .github/workflows/validation-concern.yml 'project command before drop-root' \
  's/(      - name: Remove root before project code\n)/      - name: Early restore\n        shell: bash\n        run: dotnet restore\n\n$1/'
drop_expect_fail 'an unreviewed composite before drop-root' .github/workflows/validation-concern.yml 'only reviewed pre-root steps' \
  's/(      - name: Remove root before project code\n)/      - name: Early restore\n        uses: .\/.github\/actions\/restore\n\n$1/'
drop_expect_fail 'sudo after drop-root' .github/workflows/validation-concern.yml 'calls sudo after drop-root' \
  's/(          \[\[ -n "\$\{CONCERN_STARTED_AT:-\}" \]\] \|\| exit 0\n)/$1          sudo true\n/'
drop_expect_fail 'docker after drop-root once keep-docker is gone' .github/workflows/validation-concern.yml 'calls Docker after drop-root' \
  's/        with:\n          keep-docker: [^\n]*\n//; s/(          \[\[ -n "\$\{CONCERN_STARTED_AT:-\}" \]\] \|\| exit 0\n)/$1          docker ps\n/'
drop_expect_fail 'a sudo composite after drop-root' .github/workflows/validation-concern.yml 'contains sudo and is called after drop-root' \
  's/(      - name: Publish the sub-step summary\n)/      - name: Late privileged start\n        uses: .\/.github\/actions\/fake-sudo\n\n$1/'
echo 'drop-root fixtures: a missing drop, project code or an unreviewed composite before it, and sudo or Docker after it are rejected'

# Ref isolation freshness guard: the reviewed guard (inline in the concern) is extracted and run against a stubbed compare API. identical and
# behind are accepted (behind with a warning naming the sync command); ahead, diverged and an
# unreadable answer are refused, and a run from main is not subject to the guard.
fresh_dir="${base}/freshness"
mkdir -p "${fresh_dir}/bin"
cat > "${fresh_dir}/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
case "${url}" in
  */compare/main...*)
    case "${FAKE_COMPARE_STATUS}" in
      unreadable) exit 22 ;;
      *) printf '{"status":"%s","ahead_by":%s,"behind_by":%s}\n' "${FAKE_COMPARE_STATUS}" "${FAKE_AHEAD_BY:-0}" "${FAKE_BEHIND_BY:-0}" ;;
    esac ;;
  */compare/"${GITHUB_SHA}"...main)
    files="${FAKE_FILES:-}"
    [[ -n "${files}" ]] || files='[{"filename":"docs/how-ci-works.md"}]'
    [[ "${files}" == unreadable ]] && exit 22
    printf '{"status":"ahead","files":%s}\n' "${files}" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "${fresh_dir}/bin/curl"
for guard_file in .github/workflows/validation-concern.yml; do
  ruby -ryaml -e '
    doc = YAML.safe_load(File.read(ARGV[0]), aliases: false)
    steps = doc.dig("runs", "steps") || doc["jobs"].values.flat_map { |j| j["steps"] || [] }
    run = steps.map { |s| s["run"].to_s }.find { |r| r.include?("refs/heads/untrusted ]]") && r.include?("compare/main") }
    abort "no freshness guard in #{ARGV[0]}" unless run
    File.write(ARGV[1], run)' "${guard_file}" "${fresh_dir}/guard.sh"
  freshness_run() {
    local ref="$1" status="$2" ahead="${3:-0}" behind="${4:-0}"
    : > "${fresh_dir}/summary"
    set +e
    PATH="${fresh_dir}/bin:${PATH}" GITHUB_REPOSITORY=Keeldock/keeldock-ci GITHUB_REF="${ref}" \
      SOURCE_READER_APP_ID="${app_id-1234567}" SOURCE_READER_KEY_PRESENT="${key_present-true}" \
      GITHUB_SHA=1111111111111111111111111111111111111111 GITHUB_API_URL=https://api.invalid \
      GITHUB_STEP_SUMMARY="${fresh_dir}/summary" CONTROL_PLANE_TOKEN=unused \
      REQUESTED_SOURCE_SHA=2222222222222222222222222222222222222222 REQUESTED_PLATFORM=linux \
      REQUESTED_CONCERN=unit REQUESTED_VULN_GATE=none \
      FAKE_COMPARE_STATUS="${status}" FAKE_AHEAD_BY="${ahead}" FAKE_BEHIND_BY="${behind}" FAKE_FILES="${FAKE_FILES:-}" \
      bash "${fresh_dir}/guard.sh" >"${fresh_dir}/out" 2>&1
    freshness_rc=$?
    set -e
  }
  freshness_run refs/heads/untrusted identical
  [[ "${freshness_rc}" -eq 0 ]] || { echo "${guard_file}: an identical untrusted should be accepted" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
  freshness_run refs/heads/untrusted behind 0 3
  [[ "${freshness_rc}" -eq 0 ]] || { echo "${guard_file}: a behind untrusted should be accepted" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
  grep -qF '3 commit(s) behind' "${fresh_dir}/summary" && grep -qF 'git push origin origin/main:refs/heads/untrusted' "${fresh_dir}/summary" \
    || { echo "${guard_file}: a behind untrusted should warn with the count and the sync command" >&2; cat "${fresh_dir}/summary" >&2; exit 1; }
  for refused in ahead diverged unreadable; do
    freshness_run refs/heads/untrusted "${refused}" 2 1
    [[ "${freshness_rc}" -ne 0 ]] || { echo "${guard_file}: a ${refused} untrusted should be refused" >&2; exit 1; }
  done
  freshness_run refs/heads/main ahead
  [[ "${freshness_rc}" -eq 0 ]] || { echo "${guard_file}: the guard must not apply to a run from main" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
done
echo 'freshness fixtures: untrusted behind or identical to main is accepted (behind warns); ahead, diverged and unreadable are refused'

# Unconfigured settings: the same pre-mint step refuses, with the setup message, when the App id
# or the key is missing or the id is malformed, on main and on untrusted alike.
for bad in 'app_id= key_present=true' 'app_id=1234567 key_present=false' 'app_id=not-an-id key_present=true'; do
  eval "${bad}"
  freshness_run refs/heads/main identical
  [[ "${freshness_rc}" -ne 0 ]] && grep -qF 'The source-reader App is not configured' "${fresh_dir}/out" \
    || { echo "unconfigured settings (${bad}) should be refused before the mint" >&2; cat "${fresh_dir}/out" >&2; exit 1; }
done
unset app_id key_present
freshness_run refs/heads/main identical
[[ "${freshness_rc}" -eq 0 ]] || { echo 'configured settings should pass the pre-mint step' >&2; cat "${fresh_dir}/out" >&2; exit 1; }
echo 'settings fixtures: a missing App id, a missing key and a malformed id are refused before the mint'
