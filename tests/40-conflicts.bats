#!/usr/bin/env bats
# Real-conflict coverage for the coordinated sync → resolve → merge lifecycle:
# the strict sync gate, rebase/stash/squash conflicts, continue/abort/resolve,
# partial-merge rollback+resume, and the coordination-identity fixes.

load helpers

setup() {
  setup_workspace
}

# Branch alpha, commit a conflicting local change, advance the remote main
# with different content on the same line.
make_conflict() {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-x >/dev/null 2>&1
  printf 'local change\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "local work"
  advance_remote alpha "remote change"
}

# A stash-pop conflict on main: unmerged index entries with NO git op marker
# (the state that used to be invisible to status/continue/abort).
make_markerless_conflict() {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  printf 'stash me\n' >alpha/README.md
  git -C alpha stash push -m "mcrepo: auto-stash before rebase" --include-untracked
  printf 'committed different\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "conflicting commit"
  run git -C alpha stash pop
  [ "$status" -ne 0 ]
}

@test "merge refuses when the branch is behind its parent (strict sync gate)" {
  make_conflict
  run mcrepo merge
  [ "$status" -eq 1 ]
  assert_contains "$output" "behind its parent"
  assert_contains "$output" "mcrepo rebase"
}

@test "rebase surfaces a conflict: exit 2, REBASING state, agent prompt" {
  make_conflict
  run mcrepo rebase
  [ "$status" -eq 2 ]
  assert_contains "$output" "Rebase conflicts"
  assert_contains "$output" "Paste the prompt"
  assert_contains "$output" "Resolve ONLY real semantic conflicts"
  assert_contains "$output" "✗ Rebase incomplete"
  run mcrepo status
  assert_contains "$output" "inprogress=REBASING"
}

@test "re-run loop: rebase again while unresolved reports files; after resolve+add the re-run finishes; merge fast-forwards the parent" {
  make_conflict
  run mcrepo rebase
  [ "$status" -eq 2 ]

  # Unresolved: the re-run must not pretend success — it names the files.
  run mcrepo rebase
  [ "$status" -eq 2 ]
  assert_contains "$output" "still conflicted"
  assert_contains "$output" "README.md"

  # Agent-style fix: edit + git add ONLY (no continue, no mcrepo needed).
  printf 'merged content\n' >alpha/README.md
  git -C alpha add README.md

  # The re-run finishes the paused rebase itself.
  run mcrepo rebase
  [ "$status" -eq 0 ]
  assert_contains "$output" "continuing the paused rebase"
  assert_contains "$output" "✓ Rebase complete"
  run mcrepo status
  assert_not_contains "$output" "inprogress="

  run mcrepo merge
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "main" ]
  # The stale-local-parent fix: origin/main must be an ancestor of local main.
  git -C alpha merge-base --is-ancestor origin/main main
}

@test "abort restores the pre-rebase state" {
  make_conflict
  pre_sha="$(git -C alpha rev-parse HEAD)"
  run mcrepo rebase
  [ "$status" -eq 2 ]
  run mcrepo abort
  [ "$status" -eq 0 ]
  [ "$(git -C alpha rev-parse HEAD)" = "$pre_sha" ]
  [ "$(repo_branch alpha)" = "feat-x" ]
  run mcrepo status
  assert_not_contains "$output" "inprogress="
}

@test "marker-less conflicts show as CONFLICTED with mcrepo-stash indicator" {
  make_markerless_conflict
  run mcrepo status
  assert_contains "$output" "inprogress=CONFLICTED"
  assert_contains "$output" "mcrepo-stash=1"
}

@test "hidden continue on a marker-less conflict explains and prints the prompt instead of 'No repository is mid-'" {
  make_markerless_conflict
  run mcrepo continue
  [ "$status" -eq 2 ]
  assert_not_contains "$output" "No repository is mid-"
  assert_contains "$output" "unmerged files but no merge/rebase in progress"
  assert_contains "$output" "Paste the prompt"
  assert_contains "$output" "re-run"
}

@test "abort clears a marker-less conflict and preserves the stash" {
  make_markerless_conflict
  run mcrepo abort
  [ "$status" -eq 0 ]
  [ -z "$(git -C alpha ls-files -u)" ]
  run git -C alpha stash list
  assert_contains "$output" "mcrepo: auto-stash before rebase"
  run mcrepo status
  assert_not_contains "$output" "inprogress="
  assert_contains "$output" "mcrepo-stash=1"
}

