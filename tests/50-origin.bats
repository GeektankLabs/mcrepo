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

@test "conflict-resolved rebase is publishable: resolution mutates patch ids, push must still go out" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-cr >/dev/null 2>&1
  # The feature commit touches the SAME line advance_remote rewrites, so the
  # rebase must stop and the resolution necessarily changes the commit's patch id.
  printf 'feature line\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "feature work"
  git -C alpha push -q -u origin feat-cr
  remote_before="$(git -C alpha rev-parse origin/feat-cr)"
  advance_remote alpha "parent moved"

  run mcrepo rebase
  [ "$status" -eq 2 ]
  assert_contains "$output" "Rebase conflicts"

  # Agent-style fix: edit + git add only, then re-run rebase.
  printf 'parent moved\nfeature line\n' >alpha/README.md
  git -C alpha add README.md
  run mcrepo rebase
  [ "$status" -eq 0 ]

  # The rebase is done and origin/feat-cr is untouched since it began, so this
  # is provably our own rewrite — even though patch equivalence cannot show it.
  [ "$(git -C alpha rev-parse origin/feat-cr)" = "$remote_before" ]
  run git -C alpha rev-list --left-only --cherry-pick --count 'origin/feat-cr...HEAD'
  [ "$output" != "0" ]

  run mcrepo push
  [ "$status" -eq 0 ]
  git -C alpha fetch -q origin
  [ "$(git -C alpha rev-parse origin/feat-cr)" = "$(git -C alpha rev-parse HEAD)" ]
  run git -C alpha log --format=%s origin/feat-cr
  assert_contains "$output" "feature work"
  assert_contains "$output" "remote advance alpha"
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

# --- mcrepo.yaml reconciliation across machines ---------------------------
#
# The manifest is committed and shared, but mcrepo rewrites it canonically on
# every coordinated command, so two machines edit the SAME lines without either
# of them touching code. Letting git merge that textually produced conflicts in
# mcrepo's own state file. pull now takes it out of the stash entirely and
# merges it field by field.

# A workspace whose meta-context has an origin, plus one sub-repo.
meta_workspace() {
  init_workspace_with_repos alpha beta
  git_manage_workspace
  make_meta_remote
}

@test "a dirty mcrepo.yaml never reaches the stash and never conflicts on pull" {
  meta_workspace
  # Local machine records coordination state -> manifest is dirty, exactly the
  # 'branch:'/'parent:' churn that collided with origin before.
  mcrepo branch vm-archive >/dev/null 2>&1
  git checkout -q main
  [ -n "$(git status --porcelain -- mcrepo.yaml)" ]
  # Other machine edits a description and pushes it to main.
  device_b_meta sed -i.bak 's|description: ""|description: "from device B"|' mcrepo.yaml

  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "Stash conflicts"
  assert_not_contains "$output" "restoring auto-stashed changes conflicted"

  run cat mcrepo.yaml
  assert_not_contains "$output" "<<<<<<<"
  assert_contains "$output" "from device B"

  run git stash list
  [ -z "$output" ]
}

@test "pull --ff-only also keeps mcrepo.yaml out of the auto-stash" {
  meta_workspace
  mcrepo branch feature-x >/dev/null 2>&1
  git checkout -q main
  device_b_meta sed -i.bak 's|description: ""|description: "ff-only device B"|' mcrepo.yaml

  run mcrepo pull --ff-only
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "Stash conflicts"
  run cat mcrepo.yaml
  assert_not_contains "$output" "<<<<<<<"
  assert_contains "$output" "ff-only device B"
}

@test "parent maps merge key by key instead of colliding textually" {
  meta_workspace
  # Local records feature-x's parent...
  mcrepo branch feature-x >/dev/null 2>&1
  git checkout -q main
  # ...device B records a different branch's parent in the same lines.
  device_b_meta sed -i.bak 's|^repos:|meta-parent: other:main\nrepos:|' mcrepo.yaml

  run mcrepo pull
  [ "$status" -eq 0 ]
  run cat mcrepo.yaml
  assert_contains "$output" "feature-x:main"
  assert_contains "$output" "other:main"
  # The pre-0.9 positional corruption must never reappear.
  assert_not_contains "$output" "main,main"
}

