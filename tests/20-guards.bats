#!/usr/bin/env bats
# Regression tests for data-loss and crash fixes.

load helpers

setup() {
  setup_workspace
}

@test "branch --dirty carry works when a repo is dirty only via untracked files (target_ref crash)" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  echo "untracked-only" >alpha/new-file.txt
  run mcrepo branch feature-y --dirty carry
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "unbound variable"
  [ "$(repo_branch alpha)" = "feature-y" ]
  [ -f alpha/new-file.txt ]
}

@test "branch rejects unknown flags instead of treating them as branch names" {
  init_workspace_with_repos alpha
  run mcrepo branch --delte
  [ "$status" -ne 0 ]
  assert_contains "$output" "Unknown branch option"
  # must fail fast: no fetch/fork flow for a typo
  assert_not_contains "$output" "fork"
}

@test "branch accepts flags before the branch name" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  run mcrepo branch --dirty abort feature-z
  [ "$status" -eq 0 ]
  [ "$(repo_branch alpha)" = "feature-z" ]
}

@test "mcrepo.yaml round-trip preserves descriptions with quotes and backslashes" {
  init_workspace_with_repos alpha
  desc='He said "hi" and C:\path\stuff'
  python3 - <<PYEOF
import re
with open("mcrepo.yaml") as f:
    text = f.read()
escaped = 'He said \\\\"hi\\\\" and C:\\\\\\\\path\\\\\\\\stuff'
text = text.replace('description: ""', 'description: "%s"' % escaped, 1)
with open("mcrepo.yaml", "w") as f:
    f.write(text)
PYEOF
  before="$(cat mcrepo.yaml)"
  # each mode switch does a load+save round-trip
  mcrepo write alpha >/dev/null
  mcrepo read alpha >/dev/null
  mcrepo write alpha >/dev/null
  mcrepo read alpha >/dev/null
  after="$(cat mcrepo.yaml)"
  [ "$before" = "$after" ]
}

@test "JSONC in .vscode/settings.json is left untouched instead of being wiped" {
  init_workspace_with_repos alpha
  cat >.vscode/settings.json <<'EOF'
{
  // my important comment
  "editor.fontSize": 14,
}
EOF
  run mcrepo read alpha
  [ "$status" -eq 0 ]
  grep -q "my important comment" .vscode/settings.json
  grep -q "editor.fontSize" .vscode/settings.json
}

@test "save_repos leaves no temp files behind" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  run bash -c 'ls mcrepo.yaml.tmp.* 2>/dev/null'
  [ -z "$output" ]
}

@test "sleep refuses to destroy unpushed commits without --force (non-TTY)" {
  init_workspace_with_repos alpha
  echo "local work" >>alpha/README.md
  git -C "$SANDBOX/alpha" add -A
  git -C "$SANDBOX/alpha" commit -qm "unpushed work"
  run mcrepo sleep alpha
  [ "$status" -ne 0 ]
  assert_contains "$output" "unpushed commits"
  [ -d alpha/.git ]

  run mcrepo sleep alpha --force
  [ "$status" -eq 0 ]
  [ -f alpha/.mcrepo-sleep ]
}

@test "sleep also guards read-mode repos with local edits" {
  init_workspace_with_repos alpha
  echo "read-mode edit" >>alpha/README.md
  run mcrepo sleep alpha
  [ "$status" -ne 0 ]
  assert_contains "$output" "uncommitted changes"
  [ -d alpha/.git ]
}

