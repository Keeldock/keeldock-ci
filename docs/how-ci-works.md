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
   environment through the API. If it does not exist, or its deployment branches are not
   "protected branches only", the run stops there. This matters because a job that names a
   missing environment makes GitHub create it, unprotected.
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
ancestry rule or the settings guard change (`check-concern.sh`, `revocation-order.rb`). The mint's
`with:` is an exact allow-list of keys and values (`client-id` or `app-id`, `private-key`,
`owner`, `repositories`, `permission-contents: read`, `skip-token-revoke: true`), the concern
needs the pre-flight job directly and never runs past its failure, and no expression may read a
whole `secrets`, `vars` or `github` context (`check-universal.rb`).

Strings prove little about a script, so the two scripts that guard the token are also run as
behaviour. `test-revoke.sh` extracts step 4 and runs it against stub `curl` and `git` that record
every call: on every path (success, failed checkout, identity mismatch, SHA mismatch, unreachable
SHA, failed revoke) it must call exactly the reviewed endpoints (`/repositories/1377321992`,
`/repos/Moh-Bakr/keeldock-cloud/commits/<sha>`, `.../compare/main...<sha>` and
`DELETE /installation/token` with the source token), write only the literal ancestry answer, and
fail unless every check passed; on `main` an unreachable SHA must be refused. `test-preflight.sh`
does the same for step 0: only a present, protected-branches-only `source-read` passes; a 404,
any other status, a failed request and any other branch policy are refused. `test-mutations.sh`
applies each weakening an independent review found (an early `exit 0`, a re-pointed endpoint, a
dropped `needs:`, an extra mint permission, `toJSON(secrets)`, an unconditional `keep-docker`, a
weaker gate default and more) to a copy of the tree and requires the policy to reject every one.

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
   and tags: **Protected branches only**. Add the environment secret `SOURCE_READER_PRIVATE_KEY`
   (the whole PEM) and the environment variable `SOURCE_READER_APP_ID` (the numeric App ID). Do
   not create repository-level copies.
3. **Rulesets** (Settings → Rules → Rulesets):
   - `main` (target the default branch): restrict deletions, block force pushes, require a pull
     request before merging, require the status check `Validate workflow policy` (source: GitHub
     Actions). Bypass list: Repository admin role, mode "For pull requests only".
   - `untrusted` (target `refs/heads/untrusted`): restrict deletions, restrict updates, block
     force pushes. Bypass list: Repository admin role, mode "Always".
   Both branches then count as protected, so `source-read` deploys to both and to nothing else.
4. **Actions → General:** fork pull request approval "Require approval for all external
   contributors" (already the organisation setting); workflow permissions "Read repository
   contents" (already set). Recommended, as on Taurine-CI: Actions permissions "Allow Keeldock,
   and select non-Keeldock, actions" with only "Allow actions created by GitHub", and "Require
   actions to be pinned to a full-length commit SHA".

Check them:

```bash
gh api repos/Keeldock/keeldock-ci/environments/source-read -q .deployment_branch_policy   # protected_branches: true
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
a malformed line fails the gate. The review-by date must be a real calendar date (2026-02-31 is
malformed) no more than 90 days after the run's date, so an exception is re-reviewed at least
every 90 days and a far-future date (9999-12-31) fails the gate rather than disabling it. Only advisory ids, severities, counts and an 8-hex package-name
hash are published. `test-vuln-gate.sh` runs the library over fixtures in the policy workflow.

## Sanitising: no artifacts, no source in logs

- No artifacts anywhere; the only cache is the NuGet package folder under the rules above.
- Every sub-step's output stays in a runner-local log; only a fixed reason, per-suite totals,
  durations and failing test names (identifier characters only) are published. Dependency and SBOM
  component names are published only as 8-hex SHA-256 prefixes.
- Workflows declare `permissions: {}` and grant per job; every Action is SHA-pinned and on the
  allow-list in `check-actions.sh`; protected workflows set `cancel-in-progress: false`, so a cancel
  cannot skip the revoke. Never cancel a source-bearing run.

## Changing the policy

A pull request carries its own `.github/policy/`, so on its own the policy run would let a
change weaken a check and rely on the weakening in one step. On `pull_request`,
`validate-public-changes.yml` therefore runs twice in the same required job: first the pull
request's own policy (so new fixtures run), then the base commit's: it checks out
`github.event.pull_request.base.sha`, puts that commit's `.github/policy/` in place of the pull
request's and runs every base check script against the pull request's tree. A change must pass
both. `test-mutations.sh` proves the second pass catches a pull request that removes a rule and
breaks it in the same change.

So a legitimate policy change that the old policy would reject (a new reviewed mint, another
`keep-docker` expression, a renamed step a fixture extracts) lands in two pull requests: first
make the rule permissive or add the new rule beside the old one, merge, then land the change
that relies on it. The pull request's own copy of `validate-public-changes.yml` is what runs, so
a pull request that edits that file to drop the base pass is caught only by review: treat any
change to `validate-public-changes.yml` or `.github/policy/` as a policy change and review it
as one.

## Accepted residual risks

These are known, reviewed and accepted; each is limited by the controls named.

- **(a) The App key is readable by project code on Windows and in Docker-kept concerns.** The
  key is a job secret held in runner memory for the whole job. Windows cannot drop administrator
  rights, and `db-containers` and `apphost-cold-start` keep Docker (root-equivalent), so project
  code there can read it. The key is rotated every 90 days
  (`docs/source-reader-key-rotation.md`), and the App is installed on one repository with
  contents read-only, so a stolen key reads keeldock-cloud and nothing else.
- **(b) An approved fork pull request can read main's NuGet cache.** Caches written by the base
  branch are readable by pull request runs. This repository's own policy run restores no cache,
  but a fork pull request a maintainer approves runs code that can ask the cache service for
  main's entries. Fork approval ("Require approval for all external contributors") therefore
  stays mandatory, and restored archives are re-hashed against the lock files before use.
- **(c) Hashed package names are a weak control.** Dependency and SBOM names are published as
  8-hex SHA-256 prefixes, but the set of NuGet package names is public, so a dictionary attack
  reverses them. The hash keeps names out of casual reading, not out of a determined reader.
- **(d) After the revoke, project code can tamper with later reporting steps.** Project code runs
  as the job user in the same job as the summary, proof and egress steps, so it can change what
  they report. The trust model is that keeldock-cloud writers and their dependencies are trusted
  for confidentiality: the controls stop them reaching the token, root and main's caches, not
  falsifying their own run's report. The source of truth for a result is the job conclusion.

## Differences from the Taurine-CI lane

- Own repository, own Actions concurrency, own App and key, own `source-read` environment.
- Protected ancestry is "reachable from keeldock-cloud `main`" (Taurine checks `develop`, `uat`
  and `main`).
- The dispatcher checks that `source-read` exists and is limited to protected branches before any
  job can enter it, and the concern refuses a missing App id or key before the mint.
- No `source-checkout`, `sanitize`, `concern-report`, `run-result` or `root-setup` composite: the
  Keel Dock lane never used them (its checkout is inline and pinned by `check-concern.sh`).
- Egress is audit-only (above); the Taurine-only Rust, Android, iOS, live-proof and weekly
  machinery is not ported.
