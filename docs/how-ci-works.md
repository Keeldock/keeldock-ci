# How the Keel Dock hosted CI works

This repository (`Keeldock/keeldock-ci`) is public. It is the control plane that validates the
private source repository `Moh-Bakr/keeldock-cloud` on free hosted runners. It contains
workflows, small composite actions, policy scripts and two tables, and never any product source.

It replaces the Keel Dock lane of `Moh-Bakr/Taurine-CI`, so Keel Dock gets its own Actions
concurrency and its own source-reader GitHub App and key. The security model is the same one,
reproduced file by file; the differences are listed at the end.

## The two-repo model

| Repository | Visibility | Holds |
| --- | --- | --- |
| `Keeldock/keeldock-ci` | public | Workflows, composite actions, the policy workflow and its scripts |
| `Moh-Bakr/keeldock-cloud` | private | The product source (.NET, one branch: `main`) |

Every validation is a manual `workflow_dispatch` of `validation.yml` on `main` (or `untrusted`)
of this repository, given the exact 40-character SHA of the private commit to test. Nothing runs
with source access on pull requests or pushes. The policy workflow rejects tracked source,
credential and starter-document paths: the only tracked files are workflows, composite actions
(`action.yml`), the policy scripts, `tool-pins.json`, `egress-allowlist.txt`, `dependabot.yml` and
flat `docs/*.md` guides.

## Files

| Path | Role |
| --- | --- |
| `.github/workflows/validation.yml` | Protected dispatcher: validates the input and the `source-read` environment, fans out the concern matrix, tabulates timings |
| `.github/workflows/validation-concern.yml` | Protected reusable workflow: one concern on one OS; owns everything before project code |
| `.github/workflows/validate-public-changes.yml` | The policy gate (job `Validate workflow policy`), on every pull request and push to main |
| `.github/actions/restore` | Sub-step library and the locked restore |
| `.github/actions/nuget-verify` | Re-hashes cached `.nupkg` archives against `packages.lock.json` |
| `.github/actions/postgres-start` | Digest-pinned PostgreSQL for the Migrator proof (before drop-root) |
| `.github/actions/build-format`, `test-suites`, `supply-chain`, `apphost`, `contracts-publish` | One composite per concern |
| `.github/actions/summary`, `proof` | Sanitised sub-step summary and the per-concern proof |
| `.github/actions/drop-root` | Removes root (and Docker, unless kept) before project code |
| `.github/actions/egress-audit` | Records outbound destinations; publishes only allow-listed names |
| `.github/actions/timings` | Duration table against a baseline (warning only) |
| `.github/policy/*` | One check per script; `test-*.sh` are their fixtures |

## Token lifecycle

The `validate` job of `validation-concern.yml` is the only job that reads the private
repository, and the only job that enters an environment (`source-read`, which holds the
`SOURCE_READER_APP_ID` variable and the `SOURCE_READER_PRIVATE_KEY` secret).

0. **Environment pre-flight (dispatcher).** With no environment and no secret, the
   `validate-input` job checks the SHA shape and reads this repository's `source-read`
   environment and its deployment branch policies through the API. Unless it exists, uses
   custom branch policies ("Selected branches and tags") and those are exactly the two branches
   `main` and `untrusted` (no wildcard, no tag, no third branch), the run stops there. This
   matters because a job that names a missing environment makes GitHub create it, unprotected.
   "Protected branches only" is refused: for environments GitHub counts only classic branch
   protection rules as protected, not rulesets, and this repository protects its branches with
   rulesets, so that setting lets every branch deploy (a probe proved an unprotected scratch
   branch could enter `source-read`). `test-preflight.sh` runs the reviewed step against stub
   API answers for each case.
