#!/usr/bin/env bats
# The parent map: 'parent:' holds "<branch>:<parent>" entries, so a record
# belongs to its branch rather than to whatever is checked out. Leaving a branch
# and coming back must preserve it — the flat stack this replaced could not,
# which is what made merges deadlock and hand-repairs evaporate.

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

@test "the parent record survives leaving a branch and coming back" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on feature"
  grep -q 'parent: feature:main' mcrepo.yaml

  # Leave for main ...
  bash -c 'printf "y\n" | "$0" branch main' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on main"
  grep -q 'parent: feature:main' mcrepo.yaml
  grep -q 'meta-parent: feature:main' mcrepo.yaml

  # ... and come back. The record is untouched, no prompt needed.
  run bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  assert_contains "$output" "parent 'main'"
  assert_not_contains "$output" "No parent is recorded"
  grep -q 'parent: feature:main' mcrepo.yaml
  # That the preserved record actually drives the merge target is proven by
  # "branch --parent sets the record outright and it sticks" below.
}

@test "nested forks build a tree and merge back one level at a time" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "state on feature"
  bash -c 'printf "y\n" | "$0" branch sub' "$SANDBOX/mcrepo.sh" >/dev/null
  # Both levels coexist as separate entries — no stack inside one value.
  grep -q 'parent: feature:main,sub:feature' mcrepo.yaml
  grep -q 'meta-parent: feature:main,sub:feature' mcrepo.yaml
  commit_meta_state "state on sub"

  dirty_repo alpha
  mcrepo commit -m "sub work" >/dev/null
  run bash -c 'printf "n\n" | "$0" merge -m "feat: sub"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "feature" ]
  # Only sub's entry is consumed; feature's remains.
  grep -q 'parent: feature:main' mcrepo.yaml
  ! grep -q 'sub:feature' mcrepo.yaml
  assert_contains "$output" "next parent level"
  commit_meta_state "state after first merge"

  run bash -c 'printf "n\n" | "$0" merge -m "feat: feature"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "main" ]
  ! grep -q '^    parent:' mcrepo.yaml
  assert_not_contains "$output" "next parent level"
}

@test "sibling forks are recorded separately instead of piling up" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature-a' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "a"
  bash -c 'printf "y\n" | "$0" branch main' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "back to main"
  bash -c 'printf "y\n" | "$0" branch feature-b' "$SANDBOX/mcrepo.sh" >/dev/null

  # The flat stack wrote 'main,main' here and could not tell the two apart.
  grep -q 'parent: feature-a:main,feature-b:main' mcrepo.yaml
  ! grep -q 'main,main' mcrepo.yaml
}

@test "a jump into a branch with no record offers the branch you came from" {
  coordinated_workspace
  # A branch mcrepo did not create => no entry anywhere.
  git -C "$SANDBOX/alpha" branch outside main
  git -C "$SANDBOX/beta" branch outside main
  git -C "$SANDBOX" branch outside main

  # No TTY, so confirm takes its default — which is 'n'. The offer is shown,
  # nothing is written: an unattended run must never guess a parent.
  run mcrepo branch outside
  [ "$status" -eq 0 ]
  assert_contains "$output" "No parent is recorded"
  assert_contains "$output" "alpha → main"
  assert_contains "$output" "Left unrecorded"
  ! grep -q 'outside:' mcrepo.yaml
}

@test "accepting the offer records the branch you came from" {
  coordinated_workspace
  git -C "$SANDBOX/alpha" branch outside main
  git -C "$SANDBOX/beta" branch outside main
  git -C "$SANDBOX" branch outside main

  MCREPO_ASSUME_YES=1 run mcrepo branch outside
  [ "$status" -eq 0 ]
  grep -q 'parent: outside:main' mcrepo.yaml
  grep -q 'meta-parent: outside:main' mcrepo.yaml
}

@test "moving up the tree never offers the child as its parent's parent" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "on feature"

  # Jumping feature -> main: main has no record, but recording 'feature' as
  # main's parent would invert the tree, so it must not even be offered.
  MCREPO_ASSUME_YES=1 run mcrepo branch main
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "No parent is recorded"
  ! grep -q 'main:feature' mcrepo.yaml
  grep -q 'parent: feature:main' mcrepo.yaml
}

@test "branch --parent sets the record outright and it sticks" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "on feature"
  git -C "$SANDBOX/alpha" branch base main
  git -C "$SANDBOX/beta" branch base main
  git -C "$SANDBOX" branch base main

  run mcrepo branch feature --parent base
  [ "$status" -eq 0 ]
  assert_contains "$output" "parent set to 'base'"
  grep -q 'parent: feature:base' mcrepo.yaml
  ! grep -q 'feature:main' mcrepo.yaml
  commit_meta_state "reparented"

  # Survives a round-trip, and merge honours it.
  bash -c 'printf "y\n" | "$0" branch main' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "on main"
  grep -q 'parent: feature:base' mcrepo.yaml
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  commit_meta_state "back on feature"

  dirty_repo alpha
  mcrepo commit -m "work" >/dev/null
  run bash -c 'printf "n\n" | "$0" merge -m "feat: onto base"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "base" ]
}

@test "a pre-0.9 parent stack is converted on the next command" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch vm-archive' "$SANDBOX/mcrepo.sh" >/dev/null

  # Seed exactly what repeated fork/jump cycles used to write.
  awk '{ sub(/^[ ]*parent: .*/, "    parent: main,main,main,vm-archive")
         sub(/^meta-parent: .*/, "meta-parent: main,main,main,vm-archive")
         sub(/^schema: .*/, "schema: 1")
         print }' mcrepo.yaml >mcrepo.yaml.seed
  mv mcrepo.yaml.seed mcrepo.yaml

  run mcrepo doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "pre-0.9 parent value"
  # doctor is read-only
  grep -q 'parent: main,main,main,vm-archive' mcrepo.yaml

  run mcrepo write alpha
  [ "$status" -eq 0 ]
  grep -q 'parent: vm-archive:main' mcrepo.yaml
  grep -q 'meta-parent: vm-archive:main' mcrepo.yaml
  ! grep -q 'main,main' mcrepo.yaml

  # ... and the branch is mergeable, into main rather than into itself.
  commit_meta_state "converted"
  dirty_repo alpha
  mcrepo commit -m "archive work" >/dev/null
  run bash -c 'printf "n\n" | "$0" merge -m "feat: vm-archive"' "$SANDBOX/mcrepo.sh"
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "is the same as parent"
  [ "$(repo_branch alpha)" = "main" ]
}

@test "a healthy pre-0.9 single-level stack keeps its meaning" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  awk '{ sub(/^[ ]*parent: .*/, "    parent: main")
         sub(/^meta-parent: .*/, "meta-parent: main")
         sub(/^schema: .*/, "schema: 1")
         print }' mcrepo.yaml >mcrepo.yaml.seed
  mv mcrepo.yaml.seed mcrepo.yaml

  run mcrepo write alpha
  [ "$status" -eq 0 ]
  grep -q 'parent: feature:main' mcrepo.yaml
  grep -q 'meta-parent: feature:main' mcrepo.yaml
}

@test "branch --off keeps the parent records" {
  coordinated_workspace
  bash -c 'printf "y\n" | "$0" branch feature' "$SANDBOX/mcrepo.sh" >/dev/null
  grep -q 'parent: feature:main' mcrepo.yaml

  run mcrepo branch --off
  [ "$status" -eq 0 ]
  ! grep -q '^branch:' mcrepo.yaml
  # The branches still exist, so their fork points are still worth knowing.
  grep -q 'parent: feature:main' mcrepo.yaml
}
