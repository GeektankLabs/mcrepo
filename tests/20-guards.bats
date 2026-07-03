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
