#!/usr/bin/env bats
# Multi-device / origin workflow: plain 'mcrepo pull' as the origin-side twin
# of 'mcrepo rebase' (auto-stash + real rebase onto origin, safe-force protection,
# --ff-only conservative mode) and the stuck-workspace guard.

load helpers

setup() {
  setup_workspace
}

@test "multi-device: pull replays local commits on top of remote work, then plain push" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  printf 'local feature\n' >alpha/local.txt
  git -C alpha add -A
  git -C alpha commit -qm "device A work"
  advance_remote alpha "device B change"

  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "Rebased onto origin"
  assert_contains "$output" "✓ Pull complete"

  run git -C alpha log --format=%s
  assert_contains "$output" "device A work"
  assert_contains "$output" "remote advance alpha"

  run mcrepo push
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "Force-pushed"
  run mcrepo status
  assert_contains "$output" "in-sync"
}

@test "multi-device conflict: pull pauses as REBASING, continue + re-run + push finish it" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  printf 'device A line\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "device A conflicting"
  advance_remote alpha "device B line"

  run mcrepo pull
  [ "$status" -eq 2 ]
  assert_contains "$output" "Rebase conflicts"
  assert_contains "$output" "Paste the prompt"
  run mcrepo status
  assert_contains "$output" "inprogress=REBASING"

  # Agent-style fix: edit + git add only, then re-run pull (no continue).
  printf 'both lines merged\n' >alpha/README.md
  git -C alpha add README.md
  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "continuing the paused rebase"
  run mcrepo push
  [ "$status" -eq 0 ]
  run mcrepo status
  assert_contains "$output" "in-sync"
}

@test "dirty + behind: pull carries uncommitted work across the update" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  printf 'uncommitted notes\n' >alpha/notes.txt
  advance_remote alpha "remote moved"

  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "Updated"
  [ -f alpha/notes.txt ]
  run git -C alpha log --format=%s
  assert_contains "$output" "remote advance alpha"
}

@test "safe-force protection: pull never rebases onto a stale post-sync remote" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-sf >/dev/null 2>&1
  printf 'feature work\n' >alpha/f.txt
  git -C alpha add -A
  git -C alpha commit -qm "feature work"
  git -C alpha push -q -u origin feat-sf
  advance_remote alpha "parent moved"

  run mcrepo rebase
  [ "$status" -eq 0 ]

  count_before="$(git -C alpha rev-list --count feat-sf)"
  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "Rebased locally"
  assert_contains "$output" "mcrepo push"
  [ "$(git -C alpha rev-list --count feat-sf)" = "$count_before" ]

  run mcrepo push
  [ "$status" -eq 0 ]
  assert_contains "$output" "Force-pushed"
}

@test "B3 protection: new commits stacked on a stale post-sync remote are never rebased away or force-deleted" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-b3 >/dev/null 2>&1
  printf 'feature work\n' >alpha/f.txt
  git -C alpha add -A
  git -C alpha commit -qm "feature work"
  git -C alpha push -q -u origin feat-b3
  advance_remote alpha "parent moved"
  run mcrepo rebase
  [ "$status" -eq 0 ]

  # Device B pushes a NEW commit onto the (now stale) origin/feat-b3.
  b_clone="$BATS_TEST_TMPDIR/device-b"
  git clone -q -b feat-b3 "$REMOTES_DIR/alpha.git" "$b_clone"
  printf 'device B work\n' >"$b_clone/b3.txt"
  git -C "$b_clone" add -A
  git -C "$b_clone" commit -qm "device B new work"
  git -C "$b_clone" push -q origin feat-b3

  # pull must NOT rebase (would resurrect stale history) and NOT
  # route to push (force would delete device B's commit) — ambiguous prompt.
  run mcrepo pull
  [ "$status" -eq 2 ]
  assert_contains "$output" "Diverged"
  assert_contains "$output" "Paste the prompt"
  assert_not_contains "$output" "Rebased onto origin"
  assert_not_contains "$output" "Rebased locally"

  # push must refuse too — device B's commit survives on the remote.
  run mcrepo push
  [ "$status" -eq 1 ]
  git -C alpha fetch -q origin
  run git -C alpha log --format=%s origin/feat-b3
  assert_contains "$output" "device B new work"
}

