#!/usr/bin/env bats
# Parent-stack hygiene: the 'parent:' chain is a strictly nested ancestry, so
# branch JUMPS must not leave abandoned levels behind. A leaked level used to
# deadlock 'merge' with "source is the same as parent" and could not be undone
# by rebase, merge, or branch --delete.

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

# 'mcrepo branch' leaves its own state write uncommitted in the meta-context;
# the next branch/merge dirty gate has no default answer without a TTY, so it
# must be committed between coordinated commands (mirrors the documented flow).
commit_meta_state() {
  git -C "$SANDBOX" add -A
  git -C "$SANDBOX" diff --cached --quiet || git -C "$SANDBOX" commit -qm "${1:-mcrepo state}"
}

@test "jumping back to a parent branch drops the abandoned level" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on feature"
  bash -c 'printf "y\n" | "$0" branch sub' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on sub"
  grep -q 'parent: main,feature' mcrepo.yaml

  # 'feature' already exists, so this is a jump — nothing was ever popped before.
  run bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "returned to parent level"
  grep -q 'branch: feature' mcrepo.yaml
  grep -q '^    parent: main$' mcrepo.yaml
  grep -q '^meta-parent: main$' mcrepo.yaml
  ! grep -q 'main,feature' mcrepo.yaml
}

@test "a branch jumped back to still merges into its real parent" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on feature"
  bash -c 'printf "y\n" | "$0" branch sub' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on sub"
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state back on feature"

  dirty_repo alpha
  mcrepo commit -m "work on feature" >/dev/null
  run bash -c 'printf "n\n" | "$0" merge -m "feat: feature"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "is the same as parent"
  [ "$(repo_branch alpha)" = "main" ]
  [ "$(repo_branch beta)" = "main" ]
  [ "$(repo_subject alpha)" = "feat: feature" ]
}

@test "nested branches still merge back one level at a time" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on feature"
  bash -c 'printf "y\n" | "$0" branch sub' "$SANDBOX/mcrepo.sh" >/dev/null
  # Normalization must NOT flatten a legitimate nested chain.
  grep -q 'parent: main,feature' mcrepo.yaml
  grep -q 'meta-parent: main,feature' mcrepo.yaml
  commit_meta_state "state on sub"

  dirty_repo alpha
  mcrepo commit -m "sub work" >/dev/null
  run bash -c 'printf "n\n" | "$0" merge -m "feat: sub"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "feature" ]
  grep -q 'branch: feature' mcrepo.yaml
  grep -q '^    parent: main$' mcrepo.yaml
  assert_contains "$output" "next parent level"
  commit_meta_state "state after first merge"

  run bash -c 'printf "n\n" | "$0" merge -m "feat: feature"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "main" ]
  [ "$(repo_subject alpha)" = "feat: feature" ]
  assert_not_contains "$output" "next parent level"
}

@test "re-running branch on the active branch keeps the recorded parent" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on feature"
  grep -q '^    parent: main$' mcrepo.yaml

  # Re-activating the branch the chain was recorded against is NOT a jump to an
  # unrelated branch: 'feature' is never IN its own chain, so a naive
  # "not in the chain => clear it" rule would destroy the correct parent.
  run bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "parent 'main' kept"
  assert_not_contains "$output" "parent chain cleared"
  grep -q '^    parent: main$' mcrepo.yaml
  grep -q '^meta-parent: main$' mcrepo.yaml

  # ... and the branch still merges into its real parent afterwards.
  dirty_repo alpha
  mcrepo commit -m "work" >/dev/null
  run bash -c 'printf "n\n" | "$0" merge -m "feat: kept"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "main" ]
}

@test "jumping to a branch outside the recorded chain clears the stale parent" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on feature"
  # An unrelated branch that already exists everywhere => a jump, not a fork.
  git -C "$SANDBOX/alpha" branch other main
  git -C "$SANDBOX/beta" branch other main
  git -C "$SANDBOX" branch other main

  run bash -c 'printf "y\n" | "$0" branch other' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "parent chain cleared"
  ! grep -q '^    parent:' mcrepo.yaml
  ! grep -q '^meta-parent:' mcrepo.yaml
}

@test "doctor reports a corrupt parent chain without rewriting the manifest" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch vm-archive' "$SANDBOX/mcrepo.sh" >/dev/null

  # Seed exactly what repeated fork/jump cycles used to write.
  awk '{ sub(/^[ ]*parent: .*/, "    parent: main,main,main,vm-archive")
         sub(/^meta-parent: .*/, "meta-parent: main,main,main,vm-archive")
         print }' mcrepo.yaml >mcrepo.yaml.seed
  mv mcrepo.yaml.seed mcrepo.yaml

  run mcrepo doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "stale parent chain"
  # doctor is read-only: the manifest is untouched
  grep -q 'parent: main,main,main,vm-archive' mcrepo.yaml
}

@test "a corrupt parent chain is repaired by the next command that saves" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch vm-archive' "$SANDBOX/mcrepo.sh" >/dev/null
  awk '{ sub(/^[ ]*parent: .*/, "    parent: main,main,main,vm-archive")
         sub(/^meta-parent: .*/, "meta-parent: main,main,main,vm-archive")
         print }' mcrepo.yaml >mcrepo.yaml.seed
  mv mcrepo.yaml.seed mcrepo.yaml

  run mcrepo write alpha
  [ "$status" -eq 0 ]
  ! grep -q 'main,main,main' mcrepo.yaml
  grep -q '^    parent: main$' mcrepo.yaml
  grep -q '^meta-parent: main$' mcrepo.yaml

  # ... and the branch is mergeable again instead of being its own parent.
  commit_meta_state "state on vm-archive"
  dirty_repo alpha
  mcrepo commit -m "archive work" >/dev/null
  run bash -c 'printf "n\n" | "$0" merge -m "feat: vm-archive"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "is the same as parent"
  [ "$(repo_branch alpha)" = "main" ]
}

@test "rebase does not claim success when there is no parent to rebase onto" {
  coordinated_workspace
  # Coordinating on the default branch itself: no chain is recorded, so the
  # parent falls back to the detected default — which is the source branch.
  # That is not "in sync", it is "nothing to rebase onto", and saying ✓ here is
  # what hid the broken state while 'merge' kept failing.
  bash -c 'printf "y\n" | "$0" branch main' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on main"

  run mcrepo rebase
  assert_not_contains "$output" "already in sync"
  assert_contains "$output" "Nothing to rebase for"
}