1. **Guard.** The repository must be this one, the ref must be `refs/heads/main` or
   `refs/heads/untrusted`, the SHA must match `^[0-9a-fA-F]{40}$`, and the App id and key must
   be present (the key's value never enters this step, only whether it is empty). A run from
   `untrusted` must be running main's tip or an ancestor of it (see Ref isolation).
2. **Mint.** `actions/create-github-app-token` issues a short-lived token for
   `Moh-Bakr/keeldock-cloud` only, with `contents: read` only. Its own end-of-job revoke is
   disabled (`skip-token-revoke`) because step 4 revokes explicitly.
3. **Exact-SHA checkout** into `src/`, with `persist-credentials: false`, no submodules, no LFS.
4. **Verify and revoke (`if: always()`).** Confirms the numeric repository id (1377321992),
   owner and name, that `HEAD` equals the requested SHA and that the API resolves it, then asks
   whether the SHA is reachable from keeldock-cloud `main` (protected ancestry), calls
   `DELETE /installation/token`, clears git credentials and empties step-output files. On `main`,
   a SHA that is not reachable from keeldock-cloud `main` is refused here, before project code.

The policy parses the job and fails if anything but the reviewed pre-source steps precedes the
revoke, if the revoke is not under `always()`, or if the identity constants, the mint scope, the
ancestry rule or the settings guard change (`check-concern.sh`, `revocation-order.rb`).

## Root before project code

The App private key is a job secret, which the runner keeps in memory for the whole job, and a
hosted Linux or macOS runner gives every step passwordless `sudo`. So, straight after the revoke
and the reviewed root-needing steps (egress recorders, NuGet verification, the PostgreSQL start),
`drop-root` replaces the sudoers policy, makes the Docker socket root-only, makes
`/usr/local/bin` root-owned and, on macOS, turns developer mode off and removes the job user
from `admin` and `_developer`. A separate step verifies, fail-closed, that `sudo -n true` is
refused, that the job is not root, that Docker is closed and that the job cannot attach a
debugger to the runner. `drop-root-order.rb` enforces the order.

### Residual risk

- **`db-containers` and `apphost-cold-start` keep Docker**, because their project code starts
  containers itself (Testcontainers, the Aspire AppHost). Docker access is root-equivalent, so in
  those two concerns project code can still reach root, and so the key, through Docker. `sudo` is
  still removed. The job summary says "Docker: kept open".
- **Windows** cannot drop administrator rights. Project code there can read the runner's memory.
  The mitigations are the token order above, the App's single-repository, read-only scope, and
  key rotation (`docs/source-reader-key-rotation.md`). Every Windows job records this.
- Linux: the job user can read the runner's `/proc/<pid>/environ`, which is how the cache runtime
  token is reachable; hence ref isolation below.
- A kernel privilege-escalation bug would bypass all of this.

## Egress: audit only

Every concern runs `egress-audit` (`start` after the revoke, `report` last). It records DNS answers
and new outbound connections (Linux: `resolvectl monitor` and an iptables LOG chain; macOS:
`tcpdump`; Windows: the DNS Client event log) and publishes only names on
`.github/egress-allowlist.txt`; any other name appears as `unlisted:<12-hex SHA-256 prefix>`.
It never blocks and never fails the job. Taurine-CI's Linux block mode is not ported: two Keel Dock
concerns keep Docker (so a firewall would be a claim the job cannot keep), macOS and Windows cannot
hold a firewall against project code, and the allow-list was inherited rather than measured here.
Review the first runs' audit output and adjust the list in a reviewed pull request.

## Ref isolation: main and untrusted

The Actions cache is scoped by ref, and project code can write an entry with the runner's
runtime token. So:

| Ref | Runs | Caches |
| --- | --- | --- |
| `main` | Only SHAs reachable from keeldock-cloud `main`; anything else is refused after the revoke, before project code, with the command to use `untrusted` | The only ref that restores or saves the NuGet cache |
| `untrusted` | Any SHA (a feature branch tip). Its own commit must equal main's tip or be an ancestor of it; ahead or diverged stops before any token is minted | Never restores or saves a cache |

Every NuGet cache restore and save carries the top-level terms `github.ref ==
'refs/heads/main'` and `steps.verified-source.outputs.protected-ancestor == 'true'`;
`check-cache-policy.sh` and its fixtures reject a missing term, an `||` that reopens the gate, a
save key computed after project code, or any path but `~/.nuget/packages`. Restored archives are
re-hashed against the lock files before use (`nuget-verify`).

Dispatching:

```bash
# A commit on keeldock-cloud main
sha=$(gh api repos/Moh-Bakr/keeldock-cloud/commits/main -q .sha)
gh workflow run validation.yml --repo Keeldock/keeldock-ci --ref main -f source_sha="$sha"

# A feature branch
sha=$(gh api repos/Moh-Bakr/keeldock-cloud/commits/<branch> -q .sha)
gh workflow run validation.yml --repo Keeldock/keeldock-ci --ref untrusted -f source_sha="$sha"
```

Keep `untrusted` in sync by hand after each merge to main (an admin fast-forward; the ruleset
blocks everything else). A run from a behind `untrusted` still passes and prints a warning:

```bash
git fetch origin && git push origin origin/main:refs/heads/untrusted
gh api repos/Keeldock/keeldock-ci/compare/main...untrusted -q '[.status, .ahead_by, .behind_by] | @tsv'
```

## One-time settings (owner)

Until these exist the protected workflow fails closed: the pre-flight refuses a missing or
unprotected `source-read`, and the concern refuses a missing App id or key before any mint.

1. **The source-reader App.** Create a GitHub App with no webhook, Repository permissions
   Contents **Read-only** (Metadata read-only is added automatically) and nothing else, "Only on
   this account". An App that is limited to its own account can only be installed on that
   account, and keeldock-cloud belongs to the `Moh-Bakr` user account, so create it under
   **Moh-Bakr → Settings → Developer settings → GitHub Apps**, not under the Keeldock
   organisation (an organisation-owned App would have to be made installable on any account).
   Install it on `Moh-Bakr/keeldock-cloud` **only** ("Only select repositories"). Note the App ID
   and generate a private key. If keeldock-cloud is later transferred to the Keeldock
   organisation, an organisation-owned App becomes possible and `SOURCE_REPOSITORY_OWNER` changes.
2. **Environment.** Settings → Environments → New environment `source-read`; Deployment branches
   and tags: **Selected branches and tags**, with exactly two branch rules, `main` and
   `untrusted` (not "Protected branches only": rulesets do not count as protected branches for
   environments, so that setting admits every branch here). Add the environment secret `SOURCE_READER_PRIVATE_KEY`
   (the whole PEM) and the environment variable `SOURCE_READER_APP_ID` (the numeric App ID). Do
   not create repository-level copies.
3. **Rulesets** (Settings → Rules → Rulesets):
   - `main` (target the default branch): restrict deletions, block force pushes, require a pull
     request before merging, require the status check `Validate workflow policy` (source: GitHub
     Actions). Bypass list: Repository admin role, mode "For pull requests only".
   - `untrusted` (target `refs/heads/untrusted`): restrict deletions, restrict updates, block
     force pushes. Bypass list: Repository admin role, mode "Always".
   The rulesets guard who may update the two branches; the environment's selected-branch rules
   are what limit `source-read` to them.
4. **Actions → General:** fork pull request approval "Require approval for all external
   contributors" (already the organisation setting); workflow permissions "Read repository
   contents" (already set). Recommended, as on Taurine-CI: Actions permissions "Allow Keeldock,
   and select non-Keeldock, actions" with only "Allow actions created by GitHub", and "Require
   actions to be pinned to a full-length commit SHA".

Check them:

```bash
gh api repos/Keeldock/keeldock-ci/environments/source-read -q .deployment_branch_policy   # protected_branches: false, custom_branch_policies: true
gh api repos/Keeldock/keeldock-ci/environments/source-read/deployment-branch-policies -q '.branch_policies[] | "\(.type) \(.name)"'   # branch main, branch untrusted
gh api repos/Keeldock/keeldock-ci/environments/source-read/variables -q '.variables[].name'  # SOURCE_READER_APP_ID
gh api repos/Keeldock/keeldock-ci/environments/source-read/secrets -q '.secrets[].name'      # SOURCE_READER_PRIVATE_KEY
gh api repos/Keeldock/keeldock-ci/rules/branches/main -q '.[].type'
gh api repos/Keeldock/keeldock-ci/rules/branches/untrusted -q '.[].type'                     # deletion, update, non_fast_forward
```

## Concerns

| Concern | Runs on | Proves |
| --- | --- | --- |
| `build-format` | Linux, macOS, Windows | Locked restore, Release build with warnings as errors, format check, structural suites present |
| `structural`, `unit` | Linux, macOS, Windows | The assigned suites pass (assignment follows `scripts/run-tests.sh`), contracts committed |
| `contracts-publish-smoke` | Linux, macOS, Windows | TypeScript contract current, Api/Worker/Migrator publish, Migrator smoke; on Linux the Migrator against real PostgreSQL, twice |
| `db-containers` | Linux | Every Testcontainers suite |
| `supply-chain` | Linux | Vulnerable-package gate and CycloneDX SBOM with the denied-licence gate |
| `apphost-cold-start` | Linux, opt-in (`apphost: true`) | The Aspire AppHost starts headless with a running container |

### The vulnerability gate

`vulnerability_gate` is `high` by default: any High or Critical advisory fails supply-chain.
With `high` or `critical` the scan fails closed (a non-zero exit, an NU190x feed error, no
recognisable result, or unparseable output is a FAIL); `none` only warns. A reviewed exception
lives in the private repository at `.github/nuget-vulnerability-exceptions.txt`, one
`<GHSA-or-CVE-id>  <review-by YYYY-MM-DD>  # reason` per line, honoured through its review-by date;
a malformed line fails the gate. Only advisory ids, severities, counts and an 8-hex package-name
hash are published. `test-vuln-gate.sh` runs the library over fixtures in the policy workflow.

## Sanitising: no artifacts, no source in logs

- No artifacts anywhere; the only cache is the NuGet package folder under the rules above.
- Every sub-step's output stays in a runner-local log; only a fixed reason, per-suite totals,
  durations and failing test names (identifier characters only) are published. Dependency and SBOM
  component names are published only as 8-hex SHA-256 prefixes.
- Workflows declare `permissions: {}` and grant per job; every Action is SHA-pinned and on the
  allow-list in `check-actions.sh`; protected workflows set `cancel-in-progress: false`, so a cancel
  cannot skip the revoke. Never cancel a source-bearing run.

## Differences from the Taurine-CI lane

- Own repository, own Actions concurrency, own App and key, own `source-read` environment.
- Protected ancestry is "reachable from keeldock-cloud `main`" (Taurine checks `develop`, `uat`
  and `main`).
- The dispatcher checks that `source-read` exists and is limited to exactly `main` and `untrusted` before any
  job can enter it, and the concern refuses a missing App id or key before the mint.
- No `source-checkout`, `sanitize`, `concern-report`, `run-result` or `root-setup` composite: the
  Keel Dock lane never used them (its checkout is inline and pinned by `check-concern.sh`).
- Egress is audit-only (above); the Taurine-only Rust, Android, iOS, live-proof and weekly
  machinery is not ported.
