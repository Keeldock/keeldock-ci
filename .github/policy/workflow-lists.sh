#!/usr/bin/env bash
# The explicit trust tiers of this public CI repository (sourced, not run).

# Workflow entrypoints live directly under .github/workflows (GitHub does not discover nested
# workflow files). The lists separate the public policy gate from source-bearing jobs, so adding
# a protected lane is an auditable policy change.
public_policy_workflow=".github/workflows/validate-public-changes.yml"
# Reusable and source-bearing: the only jobs that enter source-read.
protected_source_workflows=(
  ".github/workflows/validation-concern.yml"
)
reusable_protected_workflows=(
  ".github/workflows/validation-concern.yml"
)
# Dispatch-only: validates the input and the environment, then fans out to the concern.
protected_dispatch_workflows=(
  ".github/workflows/validation.yml"
)
