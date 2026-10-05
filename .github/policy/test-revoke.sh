#!/usr/bin/env bash
# Behavioural fixtures for the concern's verify-and-revoke step. The reviewed script is
# extracted from validation-concern.yml and run against stub `curl` and `git` on PATH, which
# record every call. On every path (success, a failed checkout, an identity mismatch, a SHA
# mismatch, an unreachable SHA) the step must call DELETE /installation/token with the source
# token, call exactly the reviewed endpoints, write only the literal protected-ancestry answer,
# and fail unless every check passed; main must refuse a SHA not reachable from main. A grep
# cannot prove any of this: an early `exit 0`, a re-pointed endpoint or a disabled refusal keeps
# every string in place. Run from the repository root.
set -euo pipefail

workflow=.github/workflows/validation-concern.yml
step='Verify identity, exact checkout, and revoke source token'
dir="$(mktemp -d)"
trap 'rm -rf "${dir}"' EXIT
api=https://api.invalid
token=fixture-source-token-0123456789
sha=0123456789abcdef0123456789abcdef01234567
other=fedcba9876543210fedcba9876543210fedcba98
repo_id=1377321992 owner=Moh-Bakr name=keeldock-cloud

fail() { echo "revoke fixture failed: $*" >&2; [[ -f "${dir}/stdout" ]] && cat "${dir}/stdout" >&2; exit 1; }

ruby .github/policy/extract-step.rb "${workflow}" "${step}" run > "${dir}/step.sh"
# The step reads exactly the token and the requested SHA; anything else it is given is new,
# unreviewed input and fails here.
want_env='{"SOURCE_TOKEN":"${{ steps.source-token.outputs.token }}","REQUESTED_SOURCE_SHA":"${{ inputs.source_sha }}"}'
got_env="$(ruby -ryaml -rjson -e 'd = YAML.safe_load(File.read(ARGV[0])); s = d["jobs"].values.flat_map { |j| j["steps"] || [] }.find { |x| x["name"] == ARGV[1] }; puts JSON.generate(s["env"] || {})' "${workflow}" "${step}")"
[[ "${got_env}" == "${want_env}" ]] || fail "the step's env is not the reviewed pair: ${got_env}"
printf '%s' '{"${{ steps.source-token.outputs.token }}":"'"${token}"'","${{ inputs.source_sha }}":"'"${sha}"'"}' > "${dir}/map.json"
step_env=()
while IFS= read -r line; do step_env+=("${line}"); done < <(ruby .github/policy/extract-step.rb "${workflow}" "${step}" env "${dir}/map.json")
(( ${#step_env[@]} > 0 )) || fail 'the step environment could not be read'

mkdir -p "${dir}/bin"
cat > "${dir}/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=GET url='' auth=''
while (( $# )); do
  case "$1" in
    -X) method="$2"; shift ;;
    -H) [[ "$2" == Authorization:* ]] && auth="$2"; shift ;;
    --retry|--retry-delay|--retry-max-time|--output|-o|--write-out|-w) shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s %s|%s\n' "${method}" "${url}" "${auth}" >> "${FAKE_LOG}"
case "${method} ${url}" in
  "DELETE ${GITHUB_API_URL}/installation/token") exit "${FAKE_REVOKE_RC:-0}" ;;
  "GET ${GITHUB_API_URL}/repos/"*/commits/*)
    [[ "${FAKE_COMMIT:-ok}" == fail ]] && exit 22
    printf '{"sha":"%s"}\n' "${FAKE_API_SHA}" ;;
  "GET ${GITHUB_API_URL}/repos/"*/compare/*)
    branch="${url##*/compare/}"; branch="${branch%%...*}"
    var="FAKE_COMPARE_${branch}"; status="${!var:-diverged}"
    [[ "${status}" == fail ]] && exit 22
    printf '{"status":"%s"}\n' "${status}" ;;
  "GET ${GITHUB_API_URL}/repositories/"*|"GET ${GITHUB_API_URL}/repos/"*)
    [[ "${FAKE_IDENTITY:-ok}" == fail ]] && exit 22
    printf '{"id":%s,"owner":{"login":"%s"},"name":"%s"}\n' "${FAKE_ID}" "${FAKE_OWNER}" "${FAKE_NAME}" ;;
  *) exit 22 ;;
esac
STUB
cat > "${dir}/bin/git" <<'STUB'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "${FAKE_GIT_LOG}"
case " $* " in
  *" rev-parse "*) [[ -n "${FAKE_HEAD:-}" ]] || exit 128; printf '%s\n' "${FAKE_HEAD}" ;;
  *) exit 0 ;;
esac
STUB
chmod +x "${dir}/bin/curl" "${dir}/bin/git"

# revoke_run REF [KEY=VALUE ...]: runs the step as GitHub does (bash -e -o pipefail).
revoke_run() {
  local ref="$1"; shift
  rm -rf "${dir}/runner"; mkdir -p "${dir}/runner/_runner_file_commands"
  output="${dir}/runner/_runner_file_commands/set_output_fixture"
  printf 'stale=output\n' > "${output}"
  : > "${dir}/calls"; : > "${dir}/git"
  set +e
  env "${step_env[@]}" PATH="${dir}/bin:${PATH}" GITHUB_REF="${ref}" GITHUB_API_URL="${api}" \
    RUNNER_TEMP="${dir}/runner" GITHUB_OUTPUT="${output}" FAKE_LOG="${dir}/calls" FAKE_GIT_LOG="${dir}/git" \
    FAKE_ID="${repo_id}" FAKE_OWNER="${owner}" FAKE_NAME="${name}" FAKE_HEAD="${sha}" FAKE_API_SHA="${sha}" \
    FAKE_COMPARE_main=identical "$@" \
    bash --noprofile --norc -eo pipefail "${dir}/step.sh" > "${dir}/stdout" 2>&1
  rc=$?
  set -e
}
identity="GET ${api}/repositories/${repo_id}"
commit="GET ${api}/repos/${owner}/${name}/commits/${sha}"
ancestry="GET ${api}/repos/${owner}/${name}/compare/main...${sha}?per_page=1"
revoke="DELETE ${api}/installation/token"