@test "pull --reset preserves committed work on a diverged repo non-interactively; --yes discards" {
  init_workspace_with_repos alpha
  # diverge: local commit + different remote commit
  echo "local commit" >>alpha/README.md
  git -C "$SANDBOX/alpha" add -A
  git -C "$SANDBOX/alpha" commit -qm "local only"
  local_sha="$(git -C "$SANDBOX/alpha" rev-parse HEAD)"
  seed="$BATS_TEST_TMPDIR/seed-alpha"
  echo "remote commit" >>"$seed/other.txt"
  git -C "$seed" add -A
  git -C "$seed" commit -qm "remote advance"
  git -C "$seed" push -q "$REMOTES_DIR/alpha.git" main

  run mcrepo pull --reset
  [ "$status" -eq 0 ]
  assert_contains "$output" "Reset declined (local commits preserved)"
  [ "$(git -C "$SANDBOX/alpha" rev-parse HEAD)" = "$local_sha" ]

  run mcrepo pull --reset --yes
  [ "$status" -eq 0 ]
  [ "$(git -C "$SANDBOX/alpha" rev-parse HEAD)" != "$local_sha" ]
  [ "$(repo_subject alpha)" = "remote advance" ]
}

@test "add rejects remote-helper transport URLs from the manifest attack surface" {
  mcrepo init --no-shell-install >/dev/null
  run mcrepo add "ext::sh -c whoami" evil
  [ "$status" -ne 0 ]
  assert_contains "$output" "Unsupported or unsafe"
  run mcrepo list
  assert_not_contains "$output" "evil"
}

@test "branch rejects invalid branch names" {
  init_workspace_with_repos alpha
  run mcrepo branch "bad..name"
  [ "$status" -ne 0 ]
  assert_contains "$output" "Invalid branch name"
}

@test "status shows a stash indicator" {
  init_workspace_with_repos alpha
  echo "stash me" >>alpha/README.md
  git -C "$SANDBOX/alpha" stash push -q -m "test stash"
  run mcrepo status
  [ "$status" -eq 0 ]
  assert_contains "$output" "stash=1"
}

@test "version banner goes to stderr, not stdout" {
  init_workspace_with_repos alpha
  stdout_only="$(MCREPO_SUPPRESS_VERSION_BANNER=0 "$SANDBOX/mcrepo.sh" list 2>/dev/null)"
  assert_not_contains "$stdout_only" "mcrepo version"
  stderr_only="$(MCREPO_SUPPRESS_VERSION_BANNER=0 "$SANDBOX/mcrepo.sh" list 2>&1 >/dev/null)"
  assert_contains "$stderr_only" "mcrepo version"
}

@test "mcrepo version prints the version to stdout without banner noise" {
  mcrepo init --no-shell-install >/dev/null
  out="$(MCREPO_SUPPRESS_VERSION_BANNER=0 "$SANDBOX/mcrepo.sh" version 2>/dev/null)"
  [[ "$out" == "mcrepo version "* ]]
  [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ]
}

@test "commit --reset non-interactively requires --force and preserves changes" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  echo "dirty" >>alpha/README.md
  # non-TTY: commit --reset without --force must die (exit 1), not proceed
  run mcrepo commit --reset
  [ "$status" -eq 1 ]
  assert_contains "$output" "requires --force"
  grep -q "dirty" alpha/README.md

  run mcrepo commit --reset --force
  [ "$status" -eq 0 ]
  ! grep -q "dirty" alpha/README.md
}

# --- Rebase provenance safety -------------------------------------------
#
# Provenance lets a conflict-resolved rebase be force-published. These guard
# the boundary: it must never authorize a push once the remote has moved, and
# it must not survive a rewrite mcrepo did not perform.

@test "provenance never force-publishes over work pushed after the rebase" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-prov >/dev/null 2>&1
  printf 'feature line\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "feature work"
  git -C alpha push -q -u origin feat-prov
  advance_remote alpha "parent moved"

  run mcrepo rebase
  [ "$status" -eq 2 ]
  printf 'parent moved\nfeature line\n' >alpha/README.md
  git -C alpha add README.md
  run mcrepo rebase
  [ "$status" -eq 0 ]

  # Another device publishes onto the now-stale remote branch AFTER the rebase.
  b_clone="$BATS_TEST_TMPDIR/device-b-prov"
  git clone -q -b feat-prov "$REMOTES_DIR/alpha.git" "$b_clone"
  printf 'device B work\n' >"$b_clone/b.txt"
  git -C "$b_clone" add -A
  git -C "$b_clone" commit -qm "device B new work"
  git -C "$b_clone" push -q origin feat-prov
  b_tip="$(git -C "$b_clone" rev-parse HEAD)"

  # The record no longer matches the remote, so it proves nothing.
  run mcrepo push
  [ "$status" -ne 0 ]
  git -C alpha fetch -q origin
  [ "$(git -C alpha rev-parse origin/feat-prov)" = "$b_tip" ]
  run git -C alpha log --format=%s origin/feat-prov
  assert_contains "$output" "device B new work"
}