@test "a repo added on another device arrives; a local-only addition survives" {
  meta_workspace
  local gamma_url
  gamma_url="$(make_remote gamma)"
  device_b_meta sed -i.bak "s|^repos:|repos:\n  - url: $gamma_url\n    name: gamma\n    mode: read\n    description: \"\"\n    localpath: ./gamma|" mcrepo.yaml

  local delta_url
  delta_url="$(make_remote delta)"
  mcrepo add "$delta_url" delta >/dev/null

  run mcrepo pull
  [ "$status" -eq 0 ]
  run cat mcrepo.yaml
  assert_contains "$output" "name: gamma"
  assert_contains "$output" "name: delta"
  assert_contains "$output" "name: alpha"
}

@test "a repo removed on another device is removed locally too" {
  meta_workspace
  mcrepo branch feature-x >/dev/null 2>&1
  git checkout -q main
  device_b_meta "$SANDBOX/mcrepo.sh" remove beta --force --keep-files

  run mcrepo pull
  [ "$status" -eq 0 ]
  run cat mcrepo.yaml
  assert_not_contains "$output" "name: beta"
  assert_contains "$output" "name: alpha"
}

@test "a field changed on both sides keeps origin's value and names the field" {
  meta_workspace
  sed -i.bak 's|description: ""|description: "local text"|' mcrepo.yaml && rm -f mcrepo.yaml.bak
  device_b_meta sed -i.bak 's|description: ""|description: "origin text"|' mcrepo.yaml

  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "description of"
  assert_contains "$output" "keeping origin's"
  run cat mcrepo.yaml
  assert_contains "$output" "origin text"
  assert_not_contains "$output" "local text"
}

@test "manifest drift left by 'mcrepo update' leaves the meta-context clean after pull" {
  meta_workspace
  # Reproduce exactly what the old cmd_post_update_migrate left behind: a
  # canonical rewrite of a manifest that carries no extra information.
  sed -i.bak '/^schema:/d' mcrepo.yaml && rm -f mcrepo.yaml.bak
  git add -A && git commit -qm "manifest without schema stamp" && git push -q origin main
  MCREPO_SUPPRESS_VERSION_BANNER=1 "$SANDBOX/mcrepo.sh" --post-update-migrate 0.9.0 0.9.2 >/dev/null 2>&1 || true
  [ -n "$(git status --porcelain -- mcrepo.yaml)" ]

  device_b_meta sh -c 'printf "device B note\n" > notes.txt'

  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "Stash conflicts"
  # Nothing left to commit: the local dirt said nothing origin did not.
  run git status --porcelain -- mcrepo.yaml
  [ -z "$output" ]
  [ -f notes.txt ]
}

@test "an unrelated dirty file is still carried by the auto-stash" {
  meta_workspace
  printf 'work in progress\n' >scratch.txt
  sed -i.bak 's|description: ""|description: "local text"|' mcrepo.yaml && rm -f mcrepo.yaml.bak
  device_b_meta sh -c 'printf "device B note\n" > notes.txt'

  run mcrepo pull
  [ "$status" -eq 0 ]
  [ -f notes.txt ]
  run cat scratch.txt
  assert_contains "$output" "work in progress"
  run cat mcrepo.yaml
  assert_contains "$output" "local text"
}

@test "a rebase conflict parks mcrepo.yaml; resolving and re-running applies it" {
  meta_workspace
  mcrepo branch feature-x >/dev/null 2>&1
  git checkout -q main
  printf 'device A line\n' >conflict.txt
  # Commit ONLY the conflict source: mcrepo.yaml must stay dirty so the pull has
  # something to park while the rebase is paused.
  git add conflict.txt && git commit -qm "device A conflict source"
  [ -n "$(git status --porcelain -- mcrepo.yaml)" ]
  device_b_meta sh -c 'printf "device B line\n" > conflict.txt'

  run mcrepo pull
  [ "$status" -eq 2 ]
  # The manifest is parked in the object database, not smeared with markers.
  run git rev-parse -q --verify refs/mcrepo/manifest-ours
  [ "$status" -eq 0 ]
  run cat mcrepo.yaml
  assert_not_contains "$output" "<<<<<<<"

  printf 'resolved\n' >conflict.txt
  git add conflict.txt
  run mcrepo pull
  [ "$status" -eq 0 ]
  run git rev-parse -q --verify refs/mcrepo/manifest-ours
  [ "$status" -ne 0 ]
  run cat mcrepo.yaml
  assert_contains "$output" "feature-x:main"
}