# expect LABEL RC(0|fail) ANSWER(true|false|-) CALL...: the exit status, the output file and the
# exact call sequence; the revoke must carry the source token, and the token never reaches a log.
expect() {
  local label="$1" want_rc="$2" answer="$3"; shift 3
  if [[ "${want_rc}" == 0 ]]; then
    [[ "${rc}" -eq 0 ]] || fail "${label}: should pass, exited ${rc}"
  else
    [[ "${rc}" -ne 0 ]] || fail "${label}: should fail, passed"
  fi
  local want; want="$(printf '%s\n' "$@")"
  [[ "$(cut -d'|' -f1 "${dir}/calls")" == "${want}" ]] \
    || fail "${label}: calls were
$(cut -d'|' -f1 "${dir}/calls")
wanted
${want}"
  if grep -q '^DELETE ' "${dir}/calls"; then
    [[ "$(grep '^DELETE ' "${dir}/calls" | cut -d'|' -f2)" == "Authorization: Bearer ${token}" ]] || fail "${label}: the revoke did not carry the source token"
  fi
  if [[ "${answer}" != - ]]; then
    [[ "$(cat "${output}")" == "protected-ancestor=${answer}" ]] || fail "${label}: output was '$(cat "${output}")', wanted protected-ancestor=${answer} alone"
  fi
  if grep -qF "${token}" "${dir}/stdout"; then fail "${label}: the token reached the log"; fi
  return 0
}

revoke_run refs/heads/main
expect 'main, SHA on main' 0 true "${identity}" "${commit}" "${ancestry}" "${revoke}"
revoke_run refs/heads/main FAKE_COMPARE_main=behind
expect 'main, SHA behind main' 0 true "${identity}" "${commit}" "${ancestry}" "${revoke}"
revoke_run refs/heads/main REQUESTED_SOURCE_SHA="$(printf '%s' "${sha}" | tr '[:lower:]' '[:upper:]')"
expect 'main, upper-case SHA' 0 true "${identity}" "${commit}" "${ancestry}" "${revoke}"
for unreachable in diverged ahead fail; do
  revoke_run refs/heads/main FAKE_COMPARE_main="${unreachable}"
  expect "main refuses an unreachable SHA (${unreachable})" fail false "${identity}" "${commit}" "${ancestry}" "${revoke}"
  grep -qF 'so main refuses it' "${dir}/stdout" || fail "main, ${unreachable}: no refusal message"
  revoke_run refs/heads/untrusted FAKE_COMPARE_main="${unreachable}"
  expect "untrusted runs an unreachable SHA (${unreachable}) without protected ancestry" 0 false "${identity}" "${commit}" "${ancestry}" "${revoke}"
done
revoke_run refs/heads/untrusted
expect 'untrusted, SHA on main' 0 true "${identity}" "${commit}" "${ancestry}" "${revoke}"

# Every failure still revokes; none asks the ancestry question or claims protected ancestry.
for ref in refs/heads/main refs/heads/untrusted; do
  revoke_run "${ref}" FAKE_HEAD=
  expect "${ref}: checkout failed" fail false "${identity}" "${commit}" "${revoke}"
  revoke_run "${ref}" FAKE_HEAD="${other}"
  expect "${ref}: checked-out SHA mismatch" fail false "${identity}" "${commit}" "${revoke}"
  revoke_run "${ref}" FAKE_API_SHA="${other}"
  expect "${ref}: API SHA mismatch" fail false "${identity}" "${commit}" "${revoke}"
  revoke_run "${ref}" FAKE_COMMIT=fail
  expect "${ref}: SHA not in the repository" fail false "${identity}" "${commit}" "${revoke}"
  revoke_run "${ref}" FAKE_IDENTITY=fail
  expect "${ref}: identity unreadable" fail false "${identity}" "${commit}" "${revoke}"
  revoke_run "${ref}" FAKE_ID=1
  expect "${ref}: identity id mismatch" fail false "${identity}" "${commit}" "${revoke}"
  revoke_run "${ref}" FAKE_OWNER=someone-else
  expect "${ref}: identity owner mismatch" fail false "${identity}" "${commit}" "${revoke}"
  revoke_run "${ref}" FAKE_NAME=other-repo
  expect "${ref}: identity name mismatch" fail false "${identity}" "${commit}" "${revoke}"
  revoke_run "${ref}" FAKE_REVOKE_RC=22
  expect "${ref}: revoke failed" fail - "${identity}" "${commit}" "${ancestry}" "${revoke}"
done
revoke_run refs/heads/main SOURCE_TOKEN=
expect 'no token minted' fail -
echo 'revoke fixtures: every path revokes with the source token, calls only the reviewed endpoints, and main refuses an unreachable SHA'