@test "a rewrite mcrepo did not perform invalidates the record" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-inv >/dev/null 2>&1
  printf 'feature line\n' >alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "feature work"
  git -C alpha push -q -u origin feat-inv
  advance_remote alpha "parent moved"

  run mcrepo rebase
  [ "$status" -eq 2 ]
  printf 'parent moved\nfeature line\n' >alpha/README.md
  git -C alpha add README.md
  run mcrepo rebase
  [ "$status" -eq 0 ]

  # The user rewrites history again by hand: HEAD no longer descends from the
  # tip the rebase produced, so the record must stop authorizing a force-push.
  git -C alpha reset -q --hard HEAD~1
  printf 'hand written\n' >alpha/hand.txt
  git -C alpha add -A
  git -C alpha commit -qm "hand-rolled rewrite"

  run mcrepo push
  [ "$status" -ne 0 ]
  assert_not_contains "$output" "force-push]"
}

@test "rebase refuses to strand commits the remote has and the branch lacks" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-unpulled >/dev/null 2>&1
  printf 'feature line\n' >alpha/f.txt
  git -C alpha add -A
  git -C alpha commit -qm "feature work"
  git -C alpha push -q -u origin feat-unpulled

  # Another device adds work to the shared feature branch; we never pulled it.
  b_clone="$BATS_TEST_TMPDIR/device-b-unpulled"
  git clone -q -b feat-unpulled "$REMOTES_DIR/alpha.git" "$b_clone"
  printf 'device B work\n' >"$b_clone/b.txt"
  git -C "$b_clone" add -A
  git -C "$b_clone" commit -qm "device B new work"
  git -C "$b_clone" push -q origin feat-unpulled
  b_tip="$(git -C "$b_clone" rev-parse HEAD)"
  advance_remote alpha "parent moved"

  run mcrepo rebase
  [ "$status" -eq 2 ]
  assert_contains "$output" "mcrepo pull"
  git -C alpha fetch -q origin
  [ "$(git -C alpha rev-parse origin/feat-unpulled)" = "$b_tip" ]
}

@test "force-publishing always carries an explicit lease and never a plain --force" {
  # Invariant over the source itself: a bare '--force' (or '-f') push would
  # silently discard whatever is on the remote.
  ! grep -nE 'git [^|]*push[^|]*--force([^-=]|$)' "$SANDBOX/mcrepo.sh"
  ! grep -nE 'git [^|]*push +-f( |$)' "$SANDBOX/mcrepo.sh"
  grep -q 'force-with-lease=' "$SANDBOX/mcrepo.sh"
}

# --- Workspace hygiene ---------------------------------------------------

@test "coordinated commit leaves generated artifacts out and names them" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mkdir -p "alpha/+-tests/artifacts/run-1" alpha/pkg/__pycache__
  printf 'report\n' >"alpha/+-tests/artifacts/run-1/report.json"
  printf 'bytes\n' >alpha/pkg/__pycache__/mod.cpython-311.pyc
  printf 'real source\n' >alpha/src.txt

  run mcrepo commit -m "real work"
  [ "$status" -eq 0 ]
  assert_contains "$output" "leaving out"
  assert_contains "$output" "artifacts/run-1/report.json"

  run git -C alpha ls-files
  assert_contains "$output" "src.txt"
  assert_not_contains "$output" "artifacts/run-1/report.json"
  assert_not_contains "$output" "mod.cpython-311.pyc"
  # The files themselves must survive on disk — this is a staging policy,
  # not a delete.
  [ -f "alpha/+-tests/artifacts/run-1/report.json" ]
}