@test "safe-force survives the parent advancing after sync (patch-equivalence proof)" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-pa >/dev/null 2>&1
  printf 'feature work\n' >alpha/f.txt
  git -C alpha add -A
  git -C alpha commit -qm "feature work"
  git -C alpha push -q -u origin feat-pa
  advance_remote alpha "parent move 1"
  run mcrepo rebase
  [ "$status" -eq 0 ]

  # Parent moves AGAIN after the sync — the old ancestry proof broke here and
  # sent the repo into a rebase onto its own stale remote (resurrection bug).
  advance_remote alpha "parent move 2"
  count_before="$(git -C alpha rev-list --count feat-pa)"
  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "Rebased locally"
  assert_not_contains "$output" "Rebased onto origin"
  [ "$(git -C alpha rev-list --count feat-pa)" = "$count_before" ]
}

@test "push skips mid-operation/conflicted repos instead of committing conflict markers" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  git -C alpha push -q -u origin main 2>/dev/null || git -C alpha branch -q -u origin/main main
  printf 'stash me\n' >alpha/README.md
  git -C alpha stash push -m "mcrepo: auto-stash before rebase" --include-untracked
  printf 'committed different\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "conflicting commit"
  run git -C alpha stash pop
  [ "$status" -ne 0 ]

  run mcrepo push -m "must not be committed"
  assert_contains "$output" "mid-operation/conflicted"
  [ "$(git -C alpha log -1 --format=%s)" = "conflicting commit" ]
  [ -n "$(git -C alpha ls-files -u)" ]
}

@test "pull --ff-only stays conservative (dirty repo skipped, nothing stashed); --rebase alias warns and integrates" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  printf 'uncommitted local\n' >alpha/notes.txt
  advance_remote alpha "remote moved"

  run mcrepo pull --ff-only
  [ "$status" -eq 0 ]
  assert_contains "$output" "(dirty)"
  [ -f alpha/notes.txt ]
  [ -z "$(git -C alpha stash list)" ]
  run git -C alpha log --format=%s
  assert_not_contains "$output" "remote advance alpha"

  run mcrepo pull --rebase
  [ "$status" -eq 0 ]
  assert_contains "$output" "Deprecation"
  [ -f alpha/notes.txt ]
  run git -C alpha log --format=%s
  assert_contains "$output" "remote advance alpha"
}

@test "a rebase the USER started is never touched by pull (foreign-rebase protection)" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  # Manufacture a user-started rebase paused on a conflict (plain git).
  git -C alpha checkout -qb side HEAD
  printf 'side change\n' >alpha/README.md
  git -C alpha add -A && git -C alpha commit -qm "side work"
  git -C alpha checkout -q main
  printf 'main change\n' >alpha/README.md
  git -C alpha add -A && git -C alpha commit -qm "main work"
  git -C alpha checkout -q side
  run git -C alpha rebase main
  [ "$status" -ne 0 ]

  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "manual rebase in progress"
  # The user's rebase is still paused, untouched.
  run mcrepo status
  assert_contains "$output" "inprogress=REBASING"
  git -C alpha rebase --abort
}

@test "branch re-run does not dirty-gate repos already on the target branch" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-dg >/dev/null 2>&1
  printf 'kept local work\n' >alpha/notes.txt
  run mcrepo branch feat-dg
  [ "$status" -eq 0 ]
  [ -f alpha/notes.txt ]
  [ "$(repo_branch alpha)" = "feat-dg" ]
}

@test "a git bisect session neither blocks coordinated commands nor confuses resolve" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  git -C alpha bisect start
  run mcrepo status
  assert_contains "$output" "inprogress=BISECTING"
  run mcrepo pull
  [ "$status" -eq 0 ]
  run mcrepo resolve
  [ "$status" -eq 0 ]
  assert_contains "$output" "Nothing to resolve"
  git -C alpha bisect reset >/dev/null 2>&1
}

@test "stuck-workspace guard: pull/commit/branch refuse over a conflicted repo; mcrepo stashes alone do not block" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  # marker-less conflict + mcrepo stash
  printf 'stash me\n' >alpha/README.md
  git -C alpha stash push -m "mcrepo: auto-stash before rebase" --include-untracked
  printf 'committed different\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "conflicting commit"
  run git -C alpha stash pop
  [ "$status" -ne 0 ]

  # pull may proceed (re-run is the resume path) but reports the conflict.
  run mcrepo pull
  [ "$status" -eq 2 ]
  assert_contains "$output" "conflicted"
  # commit stays strictly guarded; branch dies on the unresolved carry state.
  run mcrepo commit -m "should not work"
  [ "$status" -eq 1 ]
  assert_contains "$output" "mid-operation or conflicted"
  run mcrepo branch feat-blocked
  [ "$status" -eq 1 ]

  # abort clears the conflict; the remaining mcrepo stash must NOT block pull
  run mcrepo abort
  [ "$status" -eq 0 ]
  run git -C alpha stash list
  assert_contains "$output" "mcrepo:"
  run mcrepo pull
  [ "$status" -eq 0 ]
}
