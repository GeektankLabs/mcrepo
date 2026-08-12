#!/usr/bin/env bats
# The command surface is defined once in MCREPO_COMMANDS. usage(), the main()
# dispatch, and the generated completions must all agree with it.

load helpers

setup() {
  setup_workspace
}

inventory() {
  grep '^MCREPO_COMMANDS=' "$SANDBOX/mcrepo.sh" | cut -d'"' -f2
}

@test "every inventory command has a usage() line" {
  help_out="$(mcrepo help)"
  for cmd in $(inventory); do
    printf '%s\n' "$help_out" | grep -q "mcrepo\.sh $cmd\b" || {
      echo "command missing from usage(): $cmd" >&2
      return 1
    }
  done
}

@test "every inventory command has a dispatch case in main()" {
  dispatch="$(awk '/^  case "\$cmd" in$/,/^  esac$/' "$SANDBOX/mcrepo.sh")"
  for cmd in $(inventory); do
    printf '%s\n' "$dispatch" | grep -qE "^    ([a-z|-]+\|)*$cmd(\|[^)]*)?\)" || {
      echo "command missing from dispatch: $cmd" >&2
      return 1
    }
  done
}

@test "generated completions carry the full inventory" {
  mcrepo init --no-shell-install >/dev/null
  for cmd in $(inventory); do
    grep -q "$cmd" .mcrepo-completion.bash || {
      echo "missing in bash completion: $cmd" >&2
      return 1
    }
    grep -q "$cmd" .mcrepo-completion.zsh || {
      echo "missing in zsh completion: $cmd" >&2
      return 1
    }
  done
  # no placeholder left behind
  ! grep -q "__MCREPO_COMMANDS__" .mcrepo-completion.bash
  ! grep -q "__MCREPO_COMMANDS__" .mcrepo-completion.zsh
}

@test "manifest gets a schema stamp and older manifests load fine" {
  mcrepo init --no-shell-install >/dev/null
  grep -q '^schema: 2$' mcrepo.yaml
  # simulate a 0.5.x manifest without schema line
  grep -v '^schema:' mcrepo.yaml >mcrepo.yaml.old && mv mcrepo.yaml.old mcrepo.yaml
  run mcrepo list
  [ "$status" -eq 0 ]
}

@test "manifest from a newer schema is rejected with an update hint" {
  mcrepo init --no-shell-install >/dev/null
  python3 - <<'PYEOF'
text = open("mcrepo.yaml").read().replace("schema: 2", "schema: 99")
open("mcrepo.yaml", "w").write(text)
PYEOF
  run mcrepo list
  [ "$status" -ne 0 ]
  assert_contains "$output" "mcrepo update"
}

@test "removed legacy aliases are gone: 'off' command and 'branch off'" {
  init_workspace_with_repos alpha
  run mcrepo off alpha
  [ "$status" -ne 0 ]
  run mcrepo branch off
  [ "$status" -ne 0 ]
}

@test "create-patch is canonical; export-patch warns but still works" {
  mcrepo init --no-shell-install >/dev/null
  run mcrepo export-patch --strategy legacy topic-x
  assert_contains "$output" "Deprecation"
}