@test "--include-artifacts commits the generated paths on purpose" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mkdir -p "alpha/+-tests/artifacts/run-1"
  printf 'evidence\n' >"alpha/+-tests/artifacts/run-1/report.json"

  run mcrepo commit -m "release evidence" --include-artifacts
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "leaving out"
  run git -C alpha ls-files
  assert_contains "$output" "artifacts/run-1/report.json"
}

@test "ordinary source changes are untouched by the artifact guard" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  printf 'plain change\n' >>alpha/README.md
  printf 'new file\n' >alpha/added.txt

  run mcrepo commit -m "normal work"
  [ "$status" -eq 0 ]
  assert_not_contains "$output" "leaving out"
  run git -C alpha ls-files
  assert_contains "$output" "added.txt"
}

@test "doctor reports tracked generated artifacts and stays quiet when clean" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  run mcrepo doctor
  assert_contains "$output" "no generated artifacts tracked"

  # Force them into history the way a pre-guard workspace would have.
  mkdir -p "alpha/+-tests/artifacts/run-1"
  printf 'report\n' >"alpha/+-tests/artifacts/run-1/report.json"
  git -C alpha add -A -f
  git -C alpha commit -qm "legacy artifact commit"

  run mcrepo doctor
  assert_contains "$output" "tracks 1 generated file"
  assert_contains "$output" "rm -r --cached"
}

@test "rebase auto-resolves generated-artifact conflicts without a stop" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  # Ignore rule must exist in the repo — that is the second half of the proof.
  printf '+-tests/artifacts/\n' >alpha/.gitignore
  mkdir -p "alpha/+-tests/artifacts/run-1"
  printf 'from main\n' >"alpha/+-tests/artifacts/run-1/report.json"
  git -C alpha add -A -f
  git -C alpha commit -qm "baseline artifact on main"
  git -C alpha push -q origin main

  mcrepo branch feat-art >/dev/null 2>&1
  printf 'from feature\n' >"alpha/+-tests/artifacts/run-1/report.json"
  git -C alpha add -A -f
  git -C alpha commit -qm "feature rewrites the artifact"

  # main rewrites the SAME artifact line: a real conflict with no decision in it.
  seed="$BATS_TEST_TMPDIR/seed-alpha"
  git -C "$seed" pull -q --no-rebase "$REMOTES_DIR/alpha.git" main
  printf 'from main again\n' >"$seed/+-tests/artifacts/run-1/report.json"
  git -C "$seed" add -A -f
  git -C "$seed" commit -qm "main rewrites the artifact"
  git -C "$seed" push -q "$REMOTES_DIR/alpha.git" main

  run mcrepo rebase
  [ "$status" -eq 0 ]
  assert_contains "$output" "auto-resolved"
  assert_contains "$output" "✓ Rebase complete"
  [ -z "$(git -C alpha ls-files -u)" ]
}

@test "auto-clean never touches a conflict the workspace does not call generated" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  # Same path shape, but NO ignore rule: this repo versions its evidence.
  mkdir -p "alpha/+-tests/artifacts/run-1"
  printf 'from main\n' >"alpha/+-tests/artifacts/run-1/report.json"
  git -C alpha add -A -f
  git -C alpha commit -qm "baseline artifact on main"
  git -C alpha push -q origin main

  mcrepo branch feat-keep >/dev/null 2>&1
  printf 'from feature\n' >"alpha/+-tests/artifacts/run-1/report.json"
  git -C alpha add -A -f
  git -C alpha commit -qm "feature rewrites the artifact"

  seed="$BATS_TEST_TMPDIR/seed-alpha"
  git -C "$seed" pull -q --no-rebase "$REMOTES_DIR/alpha.git" main
  printf 'from main again\n' >"$seed/+-tests/artifacts/run-1/report.json"
  git -C "$seed" add -A -f
  git -C "$seed" commit -qm "main rewrites the artifact"
  git -C "$seed" push -q "$REMOTES_DIR/alpha.git" main

  run mcrepo rebase
  [ "$status" -eq 2 ]
  assert_not_contains "$output" "auto-resolved"
  assert_contains "$output" "Rebase conflicts"
  [ -n "$(git -C alpha ls-files -u)" ]
}