@test "pull stash-pop conflict exits 2 with prompt; resolve + add + re-run drops the stash and finishes" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  printf 'uncommitted local\n' >alpha/README.md
  advance_remote alpha "remote moved"
  run mcrepo pull
  [ "$status" -eq 2 ]
  assert_contains "$output" "Stash pop conflict"
  assert_contains "$output" "Paste the prompt"

  # Agent-style fix: edit + git add only, then re-run pull.
  printf 'both kept\n' >alpha/README.md
  git -C alpha add README.md
  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "dropped the already-applied mcrepo stash"
  [ -z "$(git -C alpha stash list)" ]
}

@test "partial merge rolls back the failed repo, keeps going, exits 2, and re-running finishes" {
  init_workspace_with_repos alpha beta
  mcrepo write alpha >/dev/null
  mcrepo write beta >/dev/null
  mcrepo branch feat-p >/dev/null 2>&1
  dirty_repo alpha
  dirty_repo beta
  run mcrepo commit -m "feature work"
  [ "$status" -eq 0 ]

  # Make beta's squash COMMIT fail (mechanical failure, not a conflict).
  printf '#!/bin/sh\nexit 1\n' >beta/.git/hooks/pre-commit
  chmod +x beta/.git/hooks/pre-commit

  run mcrepo merge
  [ "$status" -eq 2 ]
  assert_contains "$output" "PARTIAL"
  assert_contains "$output" "rolled back"
  assert_contains "$output" "Paste the prompt"
  [ "$(repo_branch alpha)" = "main" ]
  [ "$(repo_branch beta)" = "feat-p" ]
  [ -z "$(git -C beta status --porcelain)" ]
  grep -q '^branch: feat-p$' mcrepo.yaml

  rm beta/.git/hooks/pre-commit
  run mcrepo merge
  [ "$status" -eq 0 ]
  assert_contains "$output" "Skipping repos not on 'feat-p'"
  [ "$(repo_branch beta)" = "main" ]
  run mcrepo status
  assert_contains "$output" "Global branch: main"
}

@test "coordinated #N increments across sub-repo-only batches (meta-only count regression)" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  git_manage_workspace

  dirty_repo alpha
  run mcrepo commit -m "first"
  [ "$status" -eq 0 ]
  assert_contains "$(repo_subject alpha)" "mcrepo commit #1 @"

  dirty_repo alpha
  run mcrepo commit -m "second"
  [ "$status" -eq 0 ]
  assert_contains "$(repo_subject alpha)" "mcrepo commit #2 @"
}

@test "batch ids are unique across consecutive commits and still parse" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  dirty_repo alpha
  mcrepo commit -m "one" >/dev/null 2>&1
  dirty_repo alpha
  mcrepo commit -m "two" >/dev/null 2>&1
  b1="$(git -C alpha log --format=%s -1 --skip=1 | sed -n 's/^mcrepo commit #[0-9][0-9]* @\([^ ]*\):.*/\1/p')"
  b2="$(git -C alpha log --format=%s -1 | sed -n 's/^mcrepo commit #[0-9][0-9]* @\([^ ]*\):.*/\1/p')"
  [ -n "$b1" ]
  [ -n "$b2" ]
  [ "$b1" != "$b2" ]
}

@test "commit warns when a target repo is off the global branch but proceeds" {
  init_workspace_with_repos alpha beta
  mcrepo write alpha >/dev/null
  mcrepo write beta >/dev/null
  mcrepo branch feat-w >/dev/null 2>&1
  git -C beta checkout -q main
  dirty_repo alpha
  dirty_repo beta
  run mcrepo commit -m "mixed branches"
  [ "$status" -eq 0 ]
  assert_contains "$output" "beta (on 'main')"
  assert_contains "$output" "re-align"
  assert_contains "$(repo_subject alpha)" "mcrepo commit #"
  assert_contains "$(repo_subject beta)" "mcrepo commit #"
}

