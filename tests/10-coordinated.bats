#!/usr/bin/env bats
# Coordinated git flow: branch -> commit -> merge -> push across two write
# repos plus the git-managed meta-context.

load helpers

setup() {
  setup_workspace
}

coordinated_workspace() {
  init_workspace_with_repos alpha beta
  mcrepo write alpha >/dev/null
  mcrepo write beta >/dev/null
  git_manage_workspace
}

@test "branch creates a coordinated feature branch across write repos and meta" {
  coordinated_workspace
  run bash -c 'printf "y\n" | "$0" branch feature-x' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "feature-x" ]
  [ "$(repo_branch beta)" = "feature-x" ]
  [ "$(git -C "$SANDBOX" rev-parse --abbrev-ref HEAD)" = "feature-x" ]
  grep -q 'branch: feature-x' mcrepo.yaml
  grep -q 'parent: main' mcrepo.yaml
  grep -q 'meta-parent: main' mcrepo.yaml
}

@test "commit creates coordinated commits across dirty write repos" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature-x' "$SANDBOX/mcrepo.sh" >/dev/null
  dirty_repo alpha
  dirty_repo beta
  run mcrepo commit -m "coordinated change"
  [ "$status" -eq 0 ]
  [[ "$(repo_subject alpha)" == "mcrepo commit #"* ]]
  [[ "$(repo_subject alpha)" == *"coordinated change"* ]]
  [[ "$(repo_subject beta)" == "mcrepo commit #"* ]]
  # working trees clean afterwards
  [ -z "$(git -C "$SANDBOX/alpha" status --porcelain)" ]
  [ -z "$(git -C "$SANDBOX/beta" status --porcelain)" ]
}

@test "merge squash-merges the feature branch back into parents" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature-x' "$SANDBOX/mcrepo.sh" >/dev/null
  dirty_repo alpha
  dirty_repo beta
  mcrepo commit -m "coordinated change" >/dev/null
  run bash -c 'printf "n\n" | "$0" merge -m "feat: coordinated change"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "main" ]
  [ "$(repo_branch beta)" = "main" ]
  [ "$(repo_subject alpha)" = "feat: coordinated change" ]
  [ "$(repo_subject beta)" = "feat: coordinated change" ]
  # global branch coordination is popped
  ! grep -q 'branch: feature-x' mcrepo.yaml
}

@test "push publishes merged work to the file:// remotes" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature-x' "$SANDBOX/mcrepo.sh" >/dev/null
  dirty_repo alpha
  mcrepo commit -m "coordinated change" >/dev/null
  bash -c 'printf "n\n" | "$0" merge -m "feat: it"' "$SANDBOX/mcrepo.sh" >/dev/null
  run mcrepo push
  [ "$status" -eq 0 ]
  remote_subject="$(git --git-dir="$REMOTES_DIR/alpha.git" log -1 --format=%s main)"
  [ "$remote_subject" = "feat: it" ]
}

@test "pull fast-forwards repos behind their remote" {
  init_workspace_with_repos alpha
  # advance the remote from the seed clone
  seed="$BATS_TEST_TMPDIR/seed-alpha"
  printf 'more\n' >>"$seed/README.md"
  git -C "$seed" add -A
  git -C "$seed" commit -qm "remote advance"
  git -C "$seed" push -q "$REMOTES_DIR/alpha.git" main
  before="$(git -C "$SANDBOX/alpha" rev-parse HEAD)"
  run mcrepo pull
  [ "$status" -eq 0 ]
  after="$(git -C "$SANDBOX/alpha" rev-parse HEAD)"
  [ "$before" != "$after" ]
  [ "$(repo_subject alpha)" = "remote advance" ]
}

@test "branch --delete returns repos to parent and drops the feature branch" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature-x' "$SANDBOX/mcrepo.sh" >/dev/null
  # mcrepo branch leaves its own state write uncommitted in the meta-context;
  # commit it so --delete's dirty check passes (mirrors the documented flow)
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" commit -qm "state on feature-x"
  run mcrepo branch --delete
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "main" ]
  [ "$(repo_branch beta)" = "main" ]
  ! git -C "$SANDBOX/alpha" show-ref --verify --quiet refs/heads/feature-x
  ! grep -q 'branch: feature-x' mcrepo.yaml
}

@test "--include-read workflow: branch, commit, merge, push a read-mode repo" {
  init_workspace_with_repos alpha beta
  mcrepo write alpha >/dev/null
  # beta stays in read mode
  git_manage_workspace
  bash -c 'printf "y\n" | "$0" branch feature-r --include-read' "$SANDBOX/mcrepo.sh" >/dev/null
  [ "$(repo_branch beta)" = "feature-r" ]
  dirty_repo alpha
  dirty_repo beta
  mcrepo commit -m "read-inclusive change" --include-read >/dev/null
  [[ "$(repo_subject beta)" == "mcrepo commit #"* ]]
  run bash -c 'printf "n\n" | "$0" merge -m "feat: read-inclusive" --include-read' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  [ "$(repo_branch beta)" = "main" ]
  [ "$(repo_subject beta)" = "feat: read-inclusive" ]
  run mcrepo push --include-read
  [ "$status" -eq 0 ]
  remote_subject="$(git --git-dir="$REMOTES_DIR/beta.git" log -1 --format=%s main)"
  [ "$remote_subject" = "feat: read-inclusive" ]
}