@test "pull --reset discards local manifest state and leaves no parking ref" {
  meta_workspace
  sed -i.bak 's|description: ""|description: "local text"|' mcrepo.yaml && rm -f mcrepo.yaml.bak
  device_b_meta sed -i.bak 's|description: ""|description: "origin text"|' mcrepo.yaml

  run mcrepo pull --reset --yes
  [ "$status" -eq 0 ]
  run cat mcrepo.yaml
  assert_contains "$output" "origin text"
  assert_not_contains "$output" "local text"
  run git rev-parse -q --verify refs/mcrepo/manifest-ours
  [ "$status" -ne 0 ]
}

@test "a manifest from a newer schema parks instead of being downgraded" {
  meta_workspace
  sed -i.bak 's|description: ""|description: "local text"|' mcrepo.yaml && rm -f mcrepo.yaml.bak
  device_b_meta sed -i.bak 's|^schema: .*|schema: 99|' mcrepo.yaml

  run mcrepo pull
  assert_contains "$output" "newer manifest schema"
  run git rev-parse -q --verify refs/mcrepo/manifest-ours
  [ "$status" -eq 0 ]
  run cat mcrepo.yaml
  assert_contains "$output" "schema: 99"
}

@test "MCREPO_NO_MANIFEST_MERGE=1 restores the old stash behaviour" {
  meta_workspace
  sed -i.bak 's|description: ""|description: "local text"|' mcrepo.yaml && rm -f mcrepo.yaml.bak
  device_b_meta sed -i.bak 's|description: ""|description: "origin text"|' mcrepo.yaml

  MCREPO_NO_MANIFEST_MERGE=1 run mcrepo pull
  run git rev-parse -q --verify refs/mcrepo/manifest-ours
  [ "$status" -ne 0 ]
}

# --- dirty-repo handling on pull -----------------------------------------
#
# A machine that only consumes code still gets dirty repos: running a build
# writes into tracked paths. Pull used to stash unconditionally and stop dead
# when the pop conflicted, naming no files. Now it asks, and always offers
# "discard and take origin's state".

# alpha with a tracked build artifact that origin also advances, so a carry
# provokes a real stash-pop conflict on a tracked path.
colliding_artifact_workspace() {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  local seed="$BATS_TEST_TMPDIR/seed-alpha"
  mkdir -p "$seed/dist"
  printf 'v1\n' >"$seed/dist/bundle.tar.gz"
  git -C "$seed" add -A
  git -C "$seed" commit -qm "seed bundle"
  git -C "$seed" push -q "$REMOTES_DIR/alpha.git" main
  git -C alpha pull -q --ff-only
  # origin ships a new bundle...
  printf 'v2-from-origin\n' >"$seed/dist/bundle.tar.gz"
  git -C "$seed" add -A
  git -C "$seed" commit -qm "new bundle"
  git -C "$seed" push -q "$REMOTES_DIR/alpha.git" main
  # ...while this machine built its own at the same tracked path.
  printf 'v2-local-build\n' >alpha/dist/bundle.tar.gz
}

@test "a stash-pop conflict names the conflicting file on the FIRST run" {
  colliding_artifact_workspace
  run mcrepo pull
  [ "$status" -eq 2 ]
  assert_contains "$output" "restoring auto-stashed changes conflicted"
  assert_contains "$output" "both-modified"
  assert_contains "$output" "dist/bundle.tar.gz"
  # ...and the agent prompt carries it too, instead of naming only the repo.
  assert_contains "$output" "conflicted files (kind and path)"
}

@test "pull --dirty discard takes origin's state and never conflicts" {
  colliding_artifact_workspace
  run mcrepo pull --dirty discard
  [ "$status" -eq 0 ]
  assert_contains "$output" "Discarded local:  alpha"
  assert_not_contains "$output" "Stash conflicts"
  run cat alpha/dist/bundle.tar.gz
  assert_contains "$output" "v2-from-origin"
  [ -z "$(git -C alpha stash list)" ]
  [ -z "$(git -C alpha status --porcelain)" ]
}

