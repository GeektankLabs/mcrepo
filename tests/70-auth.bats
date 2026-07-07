#!/usr/bin/env bats
# Credential-prompt hygiene: pull must hit the network exactly once per repo
# (the local fast-forward keeps a second prompt from ever appearing), doctor
# must flag HTTPS hosts with no credential helper, and a failed fetch on such
# a host must point at the fix.

load helpers

setup() {
  setup_workspace
}

# Install a git shim ahead of PATH that logs every top-level git invocation.
# Sets GIT_SHIM_PATH (prepend to PATH) and GIT_SHIM_LOG (the log file).
install_git_shim() {
  GIT_SHIM_PATH="$BATS_TEST_TMPDIR/bin"
  GIT_SHIM_LOG="$BATS_TEST_TMPDIR/git-log"
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$GIT_SHIM_PATH"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >>"%s"\n' "$GIT_SHIM_LOG"
    printf 'exec "%s" "$@"\n' "$real_git"
  } >"$GIT_SHIM_PATH/git"
  chmod +x "$GIT_SHIM_PATH/git"
}

write_https_manifest() {
  cat >mcrepo.yaml <<'EOF'
schema: 1
repos:
  - url: https://github.com/example/private-thing.git
    name: private-thing
    mode: read
    description: ""
    localpath: private-thing
EOF
}

@test "pull hits the network exactly once per repo (fast-forward is local)" {
  init_workspace_with_repos alpha
  advance_remote alpha "remote advance alpha"

  install_git_shim
  run env PATH="$GIT_SHIM_PATH:$PATH" "$SANDBOX/mcrepo.sh" pull
  [ "$status" -eq 0 ]
  assert_contains "$output" "✓ Pull complete"

  run grep -c ' fetch ' "$GIT_SHIM_LOG"
  [ "$output" = "1" ]
  run grep ' pull' "$GIT_SHIM_LOG"
  [ "$status" -ne 0 ]

  run cat alpha/README.md
  assert_contains "$output" "remote advance alpha"
}

@test "branch tracking a non-origin remote falls back to a real pull" {
  init_workspace_with_repos alpha
  # Mirror alpha's history into a second remote and track THAT: the pull-loop
  # fetch only refreshes origin, so the ff must stay a real 'git pull'.
  git init -q --bare "$REMOTES_DIR/mirror.git"
  git -C alpha push -q "file://$REMOTES_DIR/mirror.git" main
  git -C alpha remote add mirror "file://$REMOTES_DIR/mirror.git"
  git -C alpha fetch -q mirror
  git -C alpha branch -q --set-upstream-to=mirror/main main

  install_git_shim
  run env PATH="$GIT_SHIM_PATH:$PATH" "$SANDBOX/mcrepo.sh" pull
  [ "$status" -eq 0 ]

  run grep ' pull --ff-only' "$GIT_SHIM_LOG"
  [ "$status" -eq 0 ]
}

@test "doctor warns when an HTTPS host has no credential helper" {
  mcrepo init --no-shell-install >/dev/null
  write_https_manifest

  run mcrepo doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "no credential helper for github.com"
  assert_contains "$output" "private HTTPS repos prompt for credentials on every fetch"
}

@test "doctor reports a configured credential helper and stays quiet" {
  mcrepo init --no-shell-install >/dev/null
  write_https_manifest
  git config --file "$GIT_CONFIG_GLOBAL" credential.helper store

  run mcrepo doctor
  [ "$status" -eq 0 ]
  assert_contains "$output" "auth: credential helper for github.com: store"
  assert_not_contains "$output" "no credential helper"
}

@test "failed fetch on an HTTPS remote without helper prints the doctor hint once" {
  init_workspace_with_repos alpha bravo
  git -C alpha remote set-url origin "https://127.0.0.1:1/nope/alpha.git"
  git -C bravo remote set-url origin "https://127.0.0.1:1/nope/bravo.git"

  run env GIT_TERMINAL_PROMPT=0 "$SANDBOX/mcrepo.sh" pull
  [ "$status" -ne 0 ]
  assert_contains "$output" "Fetch failed for 'alpha'"
  assert_contains "$output" "Fetch failed for 'bravo'"
  assert_contains "$output" "hint: repeated credential prompts?"
  # One-shot: the fix is global, the hint must not repeat per repo.
  [ "$(printf '%s\n' "$output" | grep -c 'hint: repeated credential prompts?')" -eq 1 ]
}

@test "failed fetch stays hint-free when a credential helper is configured" {
  init_workspace_with_repos alpha
  git -C alpha remote set-url origin "https://127.0.0.1:1/nope/alpha.git"
  git config --file "$GIT_CONFIG_GLOBAL" credential.helper store

  run env GIT_TERMINAL_PROMPT=0 "$SANDBOX/mcrepo.sh" pull
  [ "$status" -ne 0 ]
  assert_contains "$output" "Fetch failed for 'alpha'"
  assert_not_contains "$output" "hint: repeated credential prompts?"
}
