#!/usr/bin/env bash
# Reject private-source and credential material
# Run from the repository root (the policy workflow does).
set -euo pipefail

# Keel Dock is .NET with a TypeScript code generator: no C#, project, solution, MSBuild, script
# or lock file, and no key or certificate container, may be tracked here.
forbidden_path_re='(^|/)(src|tests|contracts|tools|bin|obj|node_modules|vendor)(/|$)|\.(cs|csproj|sln|slnx|props|targets|fs|vb|rs|ts|tsx|js|jsx|json|toml|lock|pem|key|p12|pfx|jks|keystore|snk)$'
forbidden_name_re='(^|/)(README|SECURITY|CODEOWNERS|LICENSE)(\.|$)'

while IFS= read -r -d '' path; do
  if [[ "$path" == .github/workflows/* ]]; then
    continue
  fi
  # Local composite actions: action.yml only.
  if [[ "$path" =~ ^\.github/actions/[a-z0-9-]+/action\.yml$ ]]; then
    continue
  fi
  # The policy's own scripts: shell and Ruby, nothing else, flat in one directory.
  if [[ "$path" =~ ^\.github/policy/[a-z0-9-]+\.(sh|rb)$ ]]; then
    continue
  fi
  if [[ "$path" == .github/dependabot.yml || "$path" == .github/tool-pins.json || "$path" == .github/egress-allowlist.txt ]]; then
    continue
  fi
  # Flat documentation guides: markdown directly under docs/, nothing else.
  if [[ "$path" =~ ^docs/[a-z0-9-]+\.md$ ]]; then
    continue
  fi
  if [[ "$path" == .gitignore ]]; then
    continue
  fi
  echo "Unexpected tracked path in the public CI repository: $path" >&2
  exit 1
done < <(git ls-files -z)

if git ls-files | grep -vxF -e '.github/dependabot.yml' -e '.github/tool-pins.json' | grep -E "$forbidden_path_re|$forbidden_name_re"; then
  echo "The public repository contains a forbidden source, credential, or starter-document path." >&2
  exit 1
fi

if git grep -nI -E 'GH_APP_PRIVATE_KEY|(KEELDOCK|TAURINE)_(PAT|TOKEN|PRIVATE_KEY)|GITHUB_TOKEN[[:space:]]*[:=]|DEPLOY_KEY|BEGIN (RSA |OPENSSH |EC |ENCRYPTED )?PRIVATE KEY|BEGIN (RSA|OPENSSH|EC) |gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|secrets\.(KEELDOCK|TAURINE|GH_APP|PAT|DEPLOY|SIGNING)' -- . ':!.github/workflows/validate-public-changes.yml' ':!.github/policy/*'; then
  echo "A reusable source, signing, or deployment credential pattern was found." >&2
  exit 1
fi
echo "repository contents: no private source or credential material"
