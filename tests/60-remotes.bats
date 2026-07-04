#!/usr/bin/env bats
# Named remote locations: workspace-declared location names ('locations:'),
# per-repo URLs ('remotes: name=url,...'), the 'mcrepo remote' management
# command, and 'mcrepo pull/push <location>'.

load helpers

setup() {
  setup_workspace
}

# Declare a 'backup' location and give alpha a second bare remote for it.
setup_backup_location() {
  init_workspace_with_repos alpha
  mcrepo write alpha >/dev/null
  BACKUP_BARE="$REMOTES_DIR/alpha-backup.git"
  git init -q --bare "$BACKUP_BARE"
  run mcrepo remote add backup
  [ "$status" -eq 0 ]
  run mcrepo remote set alpha backup "file://$BACKUP_BARE"
  [ "$status" -eq 0 ]
}

@test "remote add/set/list manage locations; manifest round-trips them" {
  setup_backup_location
  run mcrepo remote list
  [ "$status" -eq 0 ]
  assert_contains "$output" "Locations: backup"
  assert_contains "$output" "alpha: backup=file://"
  grep -q '^locations: backup$' mcrepo.yaml
  grep -q 'remotes: backup=file://' mcrepo.yaml
  # round-trip: a state-changing command must preserve the fields
  run mcrepo read alpha
  grep -q '^locations: backup$' mcrepo.yaml
  grep -q 'remotes: backup=file://' mcrepo.yaml
}

@test "remote add rejects reserved and invalid names; unknown locations die with a hint" {
  init_workspace_with_repos alpha
  run mcrepo remote add origin
  [ "$status" -eq 1 ]
  run mcrepo remote add "Bad Name"
  [ "$status" -eq 1 ]
  run mcrepo push nosuch
  [ "$status" -eq 1 ]
  assert_contains "$output" "Unknown location"
  assert_contains "$output" "mcrepo remote add"
}

@test "push <location> publishes write repos; repos without a URL are skipped" {
  setup_backup_location
  url2="$(make_remote beta)"
  mcrepo add "$url2" beta >/dev/null
  mcrepo write beta >/dev/null

  printf 'work\n' >>alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "alpha work"

  run mcrepo push backup
  [ "$status" -eq 0 ]
  assert_contains "$output" "Pushed:  alpha"
  assert_contains "$output" "beta (no backup URL)"
  run git --git-dir="$BACKUP_BARE" log --format=%s main
  assert_contains "$output" "alpha work"
}

@test "pull <location> integrates new commits from the location (rebase on top)" {
  setup_backup_location
  git -C alpha push -q backup main

  # Another device pushes to the backup location; we also have local work.
  b_clone="$BATS_TEST_TMPDIR/backup-clone"
  git clone -q "$BACKUP_BARE" "$b_clone"
  printf 'from backup device\n' >"$b_clone/backup.txt"
  git -C "$b_clone" add -A
  git -C "$b_clone" commit -qm "backup device work"
  git -C "$b_clone" push -q origin main

  printf 'local work\n' >alpha/local.txt
  git -C alpha add -A
  git -C alpha commit -qm "local work"

  run mcrepo pull backup
  [ "$status" -eq 0 ]
  run git -C alpha log --format=%s
  assert_contains "$output" "backup device work"
  assert_contains "$output" "local work"
}

@test "pull <location> never rebases onto a stale mirror — routes to push" {
  setup_backup_location
  git -C alpha push -q backup main
  # local advances; backup is now a strictly stale mirror
  printf 'newer\n' >>alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "newer local"

  run mcrepo pull backup
  [ "$status" -eq 0 ]
  assert_contains "$output" "Ahead of 'backup'"
  run mcrepo push backup
  [ "$status" -eq 0 ]
  run git --git-dir="$BACKUP_BARE" log --format=%s main
  assert_contains "$output" "newer local"
}

@test "push <location> refuses when the location has commits you lack (never forced)" {
  setup_backup_location
  git -C alpha push -q backup main
  b_clone="$BATS_TEST_TMPDIR/backup-clone2"
  git clone -q "$BACKUP_BARE" "$b_clone"
  printf 'only on backup\n' >"$b_clone/b.txt"
  git -C "$b_clone" add -A
  git -C "$b_clone" commit -qm "backup only"
  git -C "$b_clone" push -q origin main
  # local diverges
  printf 'local div\n' >>alpha/README.md
  git -C alpha add -A
  git -C alpha commit -qm "local divergent"

  run mcrepo push backup
  [ "$status" -eq 2 ]
  assert_contains "$output" "pull backup"
  run git --git-dir="$BACKUP_BARE" log --format=%s main
  assert_contains "$output" "backup only"
}

@test "remote remove clears the location from workspace, repos, and clones" {
  setup_backup_location
  MCREPO_ASSUME_YES=1 run mcrepo remote remove backup
  [ "$status" -eq 0 ]
  ! grep -q '^locations:' mcrepo.yaml
  ! grep -q 'remotes:' mcrepo.yaml
  run git -C alpha remote
  assert_not_contains "$output" "backup"
}
