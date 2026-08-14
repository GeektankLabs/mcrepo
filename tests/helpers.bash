# Shared helpers for the mcrepo bats suite.
#
# Every test runs in a disposable sandbox with an isolated HOME and isolated
# git config, uses local file:// bare remotes (no network, no GitHub), and
# suppresses banner/update-check/VS Code side effects.

setup_workspace() {
  MCREPO_SRC="$BATS_TEST_DIRNAME/../mcrepo.sh"
  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  REMOTES_DIR="$BATS_TEST_TMPDIR/remotes"

  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$SANDBOX" "$HOME" "$REMOTES_DIR"

  cp "$MCREPO_SRC" "$SANDBOX/mcrepo.sh"
  chmod +x "$SANDBOX/mcrepo.sh"

  export MCREPO_SUPPRESS_VERSION_BANNER=1
  export MCREPO_DISABLE_UPDATE_CHECK=1
  export MCREPO_NO_SHELL_INSTALL=1
  export MCREPO_SKIP_VSCODE=1

  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" user.email "tests@mcrepo.invalid"
  git config --file "$GIT_CONFIG_GLOBAL" user.name "mcrepo tests"
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always
  # 'git rebase/merge --continue' must not block on an editor in tests.
  git config --file "$GIT_CONFIG_GLOBAL" core.editor true

  cd "$SANDBOX" || return 1
}

mcrepo() {
  "$SANDBOX/mcrepo.sh" "$@"
}

# Create a bare remote seeded with one commit on main.
# Prints its file:// URL.
make_remote() {
  local name="$1"
  local seed="$BATS_TEST_TMPDIR/seed-$name"
  local bare="$REMOTES_DIR/$name.git"
  git init -q -b main "$seed"
  printf 'hello %s\n' "$name" >"$seed/README.md"
  git -C "$seed" add -A
  git -C "$seed" commit -qm "seed $name"
  git init -q --bare "$bare"
  git -C "$seed" push -q "$bare" main
  printf 'file://%s\n' "$bare"
}

# Initialize the sandbox as a git-managed mcrepo workspace with N added repos.
# Usage: init_workspace_with_repos repo-a repo-b ...
init_workspace_with_repos() {
  mcrepo init --no-shell-install >/dev/null
  local name url
  for name in "$@"; do
    url="$(make_remote "$name")"
    mcrepo add "$url" "$name" >/dev/null
  done
}

# Make the sandbox workspace itself git-managed (meta-context participates).
git_manage_workspace() {
  git init -q -b main .
  git add -A
  git commit -qm "workspace initial commit"
}

# Give the meta-context itself a bare origin and push the current state to it.
# Call after git_manage_workspace + whatever repos the test needs.
make_meta_remote() {
  git init -q --bare "$REMOTES_DIR/meta.git"
  git add -A
  git commit -qm "workspace state before meta remote" >/dev/null 2>&1 || true
  git remote add origin "file://$REMOTES_DIR/meta.git"
  git push -q -u origin main
}

# Act as the SECOND machine: clone the meta origin once, run a callback inside
# that clone, then commit and push. Used to produce manifest edits that arrive
# via 'mcrepo pull' without the local sandbox ever seeing them.
device_b_meta() {
  local clone="$BATS_TEST_TMPDIR/device-b-meta"
  [ -d "$clone" ] || git clone -q "$REMOTES_DIR/meta.git" "$clone"
  ( cd "$clone" && "$@" && rm -f ./*.bak && git add -A && \
    git commit -qm "device B manifest change" && git push -q origin main )
}

# Source mcrepo.sh's function definitions without running main(), for unit
# tests of individual helpers. The script ends with 'main "$@"' + exit guard.
source_mcrepo_lib() {
  local lib="$BATS_TEST_TMPDIR/mcrepo-lib.sh"
  sed '/^main "\$@"$/,$d' "$SANDBOX/mcrepo.sh" >"$lib"
  # shellcheck disable=SC1090  # generated path, resolved at runtime
  . "$lib"
}

# Advance a repo's remote main by committing new README.md content via the
# seed clone. Overwrites line 1, so a differing local edit to README.md
# produces a REAL merge/rebase conflict.
advance_remote() {
  local name="$1" content="$2"
  local seed="$BATS_TEST_TMPDIR/seed-$name"
  printf '%s\n' "$content" >"$seed/README.md"
  git -C "$seed" add -A
  git -C "$seed" commit -qm "remote advance $name"
  git -C "$seed" push -q "$REMOTES_DIR/$name.git" main
}

# Append a line to a file in a repo and stage nothing (dirty working tree).
dirty_repo() {
  local repo="$1"
  printf 'change %s\n' "$(date +%s)" >>"$SANDBOX/$repo/README.md"
}

# Current branch of a repo folder.
repo_branch() {
  git -C "$SANDBOX/$1" rev-parse --abbrev-ref HEAD
}

# Latest commit subject of a repo folder.
repo_subject() {
  git -C "$SANDBOX/$1" log -1 --format=%s
}

# Assert helper: fail with readable output.
assert_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'expected to find: %s\n---- in ----\n%s\n' "$needle" "$haystack" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'expected NOT to find: %s\n---- in ----\n%s\n' "$needle" "$haystack" >&2
    return 1
  fi
}