@test "rebase honors --include-read; without the flag it hints about read repos on the branch" {
  init_workspace_with_repos alpha beta
  mcrepo write alpha >/dev/null
  mcrepo read beta >/dev/null
  mcrepo branch feat-r --include-read >/dev/null 2>&1
  advance_remote beta "remote advance content"

  run mcrepo rebase
  [ "$status" -eq 0 ]
  assert_contains "$output" "re-run with --include-read"

  run mcrepo rebase --include-read
  [ "$status" -eq 0 ]
  run git -C beta log --format=%s
  assert_contains "$output" "remote advance beta"
  [ "$(repo_branch beta)" = "feat-r" ]
}

@test "resolve: stdout carries only the prompt body; clean workspace says nothing to resolve; merge --rebase warns deprecation" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  run mcrepo resolve
  [ "$status" -eq 0 ]
  assert_contains "$output" "Nothing to resolve"

  # Manufacture the marker-less conflict, then check the stdout contract.
  printf 'stash me\n' >alpha/README.md
  git -C alpha stash push -m "mcrepo: auto-stash before rebase" --include-untracked
  printf 'committed different\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "conflicting commit"
  git -C alpha stash pop || true

  body="$("$SANDBOX/mcrepo.sh" resolve 2>/dev/null)"
  assert_contains "$body" "I am working in an mcrepo workspace"
  assert_contains "$body" "(cd "
  assert_not_contains "$body" "Paste the prompt"

  # Deprecated alias still works and points at rebase.
  git -C alpha checkout -q -- . 2>/dev/null || true
  git -C alpha reset -q --merge 2>/dev/null || true
  git -C alpha stash drop >/dev/null 2>&1 || true
  mcrepo branch feat-d >/dev/null 2>&1
  run mcrepo merge --rebase
  [ "$status" -eq 0 ]
  assert_contains "$output" "Deprecation"
  assert_contains "$output" "mcrepo rebase"
}

@test "'mcrepo sync' remains a quiet alias of 'mcrepo rebase' (no deprecation warning)" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-alias >/dev/null 2>&1
  run mcrepo sync
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "Deprecation"
  assert_contains "$output" "Rebase"
}

@test "the rebase agent prompt carries progress, conflict kind, and the operation id" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-ctx >/dev/null 2>&1
  printf 'feature line\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "feature work"
  advance_remote alpha "parent moved"

  run mcrepo rebase
  [ "$status" -eq 2 ]
  assert_contains "$output" "Coordinated rebase 'rebase-"
  assert_contains "$output" "commit 1 of 1"
  assert_contains "$output" "both-modified"
  assert_contains "$output" "README.md"
  assert_contains "$output" "feature work"
}

@test "a conflicted mcrepo.sh does not strand the rebase: an intact launcher is offered" {
  init_workspace_with_repos alpha
  git_manage_workspace
  mcrepo write alpha >/dev/null
  # Put the tool itself into history the way a real workspace carries it.
  git add -A
  git commit -qm "workspace with mcrepo.sh"
  git init -q --bare "$REMOTES_DIR/meta.git"
  git remote add origin "file://$REMOTES_DIR/meta.git"
  git push -q -u origin main

  mcrepo branch feat-tool >/dev/null 2>&1
  # The feature branch carries an older tool version...
  sed -i.bak 's/^MCREPO_VERSION=.*/MCREPO_VERSION="0.5.6"/' mcrepo.sh && rm -f mcrepo.sh.bak
  git add -A
  git commit -qm "feature carries an old mcrepo.sh"

  # ...while main moved to a different one: a real conflict inside the script.
  git checkout -q main
  sed -i.bak 's/^MCREPO_VERSION=.*/MCREPO_VERSION="0.8.0"/' mcrepo.sh && rm -f mcrepo.sh.bak
  git add -A
  git commit -qm "main carries another mcrepo.sh"
  git push -q origin main
  git checkout -q feat-tool

  run mcrepo rebase
  [ "$status" -eq 2 ]
  # The hint has to come from THIS run: ./mcrepo.sh now holds conflict markers,
  # so re-running it is a bash syntax error and no later run could ever say so.
  assert_contains "$output" "conflict markers"
  snap="$(printf '%s\n' "$output" | sed -n 's/.*bash \(.*mcrepo-[^ ]*\.sh\) rebase.*/\1/p' | head -1)"
  [ -n "$snap" ]

  run bash -n ./mcrepo.sh
  [ "$status" -ne 0 ]
  # The offered launcher must actually be runnable.
  run bash -n "$snap"
  [ "$status" -eq 0 ]
  run bash "$snap" version
  [ "$status" -eq 0 ]
}
