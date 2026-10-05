#!/usr/bin/env bash
# Behavioural fixtures for the dispatcher's environment pre-flight. The reviewed step is
# extracted from validation.yml and run against a stub `curl` that answers the environment
# read. It must ask exactly for this repository's source-read environment, pass only when the
# environment exists and allows protected branches only, and refuse a 404 (with the setup
# message), any other status, a failed request, any other branch policy, a malformed SHA and an
# unknown gate. Run from the repository root.
set -euo pipefail

workflow=.github/workflows/validation.yml
step='Validate exact source SHA and the source-read environment'
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
api=https://api.invalid
sha=0123456789abcdef0123456789abcdef01234567

fail() { echo "pre-flight fixture failed: $*" >&2; [[ -f "${dir}/stdout" ]] && cat "${dir}/stdout" >&2; exit 1; }

ruby .github/policy/extract-step.rb "${workflow}" "${step}" run > "${dir}/step.sh"
printf '%s' '{"${{ inputs.source_sha }}":"'"${sha}"'","${{ inputs.vulnerability_gate }}":"high","${{ github.token }}":"fixture-job-token"}' > "${dir}/map.json"
step_env=()
while IFS= read -r line; do step_env+=("${line}"); done < <(ruby .github/policy/extract-step.rb "${workflow}" "${step}" env "${dir}/map.json")
(( ${#step_env[@]} > 0 )) || fail 'the step environment could not be read'

mkdir -p "${dir}/bin"
cat > "${dir}/bin/curl" <<'STUB'
#!/usr/bin/env bash
url='' out=''
while (( $# )); do
  case "$1" in
    --output|-o) out="$2"; shift ;;
    -H|--retry|--retry-delay|--retry-max-time|--write-out|-w) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s\n' "${url}" >> "${FAKE_LOG}"
[[ -n "${out}" ]] && printf '%s' "${FAKE_BODY}" > "${out}"
printf '%s' "${FAKE_CODE}"
exit "${FAKE_RC:-0}"
STUB
chmod +x "${dir}/bin/curl"

policy_body() { printf '{"name":"source-read","deployment_branch_policy":%s}' "$1"; }
preflight_run() {
  rm -rf "${dir}/runner"; mkdir -p "${dir}/runner"; : > "${dir}/calls"
  set +e
  env "${step_env[@]}" PATH="${dir}/bin:${PATH}" GITHUB_API_URL="${api}" GITHUB_REPOSITORY=Keeldock/keeldock-ci \
    RUNNER_TEMP="${dir}/runner" GITHUB_STEP_SUMMARY="${dir}/runner/summary" FAKE_LOG="${dir}/calls" \
    FAKE_CODE=200 FAKE_BODY="$(policy_body '{"protected_branches":true,"custom_branch_policies":false}')" "$@" \
    bash --noprofile --norc -eo pipefail "${dir}/step.sh" > "${dir}/stdout" 2>&1
  rc=$?
  set -e
}
expect_pass() { [[ "${rc}" -eq 0 ]] || fail "$1: should pass, exited ${rc}"; }
expect_refused() {
  [[ "${rc}" -ne 0 ]] || fail "$1: should be refused, passed"
  [[ -z "${2:-}" ]] || grep -qF -- "$2" "${dir}/stdout" || fail "$1: the refusal does not say '$2'"
}
environment_url="${api}/repos/Keeldock/keeldock-ci/environments/source-read"

preflight_run
expect_pass 'present, protected branches only'
[[ "$(cat "${dir}/calls")" == "${environment_url}" ]] || fail "the pre-flight read $(cat "${dir}/calls"), not exactly ${environment_url}"

preflight_run FAKE_CODE=404 FAKE_BODY='{"message":"Not Found"}'
expect_refused 'a missing environment (404)' 'does not exist yet'
for code in 401 403 500 502; do
  preflight_run FAKE_CODE="${code}" FAKE_BODY='{}'
  expect_refused "HTTP ${code}" "could not be read (HTTP ${code})"
done
preflight_run FAKE_CODE=000 FAKE_RC=7 FAKE_BODY=''
expect_refused 'a failed request' 'could not be read (HTTP 000)'
for branch_policy in null '{"protected_branches":false,"custom_branch_policies":true}' \
  '{"protected_branches":true,"custom_branch_policies":true}' '{"protected_branches":false,"custom_branch_policies":false}' '{}'; do
  preflight_run FAKE_BODY="$(policy_body "${branch_policy}")"
  expect_refused "branch policy ${branch_policy}" 'protected branches only'
done
preflight_run FAKE_BODY='not json'
expect_refused 'an unreadable body'

preflight_run REQUESTED_SOURCE_SHA=0123456
expect_refused 'an abbreviated SHA' 'full 40-character'
preflight_run REQUESTED_VULN_GATE=low
expect_refused 'an unknown gate' 'vulnerability_gate must be'
echo 'pre-flight fixtures: only a present, protected-branches-only source-read environment passes; 404, other statuses, failed requests and other policies are refused'
