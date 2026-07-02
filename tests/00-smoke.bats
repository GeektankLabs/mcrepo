#!/usr/bin/env bats
# Smoke tests: init, add, list, status, mode switches.

load helpers

setup() {
  setup_workspace
}

@test "init creates base structure and manifest" {
  run mcrepo init --no-shell-install
  [ "$status" -eq 0 ]
  [ -f mcrepo.yaml ]
  [ -d "+-contracts" ]
  [ -d "+-docs" ]
  [ -d "+-tests" ]
  [ -d "+-skills" ]
  [ -f AGENTS.md ]
  [ -f .gitignore ]
}

@test "init is idempotent" {
  mcrepo init --no-shell-install >/dev/null
  run mcrepo init --no-shell-install
  [ "$status" -eq 0 ]
}

@test "add clones a file:// remote and records it in the manifest" {
  mcrepo init --no-shell-install >/dev/null
  url="$(make_remote alpha)"
  run mcrepo add "$url" alpha
  [ "$status" -eq 0 ]
  [ -d alpha/.git ]
  [ -f alpha/README.md ]
  grep -q 'name: alpha' mcrepo.yaml
  grep -q 'mode: read' mcrepo.yaml
}

@test "list shows the repo with mode and branch" {
  init_workspace_with_repos alpha
  run mcrepo list
  [ "$status" -eq 0 ]
  assert_contains "$output" "alpha"
  assert_contains "$output" "read"
}

@test "status reports clean state and branch" {
  init_workspace_with_repos alpha
  run mcrepo status
  [ "$status" -eq 0 ]
  assert_contains "$output" "alpha"
  assert_contains "$output" "clean"
}

@test "write/read switch modes in the manifest" {
  init_workspace_with_repos alpha
  run mcrepo write alpha
  [ "$status" -eq 0 ]
  grep -q 'mode: write' mcrepo.yaml

  run mcrepo read alpha
  [ "$status" -eq 0 ]
  grep -q 'mode: read' mcrepo.yaml
}

@test "sleep --force clears the folder and leaves placeholders; wakeall restores" {
  init_workspace_with_repos alpha
  run mcrepo sleep alpha --force
  [ "$status" -eq 0 ]
  [ -f alpha/.mcrepo-sleep ]
  [ ! -d alpha/.git ]
  grep -q 'mode: sleep' mcrepo.yaml

  run mcrepo sleep --wakeall
  [ "$status" -eq 0 ]
  [ -d alpha/.git ]
  grep -q 'mode: read' mcrepo.yaml
}

@test "remove --force deletes folder and manifest entry" {
  init_workspace_with_repos alpha
  run mcrepo remove alpha --force
  [ "$status" -eq 0 ]
  [ ! -d alpha ]
  ! grep -q 'name: alpha' mcrepo.yaml
}

@test "help exits 0 and lists core commands" {
  run mcrepo help
  [ "$status" -eq 0 ]
  assert_contains "$output" "init"
  assert_contains "$output" "commit"
  assert_contains "$output" "merge"
}

@test "unknown command exits non-zero" {
  run mcrepo definitely-not-a-command
  [ "$status" -ne 0 ]
}

@test "skill list and validate work on a fresh workspace" {
  mcrepo init --no-shell-install >/dev/null
  run mcrepo skill list
  [ "$status" -eq 0 ]
  run mcrepo skill validate
  [ "$status" -eq 0 ]
}