@test "pull --dirty carry is the pre-0.9.3 behaviour" {
  colliding_artifact_workspace
  run mcrepo pull --dirty carry
  [ "$status" -eq 2 ]
  assert_contains "$output" "Stash conflicts"
  # Stash preserved as backup, exactly as before.
  run git -C alpha stash list
  assert_contains "$output" "mcrepo:"
}

@test "pull with no flag and no TTY still carries (unchanged default)" {
  colliding_artifact_workspace
  run mcrepo pull
  [ "$status" -eq 2 ]
  assert_contains "$output" "Stash conflicts"
  run git -C alpha stash list
  assert_contains "$output" "mcrepo:"
}

@test "pull --dirty abort changes nothing and restores the parked manifest" {
  meta_workspace
  mcrepo branch feature-x >/dev/null 2>&1
  git checkout -q main
  dirty_repo alpha
  advance_remote alpha "origin moved"

  run mcrepo pull --dirty abort
  [ "$status" -ne 0 ]
  assert_contains "$output" "uncommitted changes"
  assert_contains "$output" "--dirty discard"
  # Nothing touched: still dirty, still behind, nothing stashed.
  [ -n "$(git -C alpha status --porcelain)" ]
  [ -z "$(git -C alpha stash list)" ]
  # The manifest parked in Phase 1 must be back in the working tree.
  run git rev-parse -q --verify refs/mcrepo/manifest-ours
  [ "$status" -ne 0 ]
  run cat mcrepo.yaml
  assert_contains "$output" "feature-x"
}

@test "pull --ff-only --dirty discard updates a repo it would otherwise skip" {
  colliding_artifact_workspace
  run mcrepo pull --ff-only --dirty discard
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "fetch only (dirty)"
  run cat alpha/dist/bundle.tar.gz
  assert_contains "$output" "v2-from-origin"
}

@test "a meta-context dirty only in mcrepo.yaml is never prompted about" {
  meta_workspace
  mcrepo branch feature-x >/dev/null 2>&1
  git checkout -q main
  [ -n "$(git status --porcelain -- mcrepo.yaml)" ]
  device_b_meta sed -i.bak 's|description: ""|description: "device B"|' mcrepo.yaml

  # --dirty abort would stop the pull if the meta-context still counted as
  # dirty; the manifest is taken out before the dirty state is measured.
  run mcrepo pull --dirty abort
  [ "$status" -eq 0 ]
  assert_contains "$output" "(meta-context)       branch=main                 state=clean"
  run cat mcrepo.yaml
  assert_contains "$output" "device B"
  assert_contains "$output" "feature-x"
}

@test "a gitignored generated file conflicting through a stash pop is auto-cleaned" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  local seed="$BATS_TEST_TMPDIR/seed-alpha"
  printf '__pycache__/\n' >"$seed/.gitignore"
  mkdir -p "$seed/__pycache__"
  printf 'v1\n' >"$seed/__pycache__/x.pyc"
  git -C "$seed" add -A -f
  git -C "$seed" commit -qm "seed tracked bytecode"
  git -C "$seed" push -q "$REMOTES_DIR/alpha.git" main
  git -C alpha pull -q --ff-only
  printf 'v2-origin\n' >"$seed/__pycache__/x.pyc"
  git -C "$seed" add -A -f
  git -C "$seed" commit -qm "origin bytecode"
  git -C "$seed" push -q "$REMOTES_DIR/alpha.git" main
  printf 'v2-local\n' >alpha/__pycache__/x.pyc

  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "auto-resolved"
  assert_contains "$output" "__pycache__/x.pyc"
  assert_not_contains "$output" "Stash conflicts"
}

@test "a manifest that stays different from origin says which fields differ" {
  meta_workspace
  # A real semantic difference that reconciliation legitimately keeps: this
  # machine sleeps a repo the other one does not.
  mcrepo sleep beta >/dev/null
  device_b_meta sh -c 'printf "device B note\n" > notes.txt'

  run mcrepo pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "differs from origin in:"
  assert_contains "$output" "mode of 'beta'"
  assert_contains "$output" "sleep"
}