@test "--approve-rebased publishes an unprovable rewrite, but only under a pinned lease" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  mcrepo branch feat-appr >/dev/null 2>&1
  printf 'feature work\n' >alpha/f.txt
  git -C alpha add -A
  git -C alpha commit -qm "feature work"
  git -C alpha push -q -u origin feat-appr
  advance_remote alpha "parent moved"
  run mcrepo rebase
  [ "$status" -eq 0 ]

  # Device B stacks work on the stale remote, so nothing can prove safety.
  b_clone="$BATS_TEST_TMPDIR/device-b-appr"
  git clone -q -b feat-appr "$REMOTES_DIR/alpha.git" "$b_clone"
  printf 'device B\n' >"$b_clone/b.txt"
  git -C "$b_clone" add -A
  git -C "$b_clone" commit -qm "device B new work"
  git -C "$b_clone" push -q origin feat-appr

  # Unapproved: refused, and the refusal advertises the override.
  run mcrepo push
  [ "$status" -ne 0 ]
  assert_contains "$output" "--approve-rebased"

  # Approved: published, and the report states what is being dropped.
  local_tip="$(git -C alpha rev-parse HEAD)"
  run mcrepo push --approve-rebased alpha
  [ "$status" -eq 0 ]
  assert_contains "$output" "approved for force-publishing"
  assert_contains "$output" "will be dropped"
  git -C alpha fetch -q origin
  [ "$(git -C alpha rev-parse origin/feat-appr)" = "$local_tip" ]
}

@test "--approve-rebased refuses to combine with flags that would weaken it" {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  run mcrepo push --approve-rebased alpha --no-force
  [ "$status" -ne 0 ]
  assert_contains "$output" "contradict"
  run mcrepo push --approve-rebased alpha --no-fetch
  [ "$status" -ne 0 ]
  assert_contains "$output" "fresh fetch"
  run mcrepo push --approve-rebased
  [ "$status" -ne 0 ]
  assert_contains "$output" "requires repo names"
}

@test "save_repos/load_repos round-trip through an explicit file path" {
  init_workspace_with_repos alpha
  source_mcrepo_lib
  desc='He said "hi" and C:\path\stuff'
  load_repos
  REPO_DESCRIPTIONS[0]="$desc"
  save_repos "$BATS_TEST_TMPDIR/out.yaml"
  [ -f "$BATS_TEST_TMPDIR/out.yaml" ]
  load_repos "$BATS_TEST_TMPDIR/out.yaml"
  [ "${REPO_DESCRIPTIONS[0]}" = "$desc" ]
  [ "${REPO_NAMES[0]}" = "alpha" ]
  # Reading a file that does not exist fails instead of silently using defaults.
  run load_repos "$BATS_TEST_TMPDIR/missing.yaml"
  [ "$status" -ne 0 ]
}

@test "save_repos leaves the manifest untouched when nothing changed" {
  init_workspace_with_repos alpha
  local before after
  before="$(git hash-object mcrepo.yaml 2>/dev/null || md5 -q mcrepo.yaml)"
  # A mode switch that changes nothing still does a full load+save round-trip.
  mcrepo read alpha >/dev/null
  mcrepo read alpha >/dev/null
  after="$(git hash-object mcrepo.yaml 2>/dev/null || md5 -q mcrepo.yaml)"
  [ "$before" = "$after" ]
}
