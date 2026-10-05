# Rotating the source-reader App key

Every source-bearing job in this repository mints its short-lived checkout token from one
credential: the private key of the Keel Dock source-reader GitHub App, stored as the environment
secret `SOURCE_READER_PRIVATE_KEY` of the `source-read` environment. The App's numeric ID is the
`SOURCE_READER_APP_ID` variable of the same environment. The App is installed on
`Moh-Bakr/keeldock-cloud` only, with Contents read-only.

The key is available to a job before the token is revoked, and that job later runs private
project code. Root is removed first on Linux and macOS, but two Linux concerns keep Docker
(root-equivalent) and Windows jobs stay administrators, so a hostile dependency could copy the key
out of the runner. Rotating it regularly limits how long a stolen key stays useful. This runbook is
for the repository owner. Every step happens in GitHub settings; no workflow or agent changes them.

## When to rotate

- **Every 90 days.** Record each rotation date at the end of this file; the next date is 90 days
  after the last entry.
- **Straight away after any suspected exposure**, for example:
  - an egress-audit summary that shows a destination nobody can explain;
  - a compromised or yanked dependency that ran in a source-bearing job;
  - key material appearing in a log, summary, issue or chat;
  - a lost or shared device that held the downloaded `.pem`;
  - a collaborator with admin access leaving.

  For a suspected exposure, delete the old key first (step 5), then generate the new one. CI
  fails closed in the gap, which is the intended result.

## Rotation steps (owner, in GitHub settings)

A GitHub App can hold more than one private key at once, so the new key can be proved before the
old one is deleted.

1. **Generate a new key.** Moh-Bakr → Settings → Developer settings → GitHub Apps → the Keel Dock
   source-reader App → Private keys → **Generate a private key**. The browser downloads a `.pem`.
   Note the fingerprint GitHub shows next to the new key.
2. **Update the secret.** `Keeldock/keeldock-ci` → Settings → Environments → `source-read` →
   Environment secrets → `SOURCE_READER_PRIVATE_KEY` → edit, and paste the whole `.pem`. From the
   command line, run this yourself so the key never passes through an agent or a shell history:

   ```bash
   gh secret set SOURCE_READER_PRIVATE_KEY --repo Keeldock/keeldock-ci --env source-read < path/to/new-key.pem
   ```

   Never create a repository-level copy: an environment secret is released only to jobs that
   enter `source-read`, which only `main` and `untrusted` can.
3. **Verify with the new key** (next section) before going on.
4. **Destroy the local copy** of the `.pem`. Nothing needs it once it is in the secret.
5. **Revoke the old key.** On the App's Private keys list, delete every key except the one whose
   fingerprint you noted in step 1.
6. **Verify again**, to show that only the new key is in use.
7. **Record it** in the log below, in a docs-only pull request.

## Verifying a rotation

```bash
sha="$(gh api repos/Moh-Bakr/keeldock-cloud/commits/main -q .sha)"
gh workflow run validation.yml --repo Keeldock/keeldock-ci --ref main -f source_sha="${sha}"
```

A rotation is verified only when:

- the run's conclusion is `success`;
- the step **Verify identity, exact checkout, and revoke source token** succeeded in every job;
- the source SHA in each concern's proof summary equals the full 40-character SHA you dispatched.

A failure at the mint step usually means the pasted key is truncated or belongs to another App;
re-paste it, and do not delete the old key until a run passes. Never cancel a source-bearing run
while you wait: cancelling can interrupt the step that revokes the token.

## Optional hardening (owner decisions)

- **Keep deployment branches at "Protected branches only".** `untrusted` must stay able to enter
  `source-read` so feature-branch SHAs can be validated without touching main's caches.
- **Required reviewers on `source-read`.** Every run would wait for an approval before any job
  enters the environment. It guards against a workflow merged by mistake reading the key, at the
  cost of a manual step per dispatch. Turn on "prevent self-review" only once a second trusted
  account exists.
- **Shorter cadence** (30 days) if the egress audit is ever removed, or after a supply-chain
  incident in a dependency the private build uses.

## Retiring the Taurine-CI access

Keel Dock was validated from `Moh-Bakr/Taurine-CI` with that repository's App. After this
repository has a green run on keeldock-cloud `main`, remove keeldock-cloud from the old App:
Moh-Bakr → Settings → Applications → Installed GitHub Apps → the Taurine-CI source-reader App →
Configure → Repository access → remove `keeldock-cloud` → Save.

## Rotation log

| Date | Reason | Verified by (run IDs) |
| --- | --- | --- |
