#!/usr/bin/env bash
set -euo pipefail

MCREPO_VERSION="0.7.4"
# Manifest (mcrepo.yaml) format version. Bump when the manifest schema changes
# incompatibly; cmd_post_update_migrate migrates older manifests forward.
MCREPO_SCHEMA_VERSION="1"
MCREPO_UPDATE_REPO="GeektankLabs/mcrepo"
MCREPO_UPDATE_BRANCH="main"
MCREPO_UPDATE_SCRIPT_PATH="mcrepo.sh"
REPOS_FILE="mcrepo.yaml"
SUPPORT_CONTRACTS_DIR="+-contracts"
SUPPORT_DOCS_DIR="+-docs"
SUPPORT_TESTS_DIR="+-tests"
SUPPORT_SKILLS_DIR="+-skills"
SKILLS_CONFIG_FILE="$SUPPORT_SKILLS_DIR/skills.yaml"
OPENCODE_PROJECT_SKILLS_DIR=".opencode/skills"
# Single source of truth for the user-facing command surface. usage(), the
# dispatch in main(), and the generated completions must stay in sync with
# this list (checked by tests/30-inventory.bats).
MCREPO_COMMANDS="init publish-base add upstream fork doctor new publish remove write read sleep list branch rebase merge pr pull push commit continue abort resolve open status skill version update install-extension create-patch help"

COMPLETION_BASH_FILE=".mcrepo-completion.bash"
COMPLETION_ZSH_FILE=".mcrepo-completion.zsh"

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

# Run a command, capturing its stdout and prefixing each line with "  [name] ".
# Stderr is suppressed (matches the existing per-repo git fetch/pull behavior).
# Returns the wrapped command's exit status.
run_with_repo_prefix() {
  local rn="$1"
  shift
  local out rc=0
  out="$("$@" 2>/dev/null)" || rc=$?
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | awk -v rn="$rn" '{ printf("  [%s] %s\n", rn, $0) }'
  fi
  return "$rc"
}

supports_color() {
  [ -t 1 ] || return 1
  case "${TERM:-}" in
    ''|dumb) return 1 ;;
  esac
  return 0
}

log_yellow() {
  if supports_color; then
    printf '\033[33m%s\033[0m\n' "$*"
  else
    log "$*"
  fi
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:  # Show available mcrepo commands

═══════════════════════════════════════════════════════════════════════════════
  WORKSPACE SETUP
═══════════════════════════════════════════════════════════════════════════════
  ./mcrepo.sh init [organization] [--no-shell-install] # Initialize MC-Repo structure and optionally sync repos from a GitHub organization
  ./mcrepo.sh publish-base <git-url> [-m "msg"] [--force] # Git-manage this workspace (init if needed) and push to an empty remote; reconciles .gitignore before the first commit

═══════════════════════════════════════════════════════════════════════════════
  REPOSITORY MANAGEMENT
═══════════════════════════════════════════════════════════════════════════════
  ./mcrepo.sh add <git-url> [name] [opts]         # Add a repository (interactive when GitHub+gh: offers origin/fork/upstream/read-only)
                                                  #   opts: --as-origin|--as-upstream --upstream <url> --origin <url> --mode read|write --fork --no-clone --yes
  ./mcrepo.sh upstream [<repo> <url>|--off|--origin <url>]  # Show or set per-repo upstream (PR target) for the fork workflow
  ./mcrepo.sh fork <repo-name-or-url> [name]      # Fork a GitHub repo (gh): origin=your fork, upstream=original
  ./mcrepo.sh fork --all [--yes]                  # Fork+rewire every repo (incl. meta) where you lack push access (plan + confirm)
  ./mcrepo.sh doctor                              # Report git/gh/auth + per-repo origin/upstream/access; guidance for setup
  ./mcrepo.sh new <name> [-m "description"]       # Create a new LOCAL incubator sub-repo (files live committed in base mcrepo, no external remote yet)
  ./mcrepo.sh publish <name> <git-url> [-m "msg"] [--force] # Graduate a local incubator: untrack from base, init sub-repo .git, push initial commit to empty remote
  ./mcrepo.sh remove <name-or-url> [--keep-files] [--force] # Remove a repository: drops YAML entry and deletes local folder (after confirming uncommitted/unpushed work); --keep-files preserves folder, --force skips prompts
  ./mcrepo.sh write <repo-name>                   # Switch to write mode + align to global branch; checks push access (gh) and offers to fork if missing
  ./mcrepo.sh read <repo-name>                    # Switch a repository to read mode (read-only context)
  ./mcrepo.sh sleep <repo-name> [--force]         # Switch a repository to sleep mode and clear its local folder contents (local incubator repos: signal only, files preserved)
  ./mcrepo.sh sleep --wakeall                     # Wake all sleeping repositories and set them to read mode
  ./mcrepo.sh list                                # List configured repositories with mode, local clone state, and current branch

═══════════════════════════════════════════════════════════════════════════════
  COORDINATED GIT MANAGEMENT
  The loop:  branch → work → commit → rebase → merge → push
             (pull anytime to stay current · pr instead of push for reviews)
═══════════════════════════════════════════════════════════════════════════════
  ./mcrepo.sh branch <branch-name> [--include-read] [--dirty abort|commit|carry|discard]  # STEP 1 — one feature branch across write repos + meta-context (interactive dirty handling; --dirty preselects)
  ./mcrepo.sh commit [-m "msg"] [--include-read]     # STEP 2 — coordinated checkpoint across dirty write repos + meta-context (#N @batch, revertable as one unit; repeat freely)
  ./mcrepo.sh rebase [--include-read]                  # STEP 3 — rebase the branch onto each parent (auto-stash); resolve conflicts HERE, before merging
  ./mcrepo.sh merge [-m "subject"] [--include-read]  # STEP 4 — squash the branch back into each repo's parent; requires a rebased branch (run 'rebase' first)
  ./mcrepo.sh push [-m "message"] [--no-fetch] [--no-force] [--include-read] # STEP 5 — fetch + push write repos; safe force-with-lease for rebased branches; aborts if genuinely behind
  ./mcrepo.sh pull                                   # anytime — integrate from origin: auto-stash + rebase local commits onto remote work (multi-device); conflicts pause for 'mcrepo continue'
  ./mcrepo.sh pull --ff-only                         # anytime — conservative pull: fast-forward only, dirty repos skipped (fetch only); never stashes or rebases
  ./mcrepo.sh pr [-m "title"] [--draft] [--no-push] [--target origin|upstream]  # instead of push — coordinated GitHub PRs per repo; fork->upstream when upstream set; cross-linked
  ./mcrepo.sh branch                                 # List coordinated branches across write repos (alias: 'branch list')
  ./mcrepo.sh branch --delete                        # Discard the global branch, switch repos back to parent branches
  ./mcrepo.sh branch --off                           # Turn off branch coordination (fallback — see merge/--delete)
  ./mcrepo.sh commit --revert [--include-read] [--force]  # Peel the highest-#N coordinated commit off HEAD (reset --hard HEAD~1)
  ./mcrepo.sh commit --reset  [--include-read] [--force]  # Discard uncommitted changes across all target repos
  ./mcrepo.sh merge --no-squash                      # Legacy: --no-ff merge commit instead of squash
  ./mcrepo.sh pull --reset [--yes]                   # Discard local changes and reset to origin state (destructive!); prompts per repo before discarding committed work, --yes skips

═══════════════════════════════════════════════════════════════════════════════
  MID-OPERATION RECOVERY
═══════════════════════════════════════════════════════════════════════════════
  ./mcrepo.sh continue                            # Resume any mid-merge/rebase/cherry-pick/revert across repos (--continue); exits 2 while conflicts remain
  ./mcrepo.sh abort                               # Abort any mid-merge/rebase/cherry-pick/revert across repos (--abort); clears marker-less conflicts too
  ./mcrepo.sh resolve                             # Read-only diagnosis of stuck repos; prints a paste-ready coding-agent prompt on stdout

═══════════════════════════════════════════════════════════════════════════════
  INSPECTION & NAVIGATION
═══════════════════════════════════════════════════════════════════════════════
  ./mcrepo.sh status                              # Repo state + ahead/behind, mid-op, OFF-GLOBAL divergence, parent stack
  ./mcrepo.sh open <repo-name>                    # Open a write-mode repository in VS Code

═══════════════════════════════════════════════════════════════════════════════
  SKILLS
═══════════════════════════════════════════════════════════════════════════════
  ./mcrepo.sh skill [repo-name] <list|new|install|enable|disable|validate> [args] # Manage workspace or sub-repo skills (OpenCode-compatible)
                                                  # Browse public skills: https://clawhub.ai/skills

═══════════════════════════════════════════════════════════════════════════════
  TOOLING & MAINTENANCE
═══════════════════════════════════════════════════════════════════════════════
  ./mcrepo.sh version                             # Print the mcrepo version (plain, to stdout)
  ./mcrepo.sh update                              # Update mcrepo.sh from canonical upstream when newer version is available
  ./mcrepo.sh install-extension                   # Download and install the mcrepo VS Code extension from GitHub
  ./mcrepo.sh create-patch [--strategy intent|legacy] [topic] # Print a ready-to-submit GitHub issue body (with embedded patch) to stdout
  ./mcrepo.sh help                                # Print this help text

═══════════════════════════════════════════════════════════════════════════════
  CONVENTIONS
═══════════════════════════════════════════════════════════════════════════════
  Exit codes:  0 = success (including a declined confirmation)
               1 = fatal or usage error
               2 = partial failure (some repos succeeded, some failed)
  Prompts:     y/yes confirms, n/no declines, Enter takes the shown default,
               anything else declines. Non-interactive runs take the default;
               destructive actions then need --yes/--force (or MCREPO_ASSUME_YES=1).
  Output:      results go to stdout; version banner, prompts, warnings and
               errors go to stderr.
EOF
}

is_truthy() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# Unified confirmation prompt. Usage: confirm "Question?" [y|n]
# Second arg is the default answer (what Enter means); it defaults to "n".
# Returns 0 = confirmed, 1 = declined.
# Contract (identical for every prompt in mcrepo):
#   - affirmative: y/Y/yes/YES; negative: n/N/no/NO
#   - empty input takes the default
#   - any other input DECLINES (safe), never proceeds
#   - non-TTY: takes the default silently; destructive prompts must therefore
#     use default "n" and offer a --yes/--force flag for automation
#   - MCREPO_ASSUME_YES=1 confirms everything (CI escape hatch)
confirm() {
  local question="$1"
  local default="${2:-n}"
  if is_truthy "${MCREPO_ASSUME_YES:-0}"; then
    return 0
  fi
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    [ "$default" = "y" ]
    return $?
  fi
  local suffix="[y/N]"
  [ "$default" = "y" ] && suffix="[Y/n]"
  printf '%s %s ' "$question" "$suffix" >&2
  local _answer=""
  IFS= read -r _answer || _answer=""
  case "$_answer" in
    y|Y|yes|YES) return 0 ;;
    '') [ "$default" = "y" ]; return $? ;;
    *) return 1 ;;
  esac
}

print_version_banner() {
  if is_truthy "${MCREPO_SUPPRESS_VERSION_BANNER:-0}"; then
    return 0
  fi
  # stderr: stdout belongs to command output (parsers, completions, pipelines).
  printf 'mcrepo version %s\n' "$MCREPO_VERSION" >&2
}

update_source_url() {
  if [ -n "${MCREPO_UPDATE_URL:-}" ]; then
    printf '%s' "$MCREPO_UPDATE_URL"
    return 0
  fi
  printf 'https://raw.githubusercontent.com/%s/%s/%s' "$MCREPO_UPDATE_REPO" "$MCREPO_UPDATE_BRANCH" "$MCREPO_UPDATE_SCRIPT_PATH"
}

is_valid_version() {
  case "$1" in
    ''|*[!0-9.]*|*.*.*.*|.*|*.) return 1 ;;
  esac
  if [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi
  return 1
}

version_greater_than() {
  local left="$1"
  local right="$2"

  awk -v left="$left" -v right="$right" '
    BEGIN {
      left_count = split(left, left_parts, ".")
      right_count = split(right, right_parts, ".")
      max_count = left_count > right_count ? left_count : right_count
      for (i = 1; i <= max_count; i++) {
        l = (i in left_parts) ? left_parts[i] + 0 : 0
        r = (i in right_parts) ? right_parts[i] + 0 : 0
        if (l > r) {
          exit 0
        }
        if (l < r) {
          exit 1
        }
      }
      exit 1
    }
  '
}

# 'mcrepo merge' relies on 'git merge-tree --write-tree' (git 2.38+) for its
# conflict dry-run. Returns 1 when the installed git is provably older.
# Unparsable version strings pass (git itself will error out later).
git_supports_merge_tree_write_tree() {
  local v
  v="$(git version 2>/dev/null | awk '{print $3}')"
  [ -n "$v" ] || return 0
  case "$v" in
    [0-9]*.[0-9]*) ;;
    *) return 0 ;;
  esac
  if version_greater_than "2.38" "$v"; then
    return 1
  fi
  return 0
}

extract_version_from_file() {
  local file_path="$1"
  awk -F'"' '/^MCREPO_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$/ { print $2; exit }' "$file_path"
}

fetch_remote_script_to_file() {
  local target_file="$1"
  local source_url

  source_url="$(update_source_url)"
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  # When doing an explicit update, append a timestamp query param to bust the CDN cache.
  # Fastly (GitHub raw CDN) uses the full URL as cache key and ignores Cache-Control request headers.
  if is_truthy "${MCREPO_FETCH_NO_CACHE:-0}"; then
    source_url="${source_url}?_=$(date +%s)"
  fi

  if is_truthy "${MCREPO_UPDATE_CHECK_QUIET:-0}"; then
    curl --fail --silent --location --max-time 4 "$source_url" >"$target_file" 2>/dev/null
  else
    curl --fail --silent --show-error --location --max-time 4 "$source_url" >"$target_file"
  fi
}

source_url_for_ref() {
  local ref="$1"
  printf 'https://raw.githubusercontent.com/%s/%s/%s' "$MCREPO_UPDATE_REPO" "$ref" "$MCREPO_UPDATE_SCRIPT_PATH"
}

fetch_remote_script_ref_to_file() {
  local ref="$1"
  local target_file="$2"
  local source_url

  source_url="$(source_url_for_ref "$ref")"
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi

  curl --fail --silent --location --max-time 6 "$source_url" >"$target_file" 2>/dev/null
}

fetch_remote_script_version_to_file() {
  local version="$1"
  local target_file="$2"
  local ref repo_url repo_tmp_file repo_tmp_dir commit script_version

  ref="v$version"
  if fetch_remote_script_ref_to_file "$ref" "$target_file"; then
    return 0
  fi

  ref="$version"
  if fetch_remote_script_ref_to_file "$ref" "$target_file"; then
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    return 1
  fi

  repo_tmp_dir="$(mktemp -d)"
  repo_tmp_file="$(mktemp)"
  repo_url="https://github.com/$MCREPO_UPDATE_REPO.git"

  if ! git clone --quiet --depth 200 --branch "$MCREPO_UPDATE_BRANCH" "$repo_url" "$repo_tmp_dir" >/dev/null 2>&1; then
    rm -rf "$repo_tmp_dir"
    rm -f "$repo_tmp_file"
    return 1
  fi

  while IFS= read -r commit; do
    if git -C "$repo_tmp_dir" show "$commit:$MCREPO_UPDATE_SCRIPT_PATH" >"$repo_tmp_file" 2>/dev/null; then
      script_version="$(extract_version_from_file "$repo_tmp_file" || true)"
      if [ "$script_version" = "$version" ]; then
        cp "$repo_tmp_file" "$target_file"
        rm -rf "$repo_tmp_dir"
        rm -f "$repo_tmp_file"
        return 0
      fi
    fi
  done < <(git -C "$repo_tmp_dir" log --format='%H' -- "$MCREPO_UPDATE_SCRIPT_PATH")

  rm -rf "$repo_tmp_dir"
  rm -f "$repo_tmp_file"
  return 1
}

check_remote_version() {
  local remote_tmp_file="$1"
  local remote_version

  if ! fetch_remote_script_to_file "$remote_tmp_file"; then
    return 1
  fi

  remote_version="$(extract_version_from_file "$remote_tmp_file" || true)"
  if ! is_valid_version "$remote_version"; then
    return 1
  fi

  printf '%s' "$remote_version"
}

_print_update_notice() {
  local remote_version="$1"
  if version_greater_than "$remote_version" "$MCREPO_VERSION"; then
    log_yellow "New version available: $MCREPO_VERSION -> $remote_version" >&2
    log_yellow "Run 'mcrepo update' to update this script." >&2
  fi
}

notify_if_new_version_available() {
  local cmd="$1"
  local remote_tmp_file remote_version

  case "$cmd" in
    update|--post-update-migrate|version) return 0 ;;
  esac
  if is_truthy "${MCREPO_DISABLE_UPDATE_CHECK:-0}"; then
    return 0
  fi

  # Throttle: hit the network at most once per 24h. Without this, EVERY
  # command paid a blocking fetch (up to 4s offline) just to read a version.
  local cache_file="${HOME:-/tmp}/.mcrepo-update-check"
  local now cached_at="" cached_version=""
  now="$(date +%s)"
  if [ -f "$cache_file" ]; then
    IFS=' ' read -r cached_at cached_version <"$cache_file" 2>/dev/null || true
    case "$cached_at" in
      ''|*[!0-9]*) cached_at=0 ;;
    esac
    if [ $((now - cached_at)) -lt 86400 ]; then
      [ -n "$cached_version" ] && _print_update_notice "$cached_version"
      return 0
    fi
  fi

  remote_tmp_file="$(mktemp)"
  remote_version="$(MCREPO_UPDATE_CHECK_QUIET=1 check_remote_version "$remote_tmp_file" || true)"
  rm -f "$remote_tmp_file"

  if [ -z "$remote_version" ]; then
    return 0
  fi

  printf '%s %s\n' "$now" "$remote_version" >"$cache_file" 2>/dev/null || true
  _print_update_notice "$remote_version"
}

resolve_script_path() {
  local source_path script_dir
  source_path="${BASH_SOURCE[0]}"
  # Follow symlinks so self-update replaces the real file, not the link.
  # (readlink -f is not portable to macOS; walk links manually.)
  local guard=0
  while [ -L "$source_path" ] && [ "$guard" -lt 10 ]; do
    local link_target
    link_target="$(readlink "$source_path")" || break
    case "$link_target" in
      /*) source_path="$link_target" ;;
      *) source_path="$(dirname "$source_path")/$link_target" ;;
    esac
    guard=$((guard + 1))
  done
  script_dir="$(cd "$(dirname "$source_path")" && pwd -P)"
  printf '%s/%s' "$script_dir" "$(basename "$source_path")"
}

print_description_update_prompt() {
  cat <<'EOF'

If you have finished adding all projects, please run the following prompt once in your local agent AI in 'build' mode:

You are working inside a Multi-Context-Repo (MC-Repo). Update only `mcrepo.yaml` by filling the `description` field for each repo entry. For each repository, inspect the local repo at `localpath` (if present) and write one short, functional description (ideally 12–25 words, one sentence) that states (1) the repo’s primary purpose and (2) its role relative to the other repos in this MC-Repo. Use precise technical language, no marketing wording. Do not modify source code or any files other than `mcrepo.yaml`. Preserve YAML formatting, indentation, field order, and comments as much as possible. Keep all existing fields unchanged except `description`. If a useful description already exists, keep or minimally improve it for consistency. If a repo cannot be inspected locally (e.g. missing `localpath`), do not invent details; leave `description` empty. For each repo, inspect briefly: README/docs, package/build files (`package.json`, `pyproject.toml`, `go.mod`, etc.), main entrypoints, API/schema/contract files, and local `AGENTS.md`/`CLAUDE.md` if present. Prefer description style: "<Primary function>; <role in MC-Repo context>." Avoid vague phrases, long explanations, and low-value implementation trivia. After updating `mcrepo.yaml`, output a short summary: how many descriptions were added/updated, which repos were skipped, and which descriptions are uncertain.

EOF
}

derive_name_from_url() {
  local url="$1"
  local trimmed="${url%/}"
  local name="${trimmed##*/}"
  name="${name%.git}"
  printf '%s' "$name"
}

yaml_escape_double_quoted() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

validate_mode() {
  case "$1" in
    write|read|sleep) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_mode() {
  case "$1" in
    off) printf 'sleep' ;;
    *) printf '%s' "$1" ;;
  esac
}

mode_icon() {
  case "$1" in
    write) printf '✏️' ;;
    read) printf '👀' ;;
    sleep) printf '💤' ;;
    *) printf '•' ;;
  esac
}

repo_dir_for_mode() {
  local repo_name="$1"
  printf '%s' "$repo_name"
}

repo_local_path_for_mode() {
  local repo_name="$1"
  local mode="$2"
  printf './%s' "$(repo_dir_for_mode "$repo_name" "$mode")"
}

find_existing_repo_dir() {
  local repo_name="$1"

  if [ -d "$repo_name/.git" ] || [ -d "$repo_name" ]; then
    printf '%s' "$repo_name"
    return 0
  fi

  return 1
}

get_repo_dir() {
  local repo_name="$1"
  local mode="$2"
  local expected
  expected="$(repo_dir_for_mode "$repo_name" "$mode")"

  if [ -e "$expected" ]; then
    printf '%s' "$expected"
    return 0
  fi

  local existing
  if existing="$(find_existing_repo_dir "$repo_name")"; then
    printf '%s' "$existing"
    return 0
  fi

  printf '%s' "$expected"
}

ensure_repo_dir_mode() {
  local repo_name="$1"
  local mode="$2"
  local expected current
  expected="$(repo_dir_for_mode "$repo_name" "$mode")"

  if current="$(find_existing_repo_dir "$repo_name")"; then
    if [ "$current" != "$expected" ]; then
      if [ -e "$expected" ]; then
        warn "Cannot rename '$current' to '$expected' because target exists"
        printf '%s' "$current"
        return 0
      fi
      mv "$current" "$expected"
      printf 'Renamed repo folder: %s -> %s\n' "$current" "$expected" >&2
    fi
    printf '%s' "$expected"
    return 0
  fi

  printf '%s' "$expected"
}

clear_directory_contents() {
  local dir="$1"
  [ -d "$dir" ] || return 0

  local entry
  shopt -s dotglob nullglob
  for entry in "$dir"/*; do
    rm -rf "$entry"
  done
  shopt -u dotglob nullglob
}

write_sleep_placeholder_files() {
  local dir="$1"
  [ -d "$dir" ] || return 0

  cat >"$dir/.gitignore" <<'EOF'
*
!.gitignore
!.mcrepo-sleep
EOF

  cat >"$dir/.mcrepo-sleep" <<'EOF'
This repository is in mcrepo sleep mode.

Its local working copy is intentionally not kept here while sleeping.
When you switch it back to read or write mode, mcrepo checks it out again.
EOF
}

ensure_repos_file_exists() {
  if [ ! -f "$REPOS_FILE" ]; then
    printf 'repos: []\n' >"$REPOS_FILE"
  fi
}

parse_repos_tsv() {
  awk -v SEP=$'\x1f' '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    # Reverse of yaml_escape_double_quoted: unescape \\ and \" left-to-right.
    # Without this, every load/save cycle adds another backslash layer to
    # descriptions containing quotes or backslashes.
    function unescape_dq(s,   out, i, n, c, nc) {
      out = ""; n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\" && i < n) {
          nc = substr(s, i + 1, 1)
          if (nc == "\\" || nc == "\"") {
            out = out nc
            i += 2
            continue
          }
        }
        out = out c
        i++
      }
      return out
    }
    function unquote(s) {
      s = trim(s)
      if (s ~ /^".*"$/) {
        return unescape_dq(substr(s, 2, length(s) - 2))
      }
      if (s ~ /^\047.*\047$/) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    function parse_kv(s,   p, k, v) {
      s = trim(s)
      p = index(s, ":")
      if (p == 0) {
        return
      }
      k = trim(substr(s, 1, p - 1))
      v = unquote(substr(s, p + 1))
      if (k == "url") {
        url = v
      } else if (k == "name") {
        name = v
      } else if (k == "mode") {
        mode = v
      } else if (k == "description") {
        description = v
      } else if (k == "parent") {
        parent = v
      } else if (k == "local") {
        local = v
      } else if (k == "upstream") {
        upstream = v
      }
    }
    function emit() {
      if (in_item) {
        print url SEP name SEP mode SEP description SEP parent SEP local SEP upstream
      }
    }
    BEGIN {
      in_item = 0
      url = ""
      name = ""
      mode = ""
      description = ""
      parent = ""
      local = ""
      upstream = ""
    }
    {
      line = $0
      if (line ~ /^[ \t]*-[ \t]*/) {
        emit()
        in_item = 1
        url = ""
        name = ""
        mode = ""
        description = ""
        parent = ""
        local = ""
        upstream = ""
        sub(/^[ \t]*-[ \t]*/, "", line)
        parse_kv(line)
        next
      }
      if (in_item && line ~ /^[ \t]+[A-Za-z0-9_-]+:[ \t]*/) {
        parse_kv(line)
        next
      }
      if (in_item && line !~ /^[ \t]*$/ && line !~ /^[ \t]*#/) {
        emit()
        in_item = 0
      }
    }
    END {
      emit()
    }
  ' "$REPOS_FILE"
}

parse_organization() {
  awk '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      if (line ~ /^[ \t]*organization:[ \t]*/) {
        sub(/^[ \t]*organization:[ \t]*/, "", line)
        print unquote(line)
        exit
      }
    }
  ' "$REPOS_FILE"
}

parse_branch() {
  awk '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      if (line ~ /^[ \t]*branch:[ \t]*/) {
        sub(/^[ \t]*branch:[ \t]*/, "", line)
        print unquote(line)
        exit
      }
    }
  ' "$REPOS_FILE"
}

# Parse the top-level 'schema:' field from mcrepo.yaml (manifest format version).
parse_schema_version() {
  awk '
    {
      line = $0
      if (line ~ /^[ \t]*schema:[ \t]*/) {
        sub(/^[ \t]*schema:[ \t]*/, "", line)
        gsub(/[ \t]+/, "", line)
        print line
        exit
      }
    }
  ' "$REPOS_FILE"
}

# Parse the top-level 'meta-parent:' field from mcrepo.yaml.
# Returns the comma-separated parent branch stack for the meta-context repo.
parse_meta_parent() {
  awk '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      if (line ~ /^[ \t]*meta-parent:[ \t]*/) {
        sub(/^[ \t]*meta-parent:[ \t]*/, "", line)
        print unquote(line)
        exit
      }
    }
  ' "$REPOS_FILE"
}

parse_meta_upstream() {
  awk '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      if (line ~ /^[ \t]*meta-upstream:[ \t]*/) {
        sub(/^[ \t]*meta-upstream:[ \t]*/, "", line)
        print unquote(line)
        exit
      }
    }
  ' "$REPOS_FILE"
}

REPO_URLS=()
REPO_NAMES=()
REPO_MODES=()
REPO_DESCRIPTIONS=()
# Per-repo parent branch stack (comma-separated, rightmost = immediate parent).
# Pushed on 'mcrepo branch', popped on 'mcrepo merge'.
# Example: "main,feature" means feature is immediate parent, main is grandparent.
REPO_PARENTS=()
# Incubator flag per repo ("true"/"false"). Local repos live inside base mcrepo's
# git history with no external remote until promoted via 'mcrepo publish'.
REPO_LOCALS=()
# Per-repo upstream repo URL (fork workflow): origin (REPO_URLS) is where you push
# (your fork/own repo), upstream is the original repo that PRs target. Empty when
# you work directly in your own repo. Tracked via 'upstream:' in mcrepo.yaml.
REPO_UPSTREAMS=()
ORGANIZATION=""
GLOBAL_BRANCH=""
# Parent branch stack for the meta-context repo itself (same comma-separated
# format as REPO_PARENTS). Tracked via 'meta-parent:' in mcrepo.yaml.
META_PARENT=""
# Upstream (PR target) URL for the meta-context repo itself, set when the meta-repo
# is a fork. Its origin lives only in the git remote. Tracked via 'meta-upstream:'.
META_UPSTREAM=""

is_repo_local() {
  local idx="$1"
  case "${REPO_LOCALS[$idx]:-false}" in
    true|1|yes|TRUE|YES) return 0 ;;
    *) return 1 ;;
  esac
}

load_repos() {
  ensure_repos_file_exists
  REPO_URLS=()
  REPO_NAMES=()
  REPO_MODES=()
  REPO_DESCRIPTIONS=()
  REPO_PARENTS=()
  REPO_LOCALS=()
  REPO_UPSTREAMS=()
  ORGANIZATION=""
  GLOBAL_BRANCH=""
  META_PARENT=""
  META_UPSTREAM=""

  local manifest_schema
  manifest_schema="$(parse_schema_version || true)"
  if [ -n "$manifest_schema" ] && [ "$manifest_schema" != "$MCREPO_SCHEMA_VERSION" ]; then
    case "$manifest_schema" in
      *[!0-9]*) warn "Ignoring unparsable schema value in $REPOS_FILE: '$manifest_schema'" ;;
      *)
        if [ "$manifest_schema" -gt "$MCREPO_SCHEMA_VERSION" ]; then
          die "$REPOS_FILE uses manifest schema $manifest_schema, but this mcrepo only understands schema $MCREPO_SCHEMA_VERSION. Run 'mcrepo update' first."
        fi
        ;;
    esac
  fi

  ORGANIZATION="$(parse_organization || true)"
  GLOBAL_BRANCH="$(parse_branch || true)"
  META_PARENT="$(parse_meta_parent || true)"
  META_UPSTREAM="$(parse_meta_upstream || true)"

  local parsed_url parsed_name parsed_mode parsed_description parsed_parent parsed_local parsed_upstream
  while IFS=$'\x1f' read -r parsed_url parsed_name parsed_mode parsed_description parsed_parent parsed_local parsed_upstream; do
    local is_local="false"
    case "${parsed_local:-}" in
      true|1|yes|TRUE|YES) is_local="true" ;;
    esac
    if [ -z "$parsed_url" ] && [ "$is_local" != "true" ]; then
      continue
    fi
    if [ -z "$parsed_name" ]; then
      if [ -n "$parsed_url" ]; then
        parsed_name="$(derive_name_from_url "$parsed_url")"
      fi
    fi
    [ -n "$parsed_name" ] || continue
    if ! validate_mode "${parsed_mode:-}"; then
      parsed_mode="read"
    fi
    parsed_mode="$(normalize_mode "$parsed_mode")"
    parsed_description="${parsed_description:-}"
    REPO_URLS+=("$parsed_url")
    REPO_NAMES+=("$parsed_name")
    REPO_MODES+=("$parsed_mode")
    REPO_DESCRIPTIONS+=("$parsed_description")
    REPO_PARENTS+=("${parsed_parent:-}")
    REPO_LOCALS+=("$is_local")
    REPO_UPSTREAMS+=("${parsed_upstream:-}")
  done < <(parse_repos_tsv)
}

save_repos() {
  # Write to a same-directory temp file and rename into place: save_repos also
  # runs from EXIT traps during aborted coordinated operations, and a torn
  # write here would corrupt the workspace's single source of truth.
  local tmp_file="$REPOS_FILE.tmp.$$"
  {
    printf 'schema: %s\n' "$MCREPO_SCHEMA_VERSION"
    if [ -n "$ORGANIZATION" ]; then
      printf 'organization: %s\n' "$ORGANIZATION"
    fi
    if [ -n "$GLOBAL_BRANCH" ]; then
      printf 'branch: %s\n' "$GLOBAL_BRANCH"
    fi
    if [ -n "$META_PARENT" ]; then
      printf 'meta-parent: %s\n' "$META_PARENT"
    fi
    if [ -n "$META_UPSTREAM" ]; then
      printf 'meta-upstream: %s\n' "$META_UPSTREAM"
    fi

    if [ "${#REPO_NAMES[@]}" -eq 0 ]; then
      printf 'repos: []\n'
    else
      printf 'repos:\n'
      local i
      for i in "${!REPO_NAMES[@]}"; do
        if [ -n "${REPO_URLS[$i]:-}" ]; then
          printf '  - url: %s\n' "${REPO_URLS[$i]}"
          printf '    name: %s\n' "${REPO_NAMES[$i]}"
        else
          printf '  - name: %s\n' "${REPO_NAMES[$i]}"
        fi
        printf '    mode: %s\n' "${REPO_MODES[$i]}"
        printf '    description: "%s"\n' "$(yaml_escape_double_quoted "${REPO_DESCRIPTIONS[$i]}")"
        if [ -n "${REPO_PARENTS[$i]:-}" ]; then
          printf '    parent: %s\n' "${REPO_PARENTS[$i]}"
        fi
        if [ -n "${REPO_UPSTREAMS[$i]:-}" ]; then
          printf '    upstream: %s\n' "${REPO_UPSTREAMS[$i]}"
        fi
        if is_repo_local "$i"; then
          printf '    local: true\n'
        fi
        printf '    localpath: %s\n' "$(repo_local_path_for_mode "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
      done
    fi
  } >"$tmp_file"
  mv -f "$tmp_file" "$REPOS_FILE"
}

sync_organization_repos() {
  local org_name="$1"
  local imported=0 skipped=0

  # The org name is interpolated into gh/curl GitHub API paths — restrict it
  # to the GitHub org charset before it can reshape a request.
  case "$org_name" in
    ''|*[!A-Za-z0-9-]*) die "Invalid organization name: '$org_name' (letters, digits and dashes only)." ;;
  esac

  fetch_org_repos_tsv() {
    local org="$1"

    if command -v gh >/dev/null 2>&1; then
      if gh api --paginate "orgs/$org/repos?type=all&per_page=100" --jq '.[] | select(.archived | not) | [.clone_url, .name] | @tsv' 2>/dev/null; then
        return 0
      fi
      warn "GitHub CLI org fetch failed for '$org'; falling back to public GitHub API"
    fi

    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
      warn "Fallback org sync requires both 'curl' and 'jq'"
      return 1
    fi

    warn "Using unauthenticated public GitHub API for '$org' (public repositories only)"
    local page=1 response repo_count
    while :; do
      response="$(curl -fsSL "https://api.github.com/orgs/$org/repos?type=public&per_page=100&page=$page" 2>/dev/null || true)"
      if [ -z "$response" ]; then
        break
      fi

      repo_count="$(printf '%s' "$response" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null || printf '0')"
      if [ "$repo_count" -eq 0 ] 2>/dev/null; then
        break
      fi

      printf '%s' "$response" | jq -r '.[] | select(.archived | not) | [.clone_url, .name] | @tsv'
      page=$((page + 1))
    done

    return 0
  }

  local repo_rows
  if ! repo_rows="$(fetch_org_repos_tsv "$org_name")"; then
    warn "Could not fetch repositories for organization '$org_name'; skipping organization sync"
    warn "Check organization name and GitHub access, or run: gh auth login"
    return 0
  fi

  local repo_url repo_name
  while IFS=$'\t' read -r repo_url repo_name; do
    [ -n "$repo_url" ] || continue
    [ -n "$repo_name" ] || continue

    if find_repo_index "$repo_url" >/dev/null 2>&1 || find_repo_index "$repo_name" >/dev/null 2>&1; then
      skipped=$((skipped + 1))
      continue
    fi

    REPO_URLS+=("$repo_url")
    REPO_NAMES+=("$repo_name")
    REPO_MODES+=("read")
    REPO_DESCRIPTIONS+=("")
    REPO_PARENTS+=("")
    REPO_LOCALS+=("false")
    REPO_UPSTREAMS+=("")
    ensure_gitignore_repo_entry "$repo_name"
    imported=$((imported + 1))
  done <<<"$repo_rows"

  log "Organization '$org_name' sync: added=$imported skipped=$skipped"
}

find_repo_index() {
  local needle="$1"
  [ -n "$needle" ] || return 1
  local i
  for i in "${!REPO_NAMES[@]}"; do
    if [ "${REPO_NAMES[$i]}" = "$needle" ]; then
      printf '%s' "$i"
      return 0
    fi
    if [ -n "${REPO_URLS[$i]:-}" ] && [ "${REPO_URLS[$i]}" = "$needle" ]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

ensure_gitignore_base() {
  if [ ! -f .gitignore ]; then
    : >.gitignore
  fi
  ensure_gitignore_standard_entries
}

# Standard ignore entries that every mcrepo base workspace should carry,
# regardless of which sub-repos are registered. Idempotent: only appends
# entries that are not already present as exact lines.
ensure_gitignore_standard_entries() {
  [ -f .gitignore ] || : >.gitignore
  local entry
  local -a standard_entries=(
    "graphify-out/"
  )
  for entry in "${standard_entries[@]}"; do
    if ! grep -Fqx "$entry" .gitignore; then
      printf '%s\n' "$entry" >>.gitignore
    fi
  done
}

ensure_gitignore_repo_entry() {
  local repo_name="$1"
  ensure_gitignore_base
  local line tmp

  line="/$repo_name/"
  if ! grep -Fqx "$line" .gitignore; then
    printf '%s\n' "$line" >>.gitignore
  fi
}

remove_gitignore_repo_entry() {
  local repo_name="$1"
  [ -f .gitignore ] || return 0
  local tmp
  tmp="$(mktemp)"
  grep -Fvx "/$repo_name/" .gitignore >"$tmp" || true
  mv "$tmp" .gitignore
}

# Walks every loaded repo and reconciles base .gitignore against its kind:
#   - External repos (local=false): must have /<name>/ entry → ensure_gitignore_repo_entry.
#   - Local incubator repos (local=true): must NOT have /<name>/ entry → remove_gitignore_repo_entry.
# Idempotent. Safe to call repeatedly. Must be called BEFORE the first base
# commit during 'mcrepo publish-base' so external sub-repos don't leak in.
reconcile_gitignore_with_repos() {
  ensure_gitignore_base
  local i
  for i in "${!REPO_NAMES[@]}"; do
    if is_repo_local "$i"; then
      remove_gitignore_repo_entry "${REPO_NAMES[$i]}"
    else
      ensure_gitignore_repo_entry "${REPO_NAMES[$i]}"
    fi
  done
}

# Allow only well-known git transports. mcrepo.yaml is a committed, shareable
# manifest — cloning a hostile workspace must not hand git an ext::/fd::
# remote-helper transport or an option-injection value (leading dash).
validate_repo_url() {
  local url="$1"
  case "$url" in
    ''|-*) return 1 ;;
    https://*|http://*|ssh://*|git://*|file://*) return 0 ;;
    /*|./*|../*) return 0 ;;
    *::*) return 1 ;;
    [A-Za-z0-9_.-]*@*:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Reject branch names git itself would refuse, plus leading-dash values that
# could be parsed as options by downstream git calls.
validate_branch_name() {
  local name="$1"
  case "$name" in
    ''|-*) return 1 ;;
  esac
  git check-ref-format "refs/heads/$name" >/dev/null 2>&1
}

clone_repo_if_needed() {
  local repo_dir="$1"
  local repo_url="$2"
  local mode="$3"

  if [ "$mode" = "sleep" ]; then
    return 0
  fi
  if ! validate_repo_url "$repo_url"; then
    warn "Refusing to clone '$repo_dir': unsupported or unsafe repo URL '$repo_url' (allowed: https, ssh, git, file, local path, scp-style)."
    return 1
  fi
  if [ -d "$repo_dir/.git" ]; then
    return 0
  fi
  if [ -e "$repo_dir" ] && [ ! -d "$repo_dir" ]; then
    warn "Path '$repo_dir' exists and is not a directory, skipping clone"
    return 1
  fi

  if [ -d "$repo_dir" ]; then
    if [ -f "$repo_dir/.mcrepo-sleep" ]; then
      clear_directory_contents "$repo_dir"
    fi

    shopt -s nullglob dotglob
    local entries=("$repo_dir"/*)
    shopt -u nullglob dotglob
    if [ "${#entries[@]}" -gt 0 ]; then
      warn "Path '$repo_dir' exists but is not a git repository and not empty, skipping clone"
      return 1
    fi
  fi

  log "Cloning $repo_dir..."
  if git clone "$repo_url" "$repo_dir"; then
    return 0
  fi

  if [ -d "$repo_dir" ]; then
    warn "Initial clone failed for '$repo_dir'. Cleaning partial contents and retrying once."
    clear_directory_contents "$repo_dir"
    if git clone "$repo_url" "$repo_dir"; then
      return 0
    fi
  fi

  return 1
}

refresh_generated_files() {
  rm -f .mcrepo-completion.csh

  generate_bash_completion
  generate_zsh_completion
}

# Replace the __MCREPO_COMMANDS__ placeholder in a generated completion file
# with the single command inventory defined at the top of this script.
_substitute_command_inventory() {
  local file="$1" tmp
  tmp="$(mktemp)"
  sed "s/__MCREPO_COMMANDS__/$MCREPO_COMMANDS/" "$file" >"$tmp" && mv "$tmp" "$file"
}

generate_bash_completion() {
  cat >"$COMPLETION_BASH_FILE" <<'EOF'
# Generated by mcrepo.sh - Bash completion

_mcrepo_repo_names() {
  local cfg="./mcrepo.yaml"
  [ -f "$cfg" ] || return 0

  awk '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      if (line ~ /^[ \t]+name:[ \t]*/) {
        sub(/^[ \t]+name:[ \t]*/, "", line)
        print unquote(line)
      }
    }
  ' "$cfg"
}

_mcrepo_complete() {
  local cur prev
  local commands="__MCREPO_COMMANDS__"
  local skill_commands="list new install enable disable validate"

  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  if [ "$COMP_CWORD" -eq 1 ]; then
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    init)
      ;;
    add)
      ;;
    branch)
      if [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=( $(compgen -W "list --off --delete --include-read --dirty" -- "$cur") )
      else
        COMPREPLY=( $(compgen -W "--include-read --dirty" -- "$cur") )
      fi
      ;;
    rebase)
      COMPREPLY=( $(compgen -W "--include-read" -- "$cur") )
      ;;
    merge)
      COMPREPLY=( $(compgen -W "--no-squash --include-read -m" -- "$cur") )
      ;;
    pr)
      COMPREPLY=( $(compgen -W "-m --draft --no-push --target" -- "$cur") )
      ;;
    pull)
      COMPREPLY=( $(compgen -W "--ff-only --reset --yes" -- "$cur") )
      ;;
    push)
      COMPREPLY=( $(compgen -W "-m --no-fetch --no-force --include-read" -- "$cur") )
      ;;
    commit)
      COMPREPLY=( $(compgen -W "-m --include-read --revert --reset --force" -- "$cur") )
      ;;
    skill)
      if [ "$COMP_CWORD" -eq 2 ]; then
        COMPREPLY=( $(compgen -W "$skill_commands $(_mcrepo_repo_names)" -- "$cur") )
      elif [ "$COMP_CWORD" -eq 3 ]; then
        if [ "${COMP_WORDS[2]}" = "enable" -o "${COMP_WORDS[2]}" = "disable" ]; then
          COMPREPLY=( $(compgen -W "$(MCREPO_SUPPRESS_VERSION_BANNER=1 MCREPO_DISABLE_UPDATE_CHECK=1 ./mcrepo.sh skill list --ids 2>/dev/null || true)" -- "$cur") )
        elif printf '%s\n' "$(_mcrepo_repo_names)" | grep -Fxq "${COMP_WORDS[2]}"; then
          COMPREPLY=( $(compgen -W "$skill_commands" -- "$cur") )
        fi
      fi
      ;;
    remove|write|read|sleep|open)
      if [ "$COMP_CWORD" -eq 2 ]; then
        if [ "${COMP_WORDS[1]}" = "sleep" ]; then
          COMPREPLY=( $(compgen -W "$(_mcrepo_repo_names) --wakeall" -- "$cur") )
        else
          COMPREPLY=( $(compgen -W "$(_mcrepo_repo_names)" -- "$cur") )
        fi
      elif [ "$COMP_CWORD" -ge 3 ] && [ "${COMP_WORDS[1]}" = "remove" ]; then
        COMPREPLY=( $(compgen -W "--keep-files --force" -- "$cur") )
      elif [ "$COMP_CWORD" -eq 3 ] && [ "${COMP_WORDS[1]}" = "sleep" ]; then
        COMPREPLY=( $(compgen -W "--force" -- "$cur") )
      fi
      ;;
    *)
      ;;
  esac
}

complete -F _mcrepo_complete mcrepo
complete -F _mcrepo_complete ./mcrepo.sh
EOF
  _substitute_command_inventory "$COMPLETION_BASH_FILE"
}

generate_zsh_completion() {
  cat >"$COMPLETION_ZSH_FILE" <<'EOF'
#compdef mcrepo ./mcrepo.sh
# Generated by mcrepo.sh - Zsh completion

if ! whence -w compdef >/dev/null 2>&1; then
  autoload -Uz compinit
  compinit
fi

_mcrepo_repo_names() {
  local cfg="./mcrepo.yaml"
  [[ -f "$cfg" ]] || return 0

  awk '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      if (line ~ /^[ \t]+name:[ \t]*/) {
        sub(/^[ \t]+name:[ \t]*/, "", line)
        print unquote(line)
      }
    }
  ' "$cfg"
}

_mcrepo_complete() {
  local cmd
  local subcmd
  local -a commands repos skill_commands

  commands=(__MCREPO_COMMANDS__)
  skill_commands=(list new install enable disable validate)
  repos=("${(@f)$(_mcrepo_repo_names)}")

  if (( CURRENT == 2 )); then
    compadd -- "${commands[@]}"
    return 0
  fi

  cmd="${words[2]}"
  case "$cmd" in
    init)
      ;;
    branch)
      if (( CURRENT == 3 )); then
        compadd -- list --off --delete --include-read --dirty
      else
        compadd -- --include-read --dirty
      fi
      ;;
    rebase)
      compadd -- --include-read
      ;;
    merge)
      compadd -- --no-squash --include-read -m
      ;;
    pr)
      compadd -- -m --draft --no-push --target
      ;;
    pull)
      compadd -- --ff-only --reset --yes
      ;;
    push)
      compadd -- -m --no-fetch --no-force --include-read
      ;;
    commit)
      compadd -- -m --include-read --revert --reset --force
      ;;
    skill)
      if (( CURRENT == 3 )); then
        compadd -- "${skill_commands[@]}" "${repos[@]}"
      elif (( CURRENT == 4 )); then
        subcmd="${words[3]}"
        if [[ "$subcmd" == "enable" || "$subcmd" == "disable" ]]; then
          compadd -- "${(@f)$(MCREPO_SUPPRESS_VERSION_BANNER=1 MCREPO_DISABLE_UPDATE_CHECK=1 ./mcrepo.sh skill list --ids 2>/dev/null)}"
        elif (( ${repos[(Ie)$subcmd]} > 0 )); then
          compadd -- "${skill_commands[@]}"
        fi
      fi
      ;;
    remove|write|read|sleep|open)
      if (( CURRENT == 3 )); then
        if [[ "$cmd" == "sleep" ]]; then
          compadd -- "${repos[@]}" --wakeall
        else
          compadd -- "${repos[@]}"
        fi
      elif (( CURRENT >= 4 )) && [[ "$cmd" == "remove" ]]; then
        compadd -- --keep-files --force
      elif (( CURRENT == 4 )) && [[ "$cmd" == "sleep" ]]; then
        compadd -- --force
      fi
      ;;
    *) ;;
  esac
}

compdef _mcrepo_complete mcrepo
compdef _mcrepo_complete ./mcrepo.sh
EOF
  _substitute_command_inventory "$COMPLETION_ZSH_FILE"
}

create_readme_template() {
  cat >README.md <<'EOF'
# Multi-Context Repo

This repository is a lightweight meta-repo for coordinating multiple standalone repositories with explicit access modes.
It provides workspace governance across repos, shared documentation, tests, and reusable agent skills.

## Quickstart

1. Put `mcrepo.sh` in the repository root.
2. Make it executable: `chmod +x ./mcrepo.sh`
3. Initialize: `./mcrepo.sh init`
4. Open a new shell once, then run commands as `mcrepo`
5. Add a repository: `mcrepo add <git-url>`
6. Set repo mode: `mcrepo write <repo>` or `mcrepo read <repo>` or `mcrepo sleep <repo>`
7. Coordinate branch across target repos and meta-context repo: `mcrepo branch <branch-name>` (turn off with `mcrepo branch --off`)
8. After feature work: `mcrepo rebase` (rebase onto parent, resolve conflicts here), then `mcrepo merge`
9. To discard a branch instead: `mcrepo branch --delete`
10. Check state: `mcrepo status`
11. Manage workspace skills: `mcrepo skill list`
12. Install skills from URL: `mcrepo skill install <github-url|clawhub-url>`

## Core Concepts

- `mcrepo.yaml` is the source of truth for managed repositories.
- `mcrepo.yaml` can define a top-level `branch` that acts as the global working branch for write repos.
- Modes control intent:
  - `write`: editable and active
  - `read`: local context only
  - `sleep`: currently inactive
- Repository folders always use clean repo names (no mode-prefix or emoji-prefix renaming)
- `mcrepo.sh` orchestrates repositories.
- `mcrepo branch <name>` updates the global branch, aligns write repos (optionally read repos), then switches the meta-context repo.
- Branch switching distinguishes fork vs jump: existing branches are jumped to (no parent recorded), new branches are forked (parent recorded).
- When uncommitted changes exist, mcrepo offers interactive options: abort, commit, carry (stash+pop with dry-run), or discard.
- Branch switching is remote-first: if `origin/<name>` exists and local `<name>` does not, mcrepo creates a tracking local branch from origin.
- Switching a repo to `write` auto-aligns it to the global branch when configured.
- `mcrepo branch --off` disables global branch coordination (fallback — prefer `merge` or `--delete`).
- `mcrepo branch --delete` discards the global branch, switches repos back to parent branches, and deletes the branch locally.
- Parent branches are recorded automatically when `mcrepo branch` forks a new branch. Each repo can have a different parent.
- `mcrepo rebase` rebases the current branch onto its parent (prefers `origin/<parent>`, falls back to local `<parent>`). Auto-stashes uncommitted work. Conflicts are resolved HERE, on the feature branch — never during the merge. Rewrites local history; `mcrepo push` re-publishes safely.
- `mcrepo merge` merges the global branch into each write repo's parent branch (local only, no push). It requires a synced branch (run `mcrepo rebase` first) and performs a conflict dry-run, so the merge itself never conflicts.
- `mcrepo resolve` diagnoses stuck repos (mid-rebase, conflicts, leftover stashes) and prints a paste-ready prompt for a coding agent.
- `mcrepo pull` is the origin-side twin of `mcrepo rebase`: it auto-stashes uncommitted changes, rebases local commits onto origin (multi-device work integrates cleanly), then pops the stash. Conflicts pause as `inprogress=REBASING` — resolve, then `mcrepo continue`. Safe for dirty repos.
- `mcrepo pull --ff-only` is the conservative pull: fast-forward only, dirty sub-repos are skipped (fetch only); never stashes or rebases.
- `mcrepo pull --reset` discards all local changes and resets to origin state. Destructive — requires interactive confirmation.
- `mcrepo push` pushes all write-mode repos with committed changes to origin.
- `mcrepo push -m "message"` commits uncommitted changes in all dirty write-mode repos with the given message, then pushes.
- `+-skills/` stores project and company specific agent skills.
- Skills can include colocated helper scripts (for example `run.sh` or `check.sh`) next to `skill.md`.
- ClawHub URL installs are scanned by default; `CRITICAL` blocks install and `HIGH` warns.

## Human Workflow

- Commits, pull requests, and merges are done per repository.
- Cross-repo changes should start by checking `+-contracts/` and `+-docs/`.
EOF
}

create_agents_template() {
  cat >AGENTS.md <<'EOF'
## MC-Repo Context

This repository is a Multi-Context-Repo (MC-Repo) that groups multiple independent repositories for coordinated work.
Always read the mcrepo.yaml first under "repos" you find the list of all repositories their "localpath", "mode" and "description".

## Proactive Tooling

- When RepoMapper MCP is available, use `repo_map` at the start of work on large or unfamiliar repositories to get a ranked structural overview before planning changes.
- When RepoMapper MCP is available, use `search_identifiers` for symbol-aware code search so definitions and references stay easy to distinguish.
- When browser automation is available, use Playwright proactively for browser-based validation, end-to-end checks, and UI verification on web-facing changes.

# Agent Rules for this Multi-Context Repo

**STRICT MODE ENFORCEMENT (MANDATORY)**

1. Before any work, read `mcrepo.yaml` and verify repo access by **both** fields:
   - `mode` value
   - clean repo folder in `localpath` (no mode/emoji prefix)
2. Edit **only** repositories marked `mode: write`.
3. Treat repositories marked `mode: read` as strictly read-only (never modify files there).
4. Treat repositories marked `mode: sleep` as strictly inactive: do not implement, do not research inside them, do not include them in active scope.
5. For cross-repo changes, check `+-contracts/` and `+-docs/` first.
6. Coordinate changes across all `write` repositories.
7. Do not run `git commit`, `git push`, or `mcrepo commit` yourself. When a meaningful step of a feature or fix is reached — or at the start of a new plan/session when uncommitted changes already exist in write repos — tell the user to run `mcrepo commit -m "<short summary>"` so the working state is captured as a coordinated, revertable checkpoint. Leave the final decision with the user.
8. Always wrap paths in quotes to handle spaces correctly.

## Branch Coordination and Merging

- `mcrepo.yaml` tracks the active global `branch:` and per-repo `parent:` stacks.
- `parent:` is a comma-separated stack (rightmost = immediate parent, e.g. `main,feature`).
- `meta-parent:` tracks the meta-context repo's own parent branch stack.
- Never modify `branch:`, `parent:`, or `meta-parent:` fields directly — use `mcrepo branch`, `mcrepo rebase`, `mcrepo merge`, and `mcrepo branch --delete` commands.
- The merge-back flow is strictly two-step: `mcrepo rebase` first (rebases the branch onto its parent; conflicts are resolved here), then `mcrepo merge` (always conflict-free after a clean sync).
- `mcrepo branch <name>` distinguishes fork (new branch, records parent) from jump (existing branch, no parent change).
- `mcrepo branch --delete` discards the global branch and reverts repos to their parent branches.
- `mcrepo branch --off` is a fallback that turns off coordination without switching branches.
- `mcrepo pull` is the origin-side twin of `mcrepo rebase`: auto-stash + rebase local commits onto origin — the standard move when work from another device is on the remote; conflicts pause for `mcrepo continue`. Use `mcrepo pull --ff-only` for a conservative pull (fast-forward only, dirty sub-repos skipped). After `mcrepo rebase`, a coordinated branch can't fast-forward because the rebase rewrote its hashes; pull recognizes this and tells you to run `mcrepo push` instead of rebasing onto the stale remote.
- `mcrepo push [-m "message"]` pushes write-mode repos. With `-m`, also commits uncommitted changes first (same coordinated-commit format as `mcrepo commit`). Branches that were only rebased onto their parent (diverged from a stale remote, but provably your own rebase) are auto-published with `--force-with-lease` after a fresh fetch; pass `--no-force` to disable. Genuinely diverged branches (remote contains other work) are never force-pushed — mcrepo refuses and prints a paste-ready prompt for a local coding agent to resolve.
- When `branch:` is empty, branch coordination is off and repos manage branches independently.
- When running non-interactively (e.g., from scripts or agents), `mcrepo branch` aborts if uncommitted changes exist. Ensure clean working trees before switching branches.

## Conflict Recovery

When a coordinated operation (`mcrepo rebase`, `merge`, `pull`, `push`, `branch`) stops on
conflicts, follow this procedure instead of improvising:

1. Diagnose with `./mcrepo.sh status`: look for `inprogress=REBASING/MERGING/CONFLICTED`
   and unexpected `mcrepo-stash=N`. Then run `./mcrepo.sh resolve` — it prints the
   situation-specific recovery procedure; treat that output as the authoritative instructions.
2. Resolve ONLY real semantic conflicts inside the conflict markers. Where both sides differ
   purely in formatting/whitespace, keep the parent branch's formatting and preserve both
   sides' substantive changes. Never reformat or "clean up" code outside conflict markers.
3. Conflicting commits are often mcrepo coordination commits (`mcrepo commit #N @<batch>`)
   present in both old and rebased form — never keep both; the target is the real feature
   work on top of the latest parent branch.
4. Finish with `git add` on resolved files, then `./mcrepo.sh continue`, repeating until
   `./mcrepo.sh status` is clean. Stash-pop conflicts have nothing to continue: resolve,
   `git add`, then `git stash drop`.
5. Never run `git push --force`, `git reset --hard`, `git rebase --skip`, or delete branches
   or stashes without the user's explicit approval. Publishing stays user-driven via
   `mcrepo push`.

## Coordinated Commits (User-Driven)

- All commits in this workspace must go through `mcrepo commit`. The agent does not run this itself — it suggests the user run it.
- Suggest `mcrepo commit -m "<short summary>"` when:
  - a meaningful step of a feature or fix is done (so it can serve as a rollback point), or
  - starting a new plan/session with pre-existing uncommitted changes (so the starting state is captured).
- Coordinated commits use a single shared subject across every write repo and the meta-context: `mcrepo commit #<N> @<timestamp>: <message>`. This makes them revertable as one unit.
- To undo the most recent coordinated commit, the user runs `mcrepo commit --revert`. It peels only the top layer: only repos whose HEAD carries the highest `#N` are reset (`git reset --hard HEAD~1`); repos at a lower `#N` or not at a coordinated HEAD are left alone.
- To discard uncommitted work across all write repos, the user runs `mcrepo commit --reset` (destructive, user-confirmed).
- Never invoke `git commit`, `git push`, or `git reset --hard` on behalf of the user.

## Ordering and Shared Folders

- Keep managed repositories and shared folders as separate top-level entries.
- Do not create or rely on a visual separator directory.

## Skills Loading

1. Enforce `mcrepo.yaml` mode gates first.
2. Load active skills from `+-skills/`:
   - If `+-skills/skills.yaml` exists, use its enable/disable lists.
   - If no config exists, treat each `+-skills/<id>/skill.md` as active by default.
3. `+-skills/` is the workspace source of truth and is mirrored to `.opencode/skills/` for OpenCode auto-discovery.
4. For sub-repo write/change tasks, apply `subproject-skill-loader` and load repo-local skills only for repos in write scope.
5. For each active skill, read `skill.md` first and run colocated helper scripts only when needed.

## Local Project Instructions

When working inside a project repository, also read and follow local instruction files if present:
- `AGENTS.md`
- `CLAUDE.md`
EOF
}

create_skills_config_template() {
  cat >"$SKILLS_CONFIG_FILE" <<'EOF'
# Optional workspace governance for skill activation.
# If this file is missing, all discovered skills are treated as active.
enabled:
  - change-implementation
  - test-gate
  - release-prep
  - no-secrets
  - conflict-resolution
  - subproject-skill-loader
disabled: []
EOF
}

create_skill_template_file() {
  mkdir -p "$SUPPORT_SKILLS_DIR/_templates"
  cat >"$SUPPORT_SKILLS_DIR/_templates/skill-template.md" <<'EOF'
# <skill-id>

## Purpose
One short sentence describing what this skill optimizes for.

## When to Apply
- Trigger condition 1
- Trigger condition 2

## Inputs
- Expected context/files/repositories.

## Procedure
1. Step one.
2. Step two.
3. Validation step.

## Guardrails
- Respect `mcrepo.yaml` mode restrictions.
- Do not write outside `mode: write` repositories.
- Never commit unless explicitly requested.

## Optional Helpers
- `run.sh`: execution helper
- `check.sh`: validation helper
EOF
}

create_default_skill_pack() {
  mkdir -p "$SUPPORT_SKILLS_DIR/change-implementation"
  cat >"$SUPPORT_SKILLS_DIR/change-implementation/skill.md" <<'EOF'
# change-implementation

## Purpose
Coordinate cross-repo feature changes with explicit contract and docs checks.

## When to Apply
- A task touches two or more repositories.
- A change modifies an API, interface, or integration point.

## Procedure
1. Read `mcrepo.yaml` and identify writable repositories.
2. Check `+-contracts/` and `+-docs/` for existing agreements.
3. Implement only in writable repositories.
4. Update contracts/docs if behavior changes.
5. Validate repository-level tests before finishing.
EOF

  mkdir -p "$SUPPORT_SKILLS_DIR/test-gate"
  cat >"$SUPPORT_SKILLS_DIR/test-gate/skill.md" <<'EOF'
# test-gate

## Purpose
Ensure every change includes practical validation before handoff.

## When to Apply
- Any code or configuration change.

## Procedure
1. Run relevant tests in affected repositories.
2. For web-facing changes, run browser or end-to-end checks with Playwright when available.
3. Run fast syntax/lint checks where available.
4. Capture failures with actionable next steps.
5. Report what was run and what could not be run.
EOF

  mkdir -p "$SUPPORT_SKILLS_DIR/release-prep"
  cat >"$SUPPORT_SKILLS_DIR/release-prep/skill.md" <<'EOF'
# release-prep

## Purpose
Prepare multi-repo release work while preserving per-repo autonomy.

## When to Apply
- A feature is ready for release coordination.

## Procedure
1. Confirm target branch alignment.
2. Verify each affected repo has clear release notes inputs.
3. Check version bumps and changelog conventions per repository.
4. List repo-by-repo release order and dependencies.
EOF

  mkdir -p "$SUPPORT_SKILLS_DIR/no-secrets"
  cat >"$SUPPORT_SKILLS_DIR/no-secrets/skill.md" <<'EOF'
# no-secrets

## Purpose
Prevent accidental exposure of credentials and private tokens.

## When to Apply
- Any edit touching config, environment files, CI, or docs.

## Procedure
1. Avoid committing `.env` and credential files.
2. Use placeholder values in examples.
3. Keep secret names documented, not secret values.
4. Flag potential leaks immediately.
EOF

  create_conflict_resolution_skill

  mkdir -p "$SUPPORT_SKILLS_DIR/subproject-skill-loader"
  cat >"$SUPPORT_SKILLS_DIR/subproject-skill-loader/skill.md" <<'EOF'
# subproject-skill-loader

## Purpose
Load sub-repo local skills only when that sub-repo is in write/change scope.

## When to Apply
- A task edits, generates, or fixes code/config/docs in a managed sub-repository.

## Procedure
1. Read `mcrepo.yaml` and enforce mode gates first.
2. Identify sub-repositories in write/change scope.
3. For each write-scope repo, discover local skills in this order:
   - `.opencode/skills/*/SKILL.md`
   - `.agents/skills/*/SKILL.md`
   - `.claude/skills/*/SKILL.md`
   - `skills/*/SKILL.md` (optional repo-local fallback)
4. Load and apply only those repo-local skills needed for the current write task.
5. Do not load repo-local skills for read-only context scans.
6. Report which repo-local skills were loaded and which repos were skipped.

## Guardrails
- Never bypass `mcrepo.yaml` mode restrictions.
- Workspace governance and safety skills always win in conflicts.
- Repo-local skills can refine workflow details only inside their own repo scope.
EOF
}

# Kept as its own function so cmd_post_update_migrate can backfill just this
# skill into workspaces created before it existed.
create_conflict_resolution_skill() {
  mkdir -p "$SUPPORT_SKILLS_DIR/conflict-resolution"
  cat >"$SUPPORT_SKILLS_DIR/conflict-resolution/skill.md" <<'EOF'
# conflict-resolution

## Purpose
Recover coordinated multi-repo git operations from conflicts without losing work.

## When to Apply
- `mcrepo status` shows `inprogress=REBASING/MERGING/CONFLICTED` or an unexpected `mcrepo-stash=N`.
- An mcrepo command printed a paste-ready recovery prompt, or the user pastes one.
- A coordinated `rebase`, `merge`, `pull`, `push`, or `branch` stopped on conflicts.

## Procedure
1. Run `./mcrepo.sh resolve` and treat its output as the authoritative, situation-specific
   instructions. Orient with `./mcrepo.sh status` and per-repo `git status` before changing anything.
2. Resolve ONLY real semantic conflicts. On formatting-only collisions, keep the parent side's
   formatting and preserve both sides' substantive changes. Never reformat outside conflict markers.
3. Watch for duplicated `mcrepo commit #N @<batch>` coordination commits (old + rebased form) —
   never keep both; the target state is the real feature work on top of the latest parent.
4. Finish per situation: `git add` resolved files, then `./mcrepo.sh continue` (paused rebase/merge)
   or `git stash drop` (stash-pop conflict), until `./mcrepo.sh status` is clean.

## Guardrails
- Never `git push --force`, `git reset --hard`, `git rebase --skip`, or delete branches/stashes
  without explicit user approval; publishing stays user-driven via `mcrepo push`.
- Commit only to complete a paused operation or a repair commit the recovery instructions name
  verbatim; new feature commits stay user-driven.
- Respect `mcrepo.yaml` mode gates at all times.
EOF
}

ensure_skills_files() {
  mkdir -p "$SUPPORT_SKILLS_DIR"
  [ -f "$SKILLS_CONFIG_FILE" ] || create_skills_config_template
  [ -f "$SUPPORT_SKILLS_DIR/_templates/skill-template.md" ] || create_skill_template_file

  local existing_skills=0
  local dir
  shopt -s nullglob
  for dir in "$SUPPORT_SKILLS_DIR"/*; do
    [ -d "$dir" ] || continue
    [ "$(basename "$dir")" = "_templates" ] && continue
    if [ -f "$dir/skill.md" ]; then
      existing_skills=1
      break
    fi
  done
  shopt -u nullglob

  if [ "$existing_skills" -eq 0 ]; then
    create_default_skill_pack
  fi

  sync_workspace_skills_to_opencode
}

create_gitignore_template() {
  : >.gitignore
}

create_repos_template() {
  printf 'repos: []\n' >"$REPOS_FILE"
}

ensure_vscode_workspace_settings() {
  local vscode_dir=".vscode"
  local vscode_settings_file="$vscode_dir/settings.json"

  if [ -f "$vscode_settings_file" ]; then
    log "VS Code workspace settings already exist: $vscode_settings_file"
    log "To reset to MC-Repo defaults, delete this file and run init again."
    return 0
  fi

  if [ -e "$vscode_settings_file" ] && [ ! -f "$vscode_settings_file" ]; then
    warn "Cannot write VS Code settings because path exists and is not a file: $vscode_settings_file"
    return 0
  fi

  mkdir -p "$vscode_dir"
  cat >"$vscode_settings_file" <<'EOF'
{
  "scm.alwaysShowRepositories": true,
  "scm.repositories.selectionMode": "multiple",
  "git.autoRepositoryDetection": "subFolders",
  "git.repositoryScanMaxDepth": 2
}
EOF

  log "Created VS Code workspace settings: $vscode_settings_file"
}

MCREPO_VSIX_URL="https://raw.githubusercontent.com/GeektankLabs/mcrepo/main/vsc-plugin/mcrepo.vsix"

_find_code_cli() {
  if command -v code >/dev/null 2>&1; then
    echo "code"
    return 0
  fi
  # Common macOS fallback when 'code' is not on PATH
  local mac_code="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  if [ -x "$mac_code" ]; then
    echo "$mac_code"
    return 0
  fi
  return 1
}

install_vscode_extension() {
  local silent="${1:-0}"  # pass "1" to suppress non-error output during init
  if is_truthy "${MCREPO_SKIP_VSCODE:-}"; then
    [ "$silent" -eq 0 ] && log "Skipped VS Code extension install (MCREPO_SKIP_VSCODE=1)."
    return 0
  fi
  local code_cmd
  if ! code_cmd="$(_find_code_cli)"; then
    if [ "$silent" -eq 0 ]; then
      warn "VS Code CLI 'code' not found — skipping extension install."
      warn "Open VS Code and run: Shell Command: Install 'code' command in PATH"
      warn "Then re-run: mcrepo install-extension"
    fi
    return 0
  fi

  local tmp_vsix
  tmp_vsix="$(mktemp /tmp/mcrepo-XXXXXX.vsix)"

  local vsix_url
  vsix_url="${MCREPO_VSIX_URL}?_=$(date +%s)"
  log "Downloading mcrepo VS Code extension..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$vsix_url" -o "$tmp_vsix" || { warn "Download failed."; rm -f "$tmp_vsix"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_vsix" "$vsix_url" || { warn "Download failed."; rm -f "$tmp_vsix"; return 1; }
  else
    warn "Neither curl nor wget found — cannot download extension."
    rm -f "$tmp_vsix"
    return 1
  fi

  log "Installing mcrepo VS Code extension..."
  if "$code_cmd" --install-extension "$tmp_vsix" --force >/dev/null 2>&1; then
    log "VS Code extension installed successfully."
    log "To activate: reload the VS Code window (Cmd+Shift+P → 'Reload Window')."
  else
    warn "Extension install failed. You can install it manually:"
    warn "  \"$code_cmd\" --install-extension $tmp_vsix"
  fi
  rm -f "$tmp_vsix"
}

cmd_install_extension() {
  install_vscode_extension 0
}

maybe_reload_vscode_window() {
  if is_truthy "${MCREPO_SKIP_VSCODE:-}"; then
    return 0
  fi
  if command -v code >/dev/null 2>&1; then
    if code --reuse-window --command workbench.action.reloadWindow >/dev/null 2>&1; then
      log "Triggered VS Code window reload via CLI command."
      return 0
    fi
  fi

  log "If VS Code does not reflect SCM settings yet, reload the window (Cmd/Ctrl+Shift+P -> Reload Window) or restart VS Code."
}

sync_vscode_git_ignored_repositories() {
  local vscode_dir=".vscode"
  local vscode_settings_file="$vscode_dir/settings.json"
  local -a sleep_repos=()
  local i

  for i in "${!REPO_NAMES[@]}"; do
    if [ "${REPO_MODES[$i]}" = "sleep" ]; then
      sleep_repos+=("${REPO_NAMES[$i]}")
    fi
  done

  mkdir -p "$vscode_dir"
  [ -f "$vscode_settings_file" ] || printf '{}\n' >"$vscode_settings_file"

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; could not sync VS Code git.ignoredRepositories for sleeping repos."
    return 0
  fi

  local py_rc=0
  python3 - "$vscode_settings_file" "${sleep_repos[@]-}" <<'PY' || py_rc=$?
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
current_sleep = [item for item in sys.argv[2:] if item]
managed_key = "mcrepo.sleepRepositories"

try:
    raw = settings_path.read_text(encoding="utf-8")
except FileNotFoundError:
    raw = "{}"

try:
    data = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    # VS Code settings.json is JSONC — comments/trailing commas are valid for
    # VS Code but not for json.loads. NEVER fall back to {} and rewrite: that
    # silently wipes every user setting. Leave the file untouched instead.
    sys.exit(3)

if not isinstance(data, dict):
    sys.exit(3)

previous_managed = data.get(managed_key)
if not isinstance(previous_managed, list):
    previous_managed = []
previous_managed = [item for item in previous_managed if isinstance(item, str)]

existing_ignored = data.get("git.ignoredRepositories")
if not isinstance(existing_ignored, list):
    existing_ignored = []
existing_ignored = [item for item in existing_ignored if isinstance(item, str)]

base_ignored = [item for item in existing_ignored if item not in previous_managed]

merged = []
for item in base_ignored + current_sleep:
    if item not in merged:
        merged.append(item)

data["git.ignoredRepositories"] = merged
data[managed_key] = current_sleep

settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY
  if [ "$py_rc" -eq 3 ]; then
    warn "$vscode_settings_file is not plain JSON (JSONC comments/trailing commas?) — left untouched; git.ignoredRepositories not synced."
    return 0
  elif [ "$py_rc" -ne 0 ]; then
    warn "Could not sync VS Code git.ignoredRepositories for sleeping repos."
    return 0
  fi

  log "Synced VS Code git.ignoredRepositories for sleeping repos."
}

directory_is_empty() {
  local dir="$1"
  local entries=()
  shopt -s nullglob dotglob
  entries=("$dir"/*)
  shopt -u nullglob dotglob
  [ "${#entries[@]}" -eq 0 ]
}

# Scan a git working copy for local work that would be lost if the folder
# were deleted (used by 'remove' and 'sleep' before destroying contents).
# Fills the global LOCAL_WORK_CONCERNS array with one line per concern.
LOCAL_WORK_CONCERNS=()
scan_local_work_concerns() {
  local repo_dir="$1"
  LOCAL_WORK_CONCERNS=()
  [ -n "$repo_dir" ] && [ -d "$repo_dir/.git" ] || return 0

  if [ -n "$(git -C "$repo_dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    LOCAL_WORK_CONCERNS+=("uncommitted changes")
  fi
  if [ -n "$(git -C "$repo_dir" ls-files --others --exclude-standard 2>/dev/null)" ]; then
    LOCAL_WORK_CONCERNS+=("untracked files")
  fi
  # Commits on ANY local branch that no remote ref contains — not just the
  # current branch's @{u}..HEAD, which misses other local branches entirely.
  if [ -n "$(git -C "$repo_dir" log --branches --not --remotes --oneline -1 2>/dev/null)" ]; then
    LOCAL_WORK_CONCERNS+=("unpushed commits (local branch work not on any remote)")
  fi
  if ! git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    local head_branch
    head_branch="$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '')"
    if [ -n "$head_branch" ]; then
      LOCAL_WORK_CONCERNS+=("no upstream configured for '$head_branch'")
    fi
  fi
  if [ -n "$(git -C "$repo_dir" stash list 2>/dev/null)" ]; then
    LOCAL_WORK_CONCERNS+=("stashed changes")
  fi
  return 0
}

ensure_base_structure() {
  mkdir -p "$SUPPORT_CONTRACTS_DIR" "$SUPPORT_DOCS_DIR" "$SUPPORT_TESTS_DIR" "$SUPPORT_SKILLS_DIR"
}

ensure_base_files() {
  [ -f .gitignore ] || create_gitignore_template
  [ -f README.md ] || create_readme_template
  [ -f AGENTS.md ] || create_agents_template
  [ -f "$REPOS_FILE" ] || create_repos_template
  ensure_skills_files
  ensure_gitignore_base
}

resolve_shell_rc_file() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh) printf '%s' "$HOME/.zshrc" ;;
    *) printf '%s' "$HOME/.bashrc" ;;
  esac
}

remove_rc_block() {
  local rc_file="$1"
  local start_marker="$2"
  local end_marker="$3"
  local tmp

  [ -f "$rc_file" ] || return 0
  tmp="$(mktemp)"
  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start { in_block = 1; next }
    $0 == end { in_block = 0; next }
    !in_block { print }
  ' "$rc_file" >"$tmp"
  mv "$tmp" "$rc_file"
}

install_shell_command() {
  local rc_file
  local shell_name
  local repo_root
  shell_name="$(basename "${SHELL:-bash}")"
  repo_root="$(pwd)"
  rc_file="$(resolve_shell_rc_file)"
  [ -f "$rc_file" ] || touch "$rc_file"

  local shell_start="# >>> mcrepo shell command >>>"
  local shell_end="# <<< mcrepo shell command <<<"
  remove_rc_block "$rc_file" "$shell_start" "$shell_end"
  {
    printf '\n%s\n' "$shell_start"
    cat <<'EOF'
mcrepo() {
  if [ -x "./mcrepo.sh" ]; then
    ./mcrepo.sh "$@"
  else
    echo "No ./mcrepo.sh found in the current directory." >&2
    return 1
  fi
}
EOF
    printf '%s\n' "$shell_end"
  } >>"$rc_file"
  log "Installed shell command in $rc_file"

  local completion_start="# >>> mcrepo completion >>>"
  local completion_end="# <<< mcrepo completion <<<"
  remove_rc_block "$rc_file" "$completion_start" "$completion_end"
  {
    printf '\n%s\n' "$completion_start"
    if [ "$shell_name" = "zsh" ]; then
      printf 'if [ -f "%s/%s" ]; then source "%s/%s"; fi\n' "$repo_root" "$COMPLETION_ZSH_FILE" "$repo_root" "$COMPLETION_ZSH_FILE"
    else
      printf 'if [ -f "%s/%s" ]; then source "%s/%s"; fi\n' "$repo_root" "$COMPLETION_BASH_FILE" "$repo_root" "$COMPLETION_BASH_FILE"
    fi
    printf '%s\n' "$completion_end"
  } >>"$rc_file"
  log "Installed completion source in $rc_file"

  log "Reload your shell or run: source $rc_file"
}

refresh_shell_integration_if_present() {
  local rc_file
  local shell_start="# >>> mcrepo shell command >>>"
  local completion_start="# >>> mcrepo completion >>>"

  rc_file="$(resolve_shell_rc_file)"
  [ -f "$rc_file" ] || return 0

  if grep -Fq "$shell_start" "$rc_file" || grep -Fq "$completion_start" "$rc_file"; then
    install_shell_command
  fi
}

apply_global_branch_to_repo_if_configured() {
  local repo_name="$1"
  local repo_dir="$2"

  [ -n "$GLOBAL_BRANCH" ] || return 0
  if [ ! -d "$repo_dir/.git" ]; then
    warn "Global branch '$GLOBAL_BRANCH' configured but repo is not available locally: $repo_name"
    return 0
  fi

  # Record parent if this is a fork (branch doesn't exist yet in this repo)
  local idx=-1
  local i
  for i in "${!REPO_NAMES[@]}"; do
    if [ "${REPO_NAMES[$i]}" = "$repo_name" ]; then idx=$i; break; fi
  done
  if [ "$idx" -ge 0 ]; then
    if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$GLOBAL_BRANCH" && \
       ! git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$GLOBAL_BRANCH"; then
      local current_branch
      current_branch="$(repo_branch "$repo_dir")"
      if [ -n "${REPO_PARENTS[$idx]:-}" ]; then
        REPO_PARENTS[$idx]="${REPO_PARENTS[$idx]},$current_branch"
      else
        REPO_PARENTS[$idx]="$current_branch"
      fi
      save_repos
    fi
  fi

  switch_repo_branch "$repo_dir" "$GLOBAL_BRANCH"
  log "Aligned '$repo_name' to global branch '$GLOBAL_BRANCH'."
}

materialize_from_repos_file() {
  local i repo_dir
  for i in "${!REPO_NAMES[@]}"; do
    ensure_gitignore_repo_entry "${REPO_NAMES[$i]}"
    repo_dir="$(ensure_repo_dir_mode "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    if [ "${REPO_MODES[$i]}" = "write" ] || [ "${REPO_MODES[$i]}" = "read" ]; then
      if ! clone_repo_if_needed "$repo_dir" "${REPO_URLS[$i]}" "${REPO_MODES[$i]}"; then
        warn "Could not materialize repo: ${REPO_NAMES[$i]}"
      fi
      if [ "${REPO_MODES[$i]}" = "write" ]; then
        apply_global_branch_to_repo_if_configured "${REPO_NAMES[$i]}" "$repo_dir"
      fi
    elif [ "${REPO_MODES[$i]}" = "sleep" ]; then
      mkdir -p "$repo_dir"
    fi
  done
}

cmd_init() {
  local org_arg=""
  local no_shell_install=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-shell-install)
        no_shell_install=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown init option: $1"
        ;;
      *)
        if [ -n "$org_arg" ]; then
          die "Usage: ./mcrepo.sh init [organization] [--no-shell-install]"
        fi
        org_arg="$1"
        ;;
    esac
    shift
  done

  [ "$#" -eq 0 ] || die "Usage: ./mcrepo.sh init [organization] [--no-shell-install]"

  case "${MCREPO_NO_SHELL_INSTALL:-0}" in
    1|true|TRUE|yes|YES)
      no_shell_install=1
      ;;
  esac

  ensure_base_structure
  ensure_base_files
  ensure_vscode_workspace_settings
  load_repos

  if [ -n "$org_arg" ]; then
    ORGANIZATION="$org_arg"
  fi

  if [ -n "$ORGANIZATION" ]; then
    sync_organization_repos "$ORGANIZATION"
  fi

  save_repos
  materialize_from_repos_file
  refresh_generated_files
  sync_vscode_git_ignored_repositories

  if [ "$no_shell_install" -eq 1 ]; then
    log "Skipped shell command installation (--no-shell-install or MCREPO_NO_SHELL_INSTALL=1)."
  else
    install_shell_command
  fi

  # optional nicety: never let a failed download abort init under set -e
  install_vscode_extension 1 || warn "VS Code extension install skipped (download failed). Retry later with: mcrepo install-extension"
  maybe_reload_vscode_window

  log "Multi-Context repo initialized."
  if [ "${#REPO_NAMES[@]}" -eq 0 ]; then
    log "No repos configured yet."
    log "Next steps - add all relevant repostories:"
    log "  ./mcrepo.sh add <git-url>"
  fi
}

# Create a fork of <owner/repo> via gh (idempotent) and print the fork clone URL.
# Returns 1 if gh is not ready / login unknown.
gh_create_fork() {
  local slug="$1"
  gh_ready || return 1
  local login; login="$(gh_login)"
  [ -n "$login" ] || return 1
  # gh repo fork is idempotent: it reports "already exists" and exits 0.
  gh repo fork "$slug" --clone=false >/dev/null 2>&1 || true
  local repo="${slug#*/}"
  printf 'https://github.com/%s/%s.git' "$login" "$repo"
}

# Append a repo entry (origin + optional upstream), clone origin, wire the
# 'upstream' git remote, persist. Used by cmd_add / cmd_fork.
# Args: origin_url name mode upstream_url do_clone(0/1)
register_repo_entry() {
  local o_url="$1" name="$2" mode="$3" up_url="$4" do_clone="$5"
  REPO_URLS+=("$o_url")
  REPO_NAMES+=("$name")
  REPO_MODES+=("$mode")
  REPO_DESCRIPTIONS+=("")
  REPO_PARENTS+=("")
  REPO_LOCALS+=("false")
  REPO_UPSTREAMS+=("$up_url")
  save_repos

  ensure_gitignore_repo_entry "$name"
  local repo_dir
  repo_dir="$(ensure_repo_dir_mode "$name" "$mode")"
  if [ "$do_clone" -eq 1 ] && [ -n "$o_url" ]; then
    if ! clone_repo_if_needed "$repo_dir" "$o_url" "$mode"; then
      warn "Repo added, but clone failed for '$name'"
    fi
  fi
  if [ -n "$up_url" ] && [ -d "$repo_dir/.git" ]; then
    ensure_upstream_remote "$repo_dir" "$up_url"
    git -C "$repo_dir" fetch upstream --quiet 2>/dev/null || true
  fi
  refresh_generated_files
  sync_vscode_git_ignored_repositories
}

cmd_add() {
  local url="" name="" mode="read"
  local role="" flag_upstream="" flag_origin="" do_fork=0 do_clone=1 assume_yes=0 mode_set=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --as-origin)   role="origin" ;;
      --as-upstream) role="upstream" ;;
      --upstream)    shift; flag_upstream="${1:-}"; [ -n "$flag_upstream" ] || die "--upstream requires a URL" ;;
      --origin)      shift; flag_origin="${1:-}"; [ -n "$flag_origin" ] || die "--origin requires a URL" ;;
      --mode)        shift; mode="${1:-}"; mode_set=1; validate_mode "$mode" || die "--mode must be read|write|sleep" ;;
      --fork)        do_fork=1 ;;
      --no-clone)    do_clone=0 ;;
      --yes|-y)      assume_yes=1 ;;
      -*)            die "Unknown add option: $1" ;;
      *)
        if [ -z "$url" ]; then url="$1"
        elif [ -z "$name" ]; then name="$1"
        else die "Usage: ./mcrepo.sh add <git-url> [name] [options]"
        fi
        ;;
    esac
    shift
  done
  [ -n "$url" ] || die "Usage: ./mcrepo.sh add <git-url> [name] [options]"

  load_repos

  # Resolve the final origin/upstream URLs and mode.
  local final_origin="" final_upstream=""

  if [ -n "$role" ] || [ "$assume_yes" -eq 1 ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    # --- Non-interactive / flag-driven path ---
    case "${role:-origin}" in
      upstream)
        final_upstream="$url"
        if [ "$do_fork" -eq 1 ]; then
          url_is_github "$url" || die "--fork requires a github.com URL"
          gh_ready || die "--fork needs GitHub CLI. Install gh and run 'gh auth login' (see 'mcrepo doctor')."
          parse_git_url "$url" >/dev/null
          final_origin="$(gh_create_fork "$GU_OWNER/$GU_REPO")" || die "Fork via gh failed."
          [ "$mode_set" -eq 1 ] || mode="write"
        else
          final_origin="$flag_origin"
        fi
        ;;
      *) # origin
        final_origin="$url"
        final_upstream="$flag_upstream"
        ;;
    esac
  else
    # --- Interactive analysis + menu ---
    log "Analyzing $url ..."
    local is_gh=0 perm="" isfork="" parent="" defbranch="" canpush="unknown"
    if url_is_github "$url"; then
      is_gh=1
      parse_git_url "$url" >/dev/null
      if gh_ready; then
        local info; info="$(gh_repo_info "$GU_OWNER/$GU_REPO" || true)"
        if [ -n "$info" ]; then
          # shellcheck disable=SC2034  # defbranch is the 4th tab field; not used here
          IFS=$'\t' read -r perm isfork parent defbranch <<<"$info"
          if gh_perm_can_push "$perm"; then canpush="yes"; else canpush="no"; fi
        fi
      fi
    fi

    if [ "$is_gh" -eq 1 ] && [ -n "$perm" ]; then
      log "  GitHub repo $GU_OWNER/$GU_REPO — your access: $perm$([ "$isfork" = "true" ] && printf ' (is a fork of %s)' "$parent")"
    elif [ "$is_gh" -eq 1 ]; then
      log "  GitHub repo $GU_OWNER/$GU_REPO — access unknown (gh not authenticated; run 'gh auth login' for richer detection)."
    else
      log "  Non-GitHub or unparsable URL — GitHub features (fork/PR/access-check) unavailable."
    fi

    printf 'How do you want to add this repo?\n' >&2
    printf '  [o] origin       — you push here directly (your own repo / you have write access)\n' >&2
    if [ "$is_gh" -eq 1 ] && gh_ready; then
      printf '  [f] upstream+fork — fork it to your account now; PRs go fork -> this repo\n' >&2
      printf '  [e] upstream+existing fork — you already forked it; provide/auto-detect your fork\n' >&2
    fi
    printf '  [u] upstream only — record as PR target; wire your origin/fork later\n' >&2
    printf '  [r] read-only     — just track it, no push/PR intended\n' >&2
    local default_choice="o"
    [ "$canpush" = "no" ] && default_choice="f"
    printf 'Choice [o/f/e/u/r] (default %s): ' "$default_choice" >&2
    local choice; IFS= read -r choice
    [ -n "$choice" ] || choice="$default_choice"

    case "$choice" in
      o|O)
        final_origin="$url"; final_upstream="$flag_upstream"
        ;;
      f|F)
        [ "$is_gh" -eq 1 ] && gh_ready || die "Fork needs a github.com URL and an authenticated gh (see 'mcrepo doctor')."
        final_upstream="$url"
        final_origin="$(gh_create_fork "$GU_OWNER/$GU_REPO")" || die "Fork via gh failed."
        log "  Forked -> $final_origin"
        [ "$mode_set" -eq 1 ] || mode="write"
        ;;
      e|E)
        final_upstream="$url"
        local login fork_try=""
        login="$(gh_login)"
        if [ -n "$login" ] && gh_repo_info "$login/$GU_REPO" >/dev/null 2>&1; then
          fork_try="https://github.com/$login/$GU_REPO.git"
          log "  Detected existing fork: $fork_try"
        fi
        if [ -n "$flag_origin" ]; then
          final_origin="$flag_origin"
        elif [ -n "$fork_try" ]; then
          final_origin="$fork_try"
        else
          printf 'Enter your fork (origin) URL: ' >&2
          IFS= read -r final_origin
          [ -n "$final_origin" ] || die "No fork URL provided."
        fi
        [ "$mode_set" -eq 1 ] || mode="write"
        ;;
      u|U)
        final_upstream="$url"; final_origin="$flag_origin"
        [ "$mode_set" -eq 1 ] || mode="write"
        ;;
      r|R)
        final_origin="$url"; final_upstream=""; mode="read"
        ;;
      *)
        die "Unknown choice '$choice'. Aborting."
        ;;
    esac
  fi

  # Derive a name from the most specific URL we have.
  if [ -z "$name" ]; then
    name="$(derive_name_from_url "${final_origin:-$final_upstream}")"
  fi
  [ -n "$name" ] || die "Could not derive repository name"

  if [ -n "$final_origin" ] && ! validate_repo_url "$final_origin"; then
    die "Unsupported or unsafe origin URL: '$final_origin' (allowed: https, ssh, git, file, local path, scp-style)."
  fi
  if [ -n "$final_upstream" ] && ! validate_repo_url "$final_upstream"; then
    die "Unsupported or unsafe upstream URL: '$final_upstream' (allowed: https, ssh, git, file, local path, scp-style)."
  fi

  # Duplicate checks.
  if [ -n "$final_origin" ] && find_repo_index "$final_origin" >/dev/null 2>&1; then
    die "Repository URL already exists in $REPOS_FILE"
  fi
  if find_repo_index "$name" >/dev/null 2>&1; then
    die "Repository name already exists in $REPOS_FILE"
  fi

  register_repo_entry "$final_origin" "$name" "$mode" "$final_upstream" "$do_clone"

  local summary="origin=${final_origin:-<none>}"
  [ -n "$final_upstream" ] && summary="$summary upstream=$final_upstream"
  log "Added repo '$name' in mode '$mode' ($summary)."
  print_description_update_prompt
}

# Manage the per-repo upstream (PR target) relationship.
#   mcrepo upstream                       # list origin/upstream per repo
#   mcrepo upstream <repo> <url>          # set/replace upstream
#   mcrepo upstream <repo> --off          # remove upstream
#   mcrepo upstream <repo> --origin <url> # set origin for an upstream-only entry
cmd_upstream() {
  load_repos

  if [ "$#" -eq 0 ]; then
    if [ "${#REPO_NAMES[@]}" -eq 0 ]; then
      log "No repositories configured."
      return 0
    fi
    log "Repo origin/upstream:"
    local i
    for i in "${!REPO_NAMES[@]}"; do
      printf '  %-20s origin=%-45s upstream=%s\n' \
        "${REPO_NAMES[$i]}" "${REPO_URLS[$i]:-<none>}" "${REPO_UPSTREAMS[$i]:-<none>}"
    done
    return 0
  fi

  local repo="$1"; shift
  local idx; idx="$(find_repo_index "$repo")" || die "Repo not found: $repo"

  local new_upstream="" set_off=0 new_origin="" have_upstream=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --off) set_off=1 ;;
      --origin) shift; new_origin="${1:-}"; [ -n "$new_origin" ] || die "--origin requires a URL" ;;
      -*) die "Unknown upstream option: $1" ;;
      *) new_upstream="$1"; have_upstream=1 ;;
    esac
    shift
  done

  local repo_dir; repo_dir="$(get_repo_dir "${REPO_NAMES[$idx]}" "${REPO_MODES[$idx]}")"

  if [ -n "$new_origin" ]; then
    REPO_URLS[$idx]="$new_origin"
    log "Set origin for '${REPO_NAMES[$idx]}' -> $new_origin"
  fi

  if [ "$set_off" -eq 1 ]; then
    REPO_UPSTREAMS[$idx]=""
    [ -d "$repo_dir/.git" ] && git -C "$repo_dir" remote remove upstream 2>/dev/null || true
    log "Removed upstream from '${REPO_NAMES[$idx]}'."
  elif [ "$have_upstream" -eq 1 ]; then
    REPO_UPSTREAMS[$idx]="$new_upstream"
    if [ -d "$repo_dir/.git" ]; then
      ensure_upstream_remote "$repo_dir" "$new_upstream"
      git -C "$repo_dir" fetch upstream --quiet 2>/dev/null || true
    fi
    log "Set upstream for '${REPO_NAMES[$idx]}' -> $new_upstream"
  elif [ -z "$new_origin" ]; then
    die "Usage: mcrepo upstream <repo> <url> | --off | --origin <url>"
  fi

  save_repos
}

# Fork the current origin of repo <idx> and rewire: origin=fork, upstream=original
# (in mcrepo.yaml arrays AND the clone's git remotes). Does NOT call save_repos — the
# caller persists (so bulk runs save once). Returns 1 if it cannot fork.
fork_and_rewire_repo() {
  local idx="$1"
  local orig_url="${REPO_URLS[$idx]:-}"
  [ -n "$orig_url" ] || { warn "'${REPO_NAMES[$idx]}': no origin URL to fork."; return 1; }
  url_is_github "$orig_url" || { warn "'${REPO_NAMES[$idx]}': origin is not a github.com URL."; return 1; }
  parse_git_url "$orig_url" >/dev/null
  local fork_url; fork_url="$(gh_create_fork "$GU_OWNER/$GU_REPO")" || { warn "'${REPO_NAMES[$idx]}': fork via gh failed."; return 1; }
  REPO_UPSTREAMS[$idx]="$orig_url"
  REPO_URLS[$idx]="$fork_url"
  local repo_dir; repo_dir="$(get_repo_dir "${REPO_NAMES[$idx]}" "${REPO_MODES[$idx]}")"
  if [ -d "$repo_dir/.git" ]; then
    git -C "$repo_dir" remote set-url origin "$fork_url" 2>/dev/null || true
    ensure_upstream_remote "$repo_dir" "$orig_url"
    git -C "$repo_dir" fetch --all --prune --quiet 2>/dev/null || true
  fi
  log "Rewired '${REPO_NAMES[$idx]}': origin=$fork_url upstream=$orig_url"
}

# Fork the meta-repo's current origin and rewire: origin=fork (git remote),
# upstream=original (git remote + META_UPSTREAM). Caller persists via save_repos.
fork_and_rewire_meta() {
  local orig_url; orig_url="$(git -C . remote get-url origin 2>/dev/null || true)"
  [ -n "$orig_url" ] || { warn "(meta-context): no origin remote to fork."; return 1; }
  url_is_github "$orig_url" || { warn "(meta-context): origin is not a github.com URL."; return 1; }
  parse_git_url "$orig_url" >/dev/null
  local fork_url; fork_url="$(gh_create_fork "$GU_OWNER/$GU_REPO")" || { warn "(meta-context): fork via gh failed."; return 1; }
  git -C . remote set-url origin "$fork_url" 2>/dev/null || true
  ensure_upstream_remote "." "$orig_url"
  git -C . fetch --all --prune --quiet 2>/dev/null || true
  META_UPSTREAM="$orig_url"
  log "Rewired (meta-context): origin=$fork_url upstream=$orig_url"
}

# Fork repos and wire origin=fork, upstream=original.
#   mcrepo fork <repo-name>        # fork an existing entry's origin
#   mcrepo fork <git-url> [name]   # add a new entry from a fork
#   mcrepo fork --all [--yes]      # fork every repo (incl. meta) lacking push access
cmd_fork() {
  local do_all=0 assume_yes=0
  local -a pos=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all) do_all=1 ;;
      --yes|-y) assume_yes=1 ;;
      -*) die "Unknown fork option: $1" ;;
      *) pos+=("$1") ;;
    esac
    shift
  done

  gh_ready || die "fork needs GitHub CLI. Install gh and run 'gh auth login' (see 'mcrepo doctor')."
  load_repos

  if [ "$do_all" -eq 1 ]; then
    cmd_fork_all "$assume_yes"
    return $?
  fi

  [ "${#pos[@]}" -ge 1 ] || die "Usage: ./mcrepo.sh fork <repo-name-or-url> [name] | --all [--yes]"
  local target="${pos[0]}" name="${pos[1]:-}"
  local idx orig_url
  if idx="$(find_repo_index "$target" 2>/dev/null)"; then
    orig_url="${REPO_URLS[$idx]}"
    [ -n "$orig_url" ] || die "Repo '$target' has no origin URL to fork."
    fork_and_rewire_repo "$idx" || die "Fork failed for '$target'."
    save_repos
  else
    orig_url="$target"
    url_is_github "$orig_url" || die "fork requires a github.com URL (got: $orig_url)."
    parse_git_url "$orig_url" >/dev/null
    local fork_url; fork_url="$(gh_create_fork "$GU_OWNER/$GU_REPO")" || die "Fork via gh failed."
    log "Forked $GU_OWNER/$GU_REPO -> $fork_url"
    [ -n "$name" ] || name="$GU_REPO"
    find_repo_index "$name" >/dev/null 2>&1 && die "Repository name already exists: $name"
    register_repo_entry "$fork_url" "$name" "write" "$orig_url" 1
    log "Added forked repo '$name': origin=$fork_url upstream=$orig_url"
  fi
}

# Bulk: fork every repo (and the meta-repo) where you lack push access, rewiring
# origin->upstream and fork->origin. Shows a plan and asks for confirmation (TTY).
cmd_fork_all() {
  local assume_yes="${1:-0}"
  local -a to_fork_idx=() keep=() skip=()
  local meta_to_fork=0

  local i name o
  for i in "${!REPO_NAMES[@]}"; do
    name="${REPO_NAMES[$i]}"; o="${REPO_URLS[$i]:-}"
    if [ -n "${REPO_UPSTREAMS[$i]:-}" ]; then skip+=("$name (already has upstream)"); continue; fi
    if [ -z "$o" ] || ! url_is_github "$o"; then skip+=("$name (no github origin)"); continue; fi
    parse_git_url "$o" >/dev/null
    local info perm; info="$(gh_repo_info "$GU_OWNER/$GU_REPO" || true)"
    perm="$(printf '%s' "$info" | cut -f1)"
    if [ -n "$perm" ] && gh_perm_can_push "$perm"; then
      keep+=("$name ($perm)")
    else
      to_fork_idx+=("$i")
    fi
  done

  # Meta-repo
  local meta_origin meta_label=""
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    meta_origin="$(git -C . remote get-url origin 2>/dev/null || true)"
    if [ -n "$META_UPSTREAM" ]; then
      skip+=("(meta-context) (already has upstream)")
    elif [ -z "$meta_origin" ] || ! url_is_github "$meta_origin"; then
      [ -n "$meta_origin" ] && skip+=("(meta-context) (no github origin)")
    else
      parse_git_url "$meta_origin" >/dev/null
      local minfo mperm; minfo="$(gh_repo_info "$GU_OWNER/$GU_REPO" || true)"
      mperm="$(printf '%s' "$minfo" | cut -f1)"
      if [ -n "$mperm" ] && gh_perm_can_push "$mperm"; then
        keep+=("(meta-context) ($mperm)")
      else
        meta_to_fork=1; meta_label="(meta-context)"
      fi
    fi
  fi

  if [ "${#to_fork_idx[@]}" -eq 0 ] && [ "$meta_to_fork" -eq 0 ]; then
    log "Nothing to fork — every repo either has push access or already has an upstream."
    [ "${#keep[@]}" -gt 0 ] && log "  keep: ${keep[*]}"
    [ "${#skip[@]}" -gt 0 ] && log "  skip: ${skip[*]}"
    return 0
  fi

  log "=== fork --all plan ==="
  local -a fork_labels=()
  for i in ${to_fork_idx[@]+"${to_fork_idx[@]}"}; do fork_labels+=("${REPO_NAMES[$i]}"); done
  [ "$meta_to_fork" -eq 1 ] && fork_labels+=("$meta_label")
  log "  fork: ${fork_labels[*]}"
  [ "${#keep[@]}" -gt 0 ] && log "  keep: ${keep[*]}"
  [ "${#skip[@]}" -gt 0 ] && log "  skip: ${skip[*]}"
  log ""

  if [ "$assume_yes" -ne 1 ]; then
    if ! confirm "Fork and rewire ${#fork_labels[@]} repo(s)?" y; then
      log "Aborted."
      return 0
    fi
  fi

  local rewired=0
  for i in ${to_fork_idx[@]+"${to_fork_idx[@]}"}; do
    fork_and_rewire_repo "$i" && rewired=$((rewired+1))
  done
  if [ "$meta_to_fork" -eq 1 ]; then
    fork_and_rewire_meta && rewired=$((rewired+1))
  fi
  save_repos
  log ""
  log "fork --all complete: rewired $rewired repo(s). Modes unchanged. Run 'mcrepo pr' to open coordinated PRs to upstream."
}

# Report environment + per-repo origin/upstream/access so the git+gh+platform
# setup is transparent. Degrades gracefully when gh is missing/unauthenticated.
cmd_doctor() {
  load_repos
  log "=== mcrepo doctor ==="

  if command -v git >/dev/null 2>&1; then
    if git_supports_merge_tree_write_tree; then
      log "git:  $(git --version 2>/dev/null)"
    else
      warn "git:  $(git --version 2>/dev/null) — 'mcrepo merge' needs git >= 2.38 (merge-tree --write-tree)"
    fi
  else
    warn "git:  NOT FOUND (required)"
  fi

  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      local login; login="$(gh_login)"
      log "gh:   installed, authenticated as ${login:-?}"
    else
      warn "gh:   installed but NOT authenticated — run 'gh auth login' to enable access checks, fork and PRs"
    fi
  else
    warn "gh:   NOT installed — clone/push/branch/merge still work; fork/PR/access-check need gh"
  fi
  log ""

  if [ "${#REPO_NAMES[@]}" -eq 0 ]; then
    log "No repositories configured."
    return 0
  fi
  log "Repositories:"
  local i
  for i in "${!REPO_NAMES[@]}"; do
    local name="${REPO_NAMES[$i]}" o="${REPO_URLS[$i]:-}" up="${REPO_UPSTREAMS[$i]:-}"
    local line="  $name\n     origin:   ${o:-<none>}"
    [ -n "$up" ] && line="$line\n     upstream: $up"
    if [ -n "$o" ] && url_is_github "$o" && gh_ready; then
      parse_git_url "$o" >/dev/null
      local info; info="$(gh_repo_info "$GU_OWNER/$GU_REPO" || true)"
      if [ -n "$info" ]; then
        local perm; perm="$(printf '%s' "$info" | cut -f1)"
        if gh_perm_can_push "$perm"; then
          line="$line\n     access:   $perm (push OK)"
        else
          line="$line\n     access:   $perm (no push — consider 'mcrepo fork $name')"
        fi
      fi
    fi
    printf '%b\n' "$line"
  done
}

cmd_remove() {
  local target=""
  local force=0
  local keep_files=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force|-force)
        force=1
        ;;
      --keep-files)
        keep_files=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option for remove: $1"
        ;;
      *)
        if [ -n "$target" ]; then
          die "Usage: ./mcrepo.sh remove <name-or-url> [--keep-files] [--force]"
        fi
        target="$1"
        ;;
    esac
    shift
  done

  [ -n "$target" ] || die "Usage: ./mcrepo.sh remove <name-or-url> [--keep-files] [--force]"

  load_repos
  local idx
  idx="$(find_repo_index "$target")" || die "Repo not found: $target"

  local removed_name="${REPO_NAMES[$idx]}"
  local removed_mode="${REPO_MODES[$idx]}"
  local removed_is_local="false"
  if is_repo_local "$idx"; then
    removed_is_local="true"
  fi

  local repo_dir=""
  if repo_dir="$(find_existing_repo_dir "$removed_name")"; then
    :
  else
    repo_dir=""
  fi

  local delete_dir=0
  if [ "$keep_files" -eq 0 ] && [ -n "$repo_dir" ] && [ -e "$repo_dir" ]; then
    local -a concerns=()
    local is_git_repo=0
    local is_sleep_placeholder=0

    if [ "$removed_is_local" = "true" ]; then
      concerns+=("local incubator repo - files are committed in base mcrepo history")
    fi

    if [ -d "$repo_dir/.git" ]; then
      is_git_repo=1
      scan_local_work_concerns "$repo_dir"
      concerns+=("${LOCAL_WORK_CONCERNS[@]+"${LOCAL_WORK_CONCERNS[@]}"}")
    elif [ -f "$repo_dir/.mcrepo-sleep" ]; then
      is_sleep_placeholder=1
    fi

    if [ "$is_git_repo" -eq 0 ] && [ "$is_sleep_placeholder" -eq 0 ] && [ "$removed_is_local" != "true" ] && ! directory_is_empty "$repo_dir"; then
      concerns+=("directory is not a git repo")
    fi

    log "Local folder '$repo_dir' still exists (mode: $removed_mode)."
    if [ "${#concerns[@]}" -gt 0 ]; then
      warn "Detected concerns before deleting '$repo_dir':"
      local c
      for c in "${concerns[@]}"; do
        warn "  - $c"
      done
    fi

    if [ "$force" -eq 1 ]; then
      delete_dir=1
    elif [ -t 0 ] && [ -t 1 ]; then
      local prompt_text
      if [ "${#concerns[@]}" -gt 0 ]; then
        prompt_text="Delete '$repo_dir' anyway? This cannot be undone."
      else
        prompt_text="Delete local folder '$repo_dir'?"
      fi
      if confirm "$prompt_text" n; then
        delete_dir=1
      else
        delete_dir=0
      fi
    else
      if [ "${#concerns[@]}" -gt 0 ]; then
        die "Local folder '$repo_dir' has unsaved work and no TTY for confirmation. Re-run with --force to delete, or --keep-files to preserve the folder."
      else
        warn "No TTY for confirmation; keeping '$repo_dir'. Pass --force to delete or --keep-files to suppress this check."
        delete_dir=0
      fi
    fi
  fi

  local old_urls=("${REPO_URLS[@]}")
  local old_names=("${REPO_NAMES[@]}")
  local old_modes=("${REPO_MODES[@]}")
  local old_descriptions=("${REPO_DESCRIPTIONS[@]}")
  local old_parents=("${REPO_PARENTS[@]}")
  local old_locals=("${REPO_LOCALS[@]}")
  local old_upstreams=("${REPO_UPSTREAMS[@]}")

  REPO_URLS=()
  REPO_NAMES=()
  REPO_MODES=()
  REPO_DESCRIPTIONS=()
  REPO_PARENTS=()
  REPO_LOCALS=()
  REPO_UPSTREAMS=()

  local i
  for i in "${!old_names[@]}"; do
    if [ "$i" -ne "$idx" ]; then
      REPO_URLS+=("${old_urls[$i]}")
      REPO_NAMES+=("${old_names[$i]}")
      REPO_MODES+=("${old_modes[$i]}")
      REPO_DESCRIPTIONS+=("${old_descriptions[$i]}")
      REPO_PARENTS+=("${old_parents[$i]}")
      REPO_LOCALS+=("${old_locals[$i]}")
      REPO_UPSTREAMS+=("${old_upstreams[$i]}")
    fi
  done
  save_repos

  if [ "$delete_dir" -eq 1 ] && [ -n "$repo_dir" ] && [ -e "$repo_dir" ]; then
    if [ "$removed_is_local" = "true" ] && git -C . rev-parse --git-dir >/dev/null 2>&1; then
      if git -C . ls-files --error-unmatch -- "$repo_dir/" >/dev/null 2>&1 \
        || [ -n "$(git -C . ls-files -- "$repo_dir/" 2>/dev/null)" ]; then
        git -C . rm -rf -- "$repo_dir" >/dev/null 2>&1 || rm -rf -- "$repo_dir"
        log "Deleted local incubator folder and untracked from base: $repo_dir"
        log "Run 'git commit' in base mcrepo to record the removal."
      else
        rm -rf -- "$repo_dir"
        log "Deleted local folder: $repo_dir"
      fi
    else
      rm -rf -- "$repo_dir"
      log "Deleted local folder: $repo_dir"
    fi
  elif [ "$keep_files" -eq 0 ] && [ -n "$repo_dir" ] && [ -e "$repo_dir" ]; then
    log "Kept local folder: $repo_dir"
  fi

  if [ "$removed_is_local" != "true" ]; then
    remove_gitignore_repo_entry "$removed_name"
  fi

  refresh_generated_files
  sync_vscode_git_ignored_repositories
  log "Removed repo '$removed_name' from management."
}

# Pick a sensible default branch name for newly-initialized git repos.
# Order: GLOBAL_BRANCH (if mcrepo.yaml configured one), git init.defaultBranch, then "main".
pick_default_branch() {
  if [ -n "${GLOBAL_BRANCH:-}" ]; then
    printf '%s' "$GLOBAL_BRANCH"
    return 0
  fi
  local cfg
  cfg="$(git config --get init.defaultBranch 2>/dev/null || true)"
  if [ -n "$cfg" ]; then
    printf '%s' "$cfg"
    return 0
  fi
  printf 'main'
}

validate_new_repo_name() {
  local name="$1"
  [ -n "$name" ] || die "Repository name must not be empty"
  case "$name" in
    .|..|.git) die "Reserved name not allowed: $name" ;;
  esac
  case "$name" in
    */*|*\\*) die "Repository name must not contain path separators: $name" ;;
  esac
  case "$name" in
    .*) die "Repository name must not start with a dot: $name" ;;
  esac
  case "$name" in
    *' '*|*$'\t'*|*$'\n'*) die "Repository name must not contain whitespace: $name" ;;
  esac
}

cmd_new() {
  local name=""
  local description=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m|--description)
        shift
        [ "$#" -ge 1 ] || die "Usage: ./mcrepo.sh new <name> [-m \"description\"]"
        description="$1"
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option for new: $1"
        ;;
      *)
        if [ -n "$name" ]; then
          die "Usage: ./mcrepo.sh new <name> [-m \"description\"]"
        fi
        name="$1"
        ;;
    esac
    shift
  done

  [ -n "$name" ] || die "Usage: ./mcrepo.sh new <name> [-m \"description\"]"
  validate_new_repo_name "$name"

  load_repos
  if find_repo_index "$name" >/dev/null 2>&1; then
    die "A repository named '$name' is already managed by mcrepo"
  fi

  if [ -e "./$name" ]; then
    die "Path './$name' already exists; refusing to overwrite. Use a different name or remove the existing path first."
  fi

  REPO_URLS+=("")
  REPO_NAMES+=("$name")
  REPO_MODES+=("write")
  REPO_DESCRIPTIONS+=("$description")
  REPO_PARENTS+=("")
  REPO_LOCALS+=("true")
  REPO_UPSTREAMS+=("")
  save_repos

  mkdir -p "./$name"
  if [ ! -e "./$name/README.md" ]; then
    cat >"./$name/README.md" <<EOF
# $name

Local incubator sub-repo managed by mcrepo. Files live committed inside the
base mcrepo until you graduate this repo with:

    ./mcrepo.sh publish $name <git-url>
EOF
  fi

  reconcile_gitignore_with_repos
  refresh_generated_files
  sync_vscode_git_ignored_repositories

  log "Created local incubator repo '$name' at ./$name/."
  log "Files live committed inside the base mcrepo until you run:"
  log "  ./mcrepo.sh publish $name <git-url>"
}

cmd_publish() {
  local name=""
  local url=""
  local commit_msg=""
  local force=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m|--message)
        shift
        [ "$#" -ge 1 ] || die "Usage: ./mcrepo.sh publish <name> <git-url> [-m \"initial commit message\"] [--force]"
        commit_msg="$1"
        ;;
      --force|-force)
        force=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option for publish: $1"
        ;;
      *)
        if [ -z "$name" ]; then
          name="$1"
        elif [ -z "$url" ]; then
          url="$1"
        else
          die "Usage: ./mcrepo.sh publish <name> <git-url> [-m \"initial commit message\"] [--force]"
        fi
        ;;
    esac
    shift
  done

  [ -n "$name" ] && [ -n "$url" ] || die "Usage: ./mcrepo.sh publish <name> <git-url> [-m \"initial commit message\"] [--force]"

  load_repos
  local idx
  idx="$(find_repo_index "$name")" || die "Repo not found: $name"
  if ! is_repo_local "$idx"; then
    die "Repo '$name' is already external (url: ${REPO_URLS[$idx]}). 'publish' only applies to local incubator repos."
  fi

  local repo_dir="./$name"
  [ -d "$repo_dir" ] || die "Local folder '$repo_dir' is missing. Re-create it or remove the mcrepo.yaml entry."

  if [ -d "$repo_dir/.git" ]; then
    die "Folder '$repo_dir' already has a .git/ directory. Remove or rename it first; mcrepo will not overwrite an existing git repo."
  fi

  # Validate remote: reachable, and (unless --force) empty.
  local ls_remote_output
  if ! ls_remote_output="$(git ls-remote "$url" 2>&1)"; then
    die "Remote not reachable: $url"$'\n'"$ls_remote_output"
  fi
  if [ -n "$ls_remote_output" ] && [ "$force" -eq 0 ]; then
    die "Remote '$url' is not empty. Refusing to publish to a non-empty remote. Re-run with --force to override."
  fi

  local base_is_git=0
  if git -C . rev-parse --git-dir >/dev/null 2>&1; then
    base_is_git=1
  fi

  # If base is a git repo, refuse if there are uncommitted changes outside <name>/
  if [ "$base_is_git" -eq 1 ]; then
    local outside_dirty
    outside_dirty="$(git -C . status --porcelain -- ":(exclude)$name/" 2>/dev/null || true)"
    if [ -n "$outside_dirty" ]; then
      die "Base mcrepo has uncommitted changes outside '$name/'. Commit or stash them first so the publish commit stays focused."
    fi
  fi

  local branch
  branch="$(pick_default_branch)"

  # ---- Mutation phase ----

  if [ "$base_is_git" -eq 1 ]; then
    # Untrack from base while keeping working files.
    if git -C . ls-files --error-unmatch -- "$repo_dir/" >/dev/null 2>&1 \
      || [ -n "$(git -C . ls-files -- "$repo_dir/" 2>/dev/null)" ]; then
      git -C . rm -r --cached -- "$repo_dir/" >/dev/null
    fi
    ensure_gitignore_repo_entry "$name"
    git -C . add -- .gitignore >/dev/null 2>&1 || true
    if [ -n "$(git -C . status --porcelain -- ".gitignore" "$repo_dir/" 2>/dev/null)" ]; then
      git -C . commit -m "mcrepo: publish $name to $url" -- ".gitignore" "$repo_dir/" >/dev/null \
        || warn "Base mcrepo commit failed. Run 'git commit' manually to record the untracking."
    fi
  else
    # Base is not git-managed yet. Still keep .gitignore in shape for when it is.
    ensure_gitignore_repo_entry "$name"
    log "Note: base mcrepo is not a git repo yet. Skipping base-side commit."
    log "      Run './mcrepo.sh publish-base <url>' to also git-manage the workspace itself."
  fi

  # Init the sub-repo, commit, push.
  git -C "$repo_dir" init -q
  git -C "$repo_dir" symbolic-ref HEAD "refs/heads/$branch"
  git -C "$repo_dir" add -A
  git -C "$repo_dir" commit -m "${commit_msg:-Initial commit}" -q
  git -C "$repo_dir" remote add origin "$url"
  if ! git -C "$repo_dir" push -u origin "$branch"; then
    warn "Push to '$url' failed. Sub-repo is initialized locally; re-run 'git -C $repo_dir push -u origin $branch' once the remote is reachable."
  fi

  # Update YAML
  REPO_URLS[$idx]="$url"
  REPO_LOCALS[$idx]="false"
  save_repos

  refresh_generated_files
  sync_vscode_git_ignored_repositories

  log "Published '$name' to $url on branch '$branch'."
  if [ "$base_is_git" -eq 1 ]; then
    log "Base mcrepo no longer tracks '$name/' going forward (old base history still contains the files; non-destructive)."
  fi
}

cmd_publish_base() {
  local url=""
  local commit_msg=""
  local force=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m|--message)
        shift
        [ "$#" -ge 1 ] || die "Usage: ./mcrepo.sh publish-base <git-url> [-m \"initial workspace commit message\"] [--force]"
        commit_msg="$1"
        ;;
      --force|-force)
        force=1
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Unknown option for publish-base: $1"
        ;;
      *)
        if [ -z "$url" ]; then
          url="$1"
        else
          die "Usage: ./mcrepo.sh publish-base <git-url> [-m \"initial workspace commit message\"] [--force]"
        fi
        ;;
    esac
    shift
  done

  [ -n "$url" ] || die "Usage: ./mcrepo.sh publish-base <git-url> [-m \"initial workspace commit message\"] [--force]"

  [ -f "$REPOS_FILE" ] || die "Not in an mcrepo workspace ($REPOS_FILE missing). Run './mcrepo.sh init' first."

  load_repos

  local base_is_git=0
  if git -C . rev-parse --git-dir >/dev/null 2>&1; then
    base_is_git=1
  fi

  # Detect existing origin so re-running publish-base with the same URL is
  # idempotent (it skips the "remote must be empty" guard).
  local existing_origin=""
  if [ "$base_is_git" -eq 1 ]; then
    existing_origin="$(git -C . remote get-url origin 2>/dev/null || true)"
  fi

  # Validate remote: reachable and (unless --force, or origin already matches)
  # not already populated. Skipping the emptiness check when origin matches
  # supports idempotent re-runs that just push new commits.
  if [ "$existing_origin" != "$url" ]; then
    local ls_remote_output
    if ! ls_remote_output="$(git ls-remote "$url" 2>&1)"; then
      die "Remote not reachable: $url"$'\n'"$ls_remote_output"
    fi
    if [ -n "$ls_remote_output" ] && [ "$force" -eq 0 ]; then
      die "Remote '$url' is not empty. Refusing to publish base to a non-empty remote. Re-run with --force to override."
    fi
  fi

  local branch
  branch="$(pick_default_branch)"

  if [ "$base_is_git" -eq 0 ]; then
    git -C . init -q
    git -C . symbolic-ref HEAD "refs/heads/$branch"
    log "Initialized base mcrepo as a git repository (branch '$branch')."
  fi

  # Safety net: reconcile .gitignore so external sub-repos are excluded and local incubators are tracked,
  # BEFORE the first commit.
  ensure_gitignore_base
  reconcile_gitignore_with_repos

  # Origin handling. existing_origin was captured earlier so we can re-detect
  # if a fresh `git init` above changed things.
  existing_origin="$(git -C . remote get-url origin 2>/dev/null || true)"
  if [ -n "$existing_origin" ]; then
    if [ "$existing_origin" != "$url" ]; then
      if [ "$force" -eq 1 ]; then
        git -C . remote set-url origin "$url"
        log "Replaced origin URL: $existing_origin -> $url"
      else
        die "Base already has origin set to '$existing_origin'. Re-run with --force to replace, or use 'git remote set-url' manually."
      fi
    fi
  else
    git -C . remote add origin "$url"
  fi

  # Commit if there's anything to commit (and there's no HEAD yet, or there's staged/unstaged work)
  local has_commits=0
  if git -C . rev-parse HEAD >/dev/null 2>&1; then
    has_commits=1
  fi

  git -C . add -A
  if [ -n "$(git -C . status --porcelain 2>/dev/null)" ]; then
    git -C . commit -m "${commit_msg:-mcrepo: initial workspace commit}" -q \
      || warn "Workspace commit failed. Run 'git commit' manually."
  elif [ "$has_commits" -eq 0 ]; then
    die "No files to commit in the workspace. Add some content (or run 'mcrepo new <name>') and try again."
  fi

  # Determine the actual branch to push (may have been changed by symbolic-ref or already existed).
  local push_branch
  push_branch="$(git -C . symbolic-ref --short HEAD 2>/dev/null || printf '%s' "$branch")"

  if ! git -C . push -u origin "$push_branch"; then
    warn "Push to '$url' failed. Workspace is git-managed locally; re-run 'git push -u origin $push_branch' once the remote is reachable."
    return 0
  fi

  log "Workspace published to $url on branch '$push_branch'."
  log "External sub-repos remain ignored; local incubator sub-repos are tracked in base history."
}

set_mode_command() {
  local target_mode="$1"
  shift

  if [ "$target_mode" = "sleep" ]; then
    if [ "$#" -eq 1 ] && [ "$1" = "--wakeall" ]; then
      wake_all_sleeping_repos_to_read
      return 0
    fi
  fi

  [ "$#" -ge 1 ] || die "Usage: ./mcrepo.sh $target_mode <repo-name>"
  local repo_name="$1"
  shift

  local force_sleep=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force|-force)
        if [ "$target_mode" != "sleep" ]; then
          die "--force is only supported with 'sleep'"
        fi
        force_sleep=1
        ;;
      *)
        die "Unknown option for $target_mode: $1"
        ;;
    esac
    shift
  done

  load_repos
  local idx
  idx="$(find_repo_index "$repo_name")" || die "Repo not found: $repo_name"

  local previous_mode
  previous_mode="${REPO_MODES[$idx]}"

  if [ "$target_mode" = "sleep" ] && ! is_repo_local "$idx"; then
    # Sleep deletes the working copy INCLUDING .git. Scan for ANY local work
    # (uncommitted, untracked, unpushed on any branch, stashes) regardless of
    # the previous mode — read-mode edits are just as lost as write-mode ones.
    local sleep_dir=""
    if sleep_dir="$(find_existing_repo_dir "${REPO_NAMES[$idx]}")" && [ -d "$sleep_dir/.git" ]; then
      scan_local_work_concerns "$sleep_dir"
      if [ "${#LOCAL_WORK_CONCERNS[@]}" -gt 0 ]; then
        warn "Sleeping '${REPO_NAMES[$idx]}' deletes its local clone (including .git). Detected local work in '$sleep_dir':"
        local _slc
        for _slc in "${LOCAL_WORK_CONCERNS[@]}"; do
          warn "  - $_slc"
        done
        if [ "$force_sleep" -eq 1 ]; then
          warn "Proceeding due to --force."
        elif [ -t 0 ] && [ -t 1 ]; then
          if ! confirm "Delete this work and sleep '${REPO_NAMES[$idx]}' anyway? This cannot be undone." n; then
            log "Aborted. Push or commit the work first, or re-run with --force to discard it."
            return 0
          fi
        else
          die "Repository '${REPO_NAMES[$idx]}' has local work that sleeping would destroy (see above). Push it first, or re-run './mcrepo.sh sleep ${REPO_NAMES[$idx]} --force' to discard it."
        fi
      fi
    fi
  elif [ "$previous_mode" = "write" ] && [ "$target_mode" != "write" ]; then
    local previous_repo_dir
    previous_repo_dir="$(get_repo_dir "${REPO_NAMES[$idx]}" "$previous_mode")"
    if [ -d "$previous_repo_dir/.git" ] && [ -n "$(git -C "$previous_repo_dir" status --porcelain 2>/dev/null)" ]; then
      die "Repository '${REPO_NAMES[$idx]}' has uncommitted changes in '$previous_repo_dir'. Commit/stash them first before changing mode to '$target_mode'."
    fi
  fi

  REPO_MODES[$idx]="$target_mode"
  save_repos

  local repo_dir
  repo_dir="$(ensure_repo_dir_mode "${REPO_NAMES[$idx]}" "$target_mode")"

  if is_repo_local "$idx"; then
    # Local incubator repo: mode is a pure signal. Files live in base mcrepo
    # working tree (committed to base history) and must not be touched. No
    # .gitignore entry, no clone, no clear.
    refresh_generated_files
    sync_vscode_git_ignored_repositories
    log "Set local repo '${REPO_NAMES[$idx]}' to mode '$target_mode' (files preserved)."
    return 0
  fi

  ensure_gitignore_repo_entry "${REPO_NAMES[$idx]}"
  if [ "$target_mode" = "write" ] || [ "$target_mode" = "read" ]; then
    if ! clone_repo_if_needed "$repo_dir" "${REPO_URLS[$idx]}" "$target_mode"; then
      warn "Mode changed, but clone failed for '${REPO_NAMES[$idx]}'"
    fi
  fi
  if [ "$target_mode" = "write" ]; then
    apply_global_branch_to_repo_if_configured "${REPO_NAMES[$idx]}" "$repo_dir"
    # read->write: if you lack push access to origin, offer to fork (non-blocking).
    if [ "$previous_mode" != "write" ] && [ -z "${REPO_UPSTREAMS[$idx]:-}" ]; then
      local _w_origin="${REPO_URLS[$idx]:-}"
      if [ -n "$_w_origin" ] && url_is_github "$_w_origin" && gh_ready; then
        parse_git_url "$_w_origin" >/dev/null
        local _w_info _w_perm
        _w_info="$(gh_repo_info "$GU_OWNER/$GU_REPO" || true)"
        _w_perm="$(printf '%s' "$_w_info" | cut -f1)"
        if [ -n "$_w_perm" ] && ! gh_perm_can_push "$_w_perm"; then
          local _w_do_fork=0
          if [ -t 0 ] && [ -t 1 ]; then
            if confirm "You have no push access to '$_w_origin' ($_w_perm). Fork it now (origin->your fork, original->upstream)?" y; then
              _w_do_fork=1
            fi
          fi
          if [ "$_w_do_fork" -eq 1 ]; then
            if fork_and_rewire_repo "$idx"; then
              save_repos
              log "origin is now your fork; '${REPO_NAMES[$idx]}' is ready for write."
            fi
          else
            warn "No push access to '${REPO_NAMES[$idx]}' origin — run 'mcrepo fork ${REPO_NAMES[$idx]}' when you want to contribute via a fork."
          fi
        fi
      fi
    fi
  fi
  if [ "$target_mode" = "sleep" ]; then
    mkdir -p "$repo_dir"
    clear_directory_contents "$repo_dir"
    write_sleep_placeholder_files "$repo_dir"
    if [ "$force_sleep" -eq 1 ]; then
      log "Put repo into sleep mode and force-cleared local contents: $repo_dir"
    else
      log "Put repo into sleep mode and cleared local contents: $repo_dir"
    fi
  fi

  refresh_generated_files
  sync_vscode_git_ignored_repositories
  log "Set '${REPO_NAMES[$idx]}' to mode '$target_mode'."
}

wake_all_sleeping_repos_to_read() {
  load_repos

  local i woke_count=0
  local -a woke_indexes=()
  for i in "${!REPO_NAMES[@]}"; do
    if [ "${REPO_MODES[$i]}" = "sleep" ]; then
      REPO_MODES[$i]="read"
      woke_indexes+=("$i")
      woke_count=$((woke_count + 1))
    fi
  done

  if [ "$woke_count" -eq 0 ]; then
    log "No sleeping repositories found."
    return 0
  fi

  save_repos

  local repo_dir
  for i in "${woke_indexes[@]}"; do
    if is_repo_local "$i"; then
      # Local repo: nothing to clone; mode flip already saved.
      continue
    fi
    repo_dir="$(ensure_repo_dir_mode "${REPO_NAMES[$i]}" "read")"
    ensure_gitignore_repo_entry "${REPO_NAMES[$i]}"
    if ! clone_repo_if_needed "$repo_dir" "${REPO_URLS[$i]}" "read"; then
      warn "Mode changed, but clone failed for '${REPO_NAMES[$i]}'"
    fi
  done

  refresh_generated_files
  sync_vscode_git_ignored_repositories
  log "Woke $woke_count sleeping repos to mode 'read'."
}

repo_branch() {
  local repo_dir="$1"
  if [ -d "$repo_dir/.git" ]; then
    git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true
  else
    printf -- '-'
  fi
}

repo_dirty_state() {
  local repo_dir="$1"
  if [ -d "$repo_dir/.git" ]; then
    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
      printf 'dirty'
    else
      printf 'clean'
    fi
  else
    printf -- '-'
  fi
}

# Reports MERGING / REBASING / CHERRY-PICKING / REVERTING / BISECTING
# when the repo is mid-operation; empty string otherwise.
repo_inprogress_state() {
  local repo_dir="$1"
  local git_dir
  git_dir="$(git -C "$repo_dir" rev-parse --git-dir 2>/dev/null)" || return 0
  if [ "${git_dir#/}" = "$git_dir" ]; then
    git_dir="$repo_dir/$git_dir"
  fi
  if [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ]; then
    printf 'REBASING'
  elif [ -f "$git_dir/MERGE_HEAD" ]; then
    printf 'MERGING'
  elif [ -f "$git_dir/CHERRY_PICK_HEAD" ]; then
    printf 'CHERRY-PICKING'
  elif [ -f "$git_dir/REVERT_HEAD" ]; then
    printf 'REVERTING'
  elif [ -f "$git_dir/BISECT_LOG" ]; then
    printf 'BISECTING'
  elif [ -n "$(git -C "$repo_dir" ls-files -u 2>/dev/null)" ]; then
    # Unmerged index entries without any op marker: a squash-merge conflict
    # (squash sets no MERGE_HEAD) or a stash-pop conflict. Without this
    # fallback such repos look idle to status/continue/abort.
    printf 'CONFLICTED'
  fi
}

# Count stash entries created by mcrepo itself ("mcrepo: carry to <branch>",
# "mcrepo: auto-stash before rebase"). They need explicit pop/drop finalization.
repo_mcrepo_stash_count() {
  local repo_dir="$1"
  git -C "$repo_dir" stash list 2>/dev/null | grep -c 'mcrepo:' || true
}

# Stash push that returns 0 ONLY when a new stash entry was actually created.
# 'git stash push' exits 0 with "No local changes to save" when the dirty
# state is something stash cannot capture (e.g. a moved submodule pointer) —
# a later blind 'stash pop' would then pop an unrelated pre-existing stash.
_mcrepo_stash_push() {
  local dir="$1" msg="$2" before after
  before="$(git -C "$dir" rev-parse -q --verify refs/stash 2>/dev/null || true)"
  git -C "$dir" stash push --include-untracked -m "$msg" 2>/dev/null || true
  after="$(git -C "$dir" rev-parse -q --verify refs/stash 2>/dev/null || true)"
  [ "$after" != "$before" ]
}

# Reports "in-sync", "ahead=N behind=M", or "no-upstream" without fetching.
# Counts are based on locally-known refs only.
repo_upstream_state() {
  local repo_dir="$1"
  if ! git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    printf 'no-upstream'
    return 0
  fi
  local ab behind ahead
  ab="$(git -C "$repo_dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)" || { printf '?'; return 0; }
  behind="$(printf '%s' "$ab" | awk '{print $1+0}')"
  ahead="$(printf '%s' "$ab" | awk '{print $2+0}')"
  if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
    printf 'in-sync'
  else
    printf 'ahead=%s behind=%s' "$ahead" "$behind"
  fi
}

# Classify how a branch diverges from its upstream, so callers can tell the
# "I rebased onto main but haven't pushed yet" case (safe to force-with-lease)
# apart from "the remote branch has real new work" (must not be clobbered).
# Usage: classify_divergence <repo_dir> <branch> <parent>  (parent may be empty)
# Prints exactly one of:
#   none         - no upstream, in-sync, ahead-only (plain push), or unknown
#   behind-only  - behind>0 && ahead==0 (plain fast-forward; normal pull handles it)
#   safe-force   - diverged AND every remote-only commit has a patch-equivalent
#                  local commit (provably our own rebase; auto-force eligible)
#   remote-work  - diverged, remote holds content-new commits on the current
#                  base (another device pushed; integrate by rebasing onto it)
#   ambiguous    - diverged, remote holds content-new commits AND predates our
#                  rebase base; never auto-force, never auto-rebase
classify_divergence() {
  local repo_dir="$1"
  local branch="$2"
  local parent="$3"
  if ! git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    printf 'none'; return 0
  fi
  local ab behind ahead
  ab="$(git -C "$repo_dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)" || { printf 'none'; return 0; }
  behind="$(printf '%s' "$ab" | awk '{print $1+0}')"
  ahead="$(printf '%s' "$ab" | awk '{print $2+0}')"
  if [ "$behind" -eq 0 ]; then
    printf 'none'; return 0   # in-sync or ahead-only: nothing diverged
  fi
  if [ "$ahead" -eq 0 ]; then
    printf 'behind-only'; return 0   # plain fast-forward
  fi
  # Diverged (ahead>0 && behind>0). Decide whether this is our own rebase.
  # Content probe first: remote-side commits with NO patch-equivalent local
  # commit. Empty means everything the remote holds also exists locally
  # (as-is or in rebased form) - force-with-lease cannot lose content. This
  # proof survives the parent branch advancing after the rebase (which used
  # to flip the classification and route repos into a rebase onto their own
  # stale remote). Merge commits never patch-match, so a remote-only merge
  # conservatively counts as new content.
  local remote_new
  remote_new="$(git -C "$repo_dir" rev-list --left-only --cherry-pick '@{u}...HEAD' 2>/dev/null || true)"
  if [ -z "$remote_new" ]; then
    printf 'safe-force'; return 0
  fi
  # Resolve the parent ref P: prefer origin/<parent>, else local <parent>.
  local p_ref=""
  if [ -n "$parent" ]; then
    if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$parent"; then
      p_ref="origin/$parent"
    elif git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$parent"; then
      p_ref="$parent"
    fi
  fi
  if [ -z "$p_ref" ]; then
    printf 'remote-work'; return 0   # no parent ref: plain divergence, integrate it
  fi
  if git -C "$repo_dir" merge-base --is-ancestor "$p_ref" HEAD 2>/dev/null && \
     ! git -C "$repo_dir" merge-base --is-ancestor "$p_ref" "@{u}" 2>/dev/null; then
    # The remote predates our rebase base AND carries content-new commits:
    # either our own conflict-resolved rebase (patches mutated during 'sync')
    # or new work stacked on the stale base by another device. The two are
    # indistinguishable here - force-pushing could delete the new work,
    # rebasing could resurrect the stale history. Hand it to a human/agent.
    printf 'ambiguous'; return 0
  fi
  printf 'remote-work'
}

# --- Agent recovery prompts -------------------------------------------------
# When mcrepo hits a state it deliberately will not auto-resolve, it prints a
# paste-ready prompt for a local coding agent. _emit_agent_prompt_body writes
# the raw prompt to stdout (used by 'mcrepo resolve');
# print_agent_recovery_prompt wraps it in framing and sends everything to
# stderr (used in failure paths - stdout stays reserved for command results).
# Usage: _emit_agent_prompt_body <situation> <name|dir> [<name|dir> ...]
#   situation: rebase-conflict | pull-rebase-conflict | merge-conflict |
#              stash-conflict | carry-conflict | ambiguous-divergence |
#              partial-commit
# Callers may set MCREPO_RECOVERY_CONTEXT (multi-line) with situation details
# (exact commit subject, stash name, ...); it is printed and cleared here.
MCREPO_RECOVERY_CONTEXT=""
_emit_agent_prompt_body() {
  local situation="$1"; shift
  local headline detail three_sides=0
  case "$situation" in
    rebase-conflict)
      headline="Rebase conflicts during 'mcrepo rebase' (coordinated branches across repos)."
      detail="A git rebase is paused mid-way. Each affected repo has an in-progress rebase to finish."
      three_sides=1
      ;;
    pull-rebase-conflict)
      headline="Rebase conflicts during 'mcrepo pull' (integrating remote work from another device)."
      detail="A git rebase is paused: MY local commits are being replayed ON TOP of genuinely new commits fetched from origin. The remote commits form the new base - they must ALL be kept."
      ;;
    merge-conflict)
      headline="A coordinated 'mcrepo merge' into the parent branch failed, or a merge left unmerged files."
      detail="Some repos may already be merged; the affected ones need repair before re-running 'mcrepo merge'."
      ;;
    stash-conflict)
      headline="Stash-pop conflicts after a coordinated rebase/pull."
      detail="The git operation succeeded, but re-applying auto-stashed local changes conflicted. The stash entry is still saved."
      ;;
    carry-conflict)
      headline="Carrying uncommitted changes to another branch conflicted ('mcrepo branch')."
      detail="mcrepo stashed local changes before switching branches and could not re-apply them cleanly."
      ;;
    ambiguous-divergence)
      headline="A coordinated branch diverged from its remote and it is NOT just a local rebase."
      detail="The remote branch contains work mcrepo cannot prove came from a local rebase, so it refuses to force-push."
      three_sides=1
      ;;
    partial-commit)
      headline="A coordinated commit succeeded in some repos but failed in others."
      detail="The batch must stay one revertable unit; the failed repos need a commit with the SAME subject."
      ;;
    *)
      headline="mcrepo hit a state it will not auto-resolve."
      detail=""
      ;;
  esac
  printf 'I am working in an mcrepo workspace (./mcrepo.sh): a meta-context repo plus managed\n'
  printf 'sub-repos share one coordinated feature branch. mcrepo records the parent branch of each\n'
  printf 'repo in mcrepo.yaml and rebases/merges all repos together. Coordinated commits share\n'
  printf 'subjects like "mcrepo commit #N @<batch>: ...".\n\n'
  printf 'Situation: %s\n' "$headline"
  [ -n "$detail" ] && printf '%s\n' "$detail"
  printf '\nAffected repos (name and local path):\n'
  local entry name dir
  for entry in "$@"; do
    name="${entry%%|*}"
    dir="${entry#*|}"
    printf -- '- %s  (cd %s)\n' "$name" "$dir"
  done
  if [ -n "${MCREPO_RECOVERY_CONTEXT:-}" ]; then
    printf '\nAdditional context:\n%s\n' "$MCREPO_RECOVERY_CONTEXT"
  fi
  MCREPO_RECOVERY_CONTEXT=""
  local step=1
  printf '\nPlease resolve this carefully:\n'
  printf '%d. Orient first, change nothing yet: run ./mcrepo.sh status, then in each affected repo\n' "$step"
  printf '   `git -C <dir> status` and `git -C <dir> log --oneline --graph --all -20`.\n'
  step=$((step + 1))
  if [ "$three_sides" -eq 1 ]; then
    printf '%d. Three sides can collide here: the local feature branch (my work), the parent branch it\n' "$step"
    printf '   is rebased onto (the latest main), and a possibly stale origin/<branch> that still\n'
    printf '   holds pre-rebase history. The same "mcrepo commit #N @<batch>" coordination commits may\n'
    printf '   exist in BOTH old and rebased form - never keep both. The target state is: my real\n'
    printf '   feature work sitting on top of the latest parent.\n'
    step=$((step + 1))
  fi
  printf '%d. Resolve ONLY real semantic conflicts. Where the two sides differ purely in formatting or\n' "$step"
  printf '   whitespace, keep the formatting of the parent/upstream side and preserve the substantive\n'
  printf '   changes of both sides. Never reformat, reorder, or "clean up" code outside the conflict\n'
  printf '   markers.\n'
  step=$((step + 1))
  case "$situation" in
    rebase-conflict)
      printf '%d. For each paused repo: edit the conflicted files, `git -C <dir> add` them, then run\n' "$step"
      printf '   ./mcrepo.sh continue to advance every paused rebase (repeat until none remain). If\n'
      printf '   mcrepo reported an auto-stash, run `git -C <dir> stash pop` afterwards; if the pop\n'
      printf '   itself conflicts, resolve the same way, `git add`, then `git -C <dir> stash drop`.\n'
      printf '   (If this rebase came from `mcrepo pull` instead of `mcrepo rebase`, the\n'
      printf '   commits from origin are genuinely NEW work from another device - they form the new\n'
      printf '   base; never drop them.)\n'
      ;;
    pull-rebase-conflict)
      printf '%d. The commits from origin/<branch> are REAL new work (for example pushed from another\n' "$step"
      printf '   device or by a teammate) - they form the new base and must all survive. My local\n'
      printf '   commits are being replayed on top; resolve each conflict so both sides remain. For\n'
      printf '   each paused repo: edit the conflicted files, `git -C <dir> add` them, then run\n'
      printf '   ./mcrepo.sh continue (repeat until none remain). If mcrepo reported an auto-stash,\n'
      printf '   `git -C <dir> stash pop` afterwards; if the pop conflicts, resolve, `git add`, then\n'
      printf '   `git -C <dir> stash drop`. When everything is clean, re-run ./mcrepo.sh pull so\n'
      printf '   remaining repos finish.\n'
      ;;
    merge-conflict)
      printf '%d. A paused merge (inprogress=MERGING) is finished with: resolve, `git -C <dir> add`,\n' "$step"
      printf '   then ./mcrepo.sh continue. A SQUASH-merge conflict leaves NO in-progress marker - the\n'
      printf '   repo sits on its PARENT branch with unmerged files (inprogress=CONFLICTED): resolve,\n'
      printf '   `git -C <dir> add` the files, then `git -C <dir> commit`. If mcrepo already rolled a\n'
      printf '   failed repo back to the feature branch, find out why the merge failed (git output,\n'
      printf '   hooks), fix that, then re-run ./mcrepo.sh merge - already-merged repos are skipped.\n'
      ;;
    stash-conflict)
      printf '%d. The rebase/pull itself succeeded; only re-applying auto-stashed local changes\n' "$step"
      printf '   conflicted, and the stash entry is still saved. Resolve the conflicted files,\n'
      printf '   `git -C <dir> add` them, then `git -C <dir> stash drop` to discard the now-applied\n'
      printf '   entry. There is nothing to "continue" - this conflict lives only in the working tree.\n'
      ;;
    carry-conflict)
      printf '%d. mcrepo branch stashed my uncommitted changes before switching and could not re-apply\n' "$step"
      printf '   them. If `git -C <dir> stash list` still shows the mcrepo entry and the working tree\n'
      printf '   has no conflict markers, `git -C <dir> stash pop` first. Resolve the conflicted files,\n'
      printf '   `git -C <dir> add` them, then `git -C <dir> stash drop` if the entry is still listed.\n'
      ;;
    ambiguous-divergence)
      printf '%d. Report before acting: show me what the remote has that I lack\n' "$step"
      printf '   (`git -C <dir> log --oneline HEAD..@{u}`) and what I have locally\n'
      printf '   (`git -C <dir> log --oneline @{u}..HEAD`). If the remote commits are wanted,\n'
      printf '   integrate them (rebase my branch onto origin/<branch>, or merge). Only if I\n'
      printf '   explicitly confirm they are obsolete pre-rebase leftovers may you publish with\n'
      printf '   `git -C <dir> push --force-with-lease` - never a plain --force, never without asking.\n'
      ;;
    partial-commit)
      printf '%d. The coordinated commit was recorded in some repos but failed in the ones listed\n' "$step"
      printf '   above. In each failed repo find out why the commit failed (hooks, unmerged files,\n'
      printf '   permissions), fix that, then complete the batch with the EXACT subject given in the\n'
      printf '   additional context: `git -C <dir> add -A && git -C <dir> commit -m "<subject>"`.\n'
      printf '   Do not invent a new message and do not run mcrepo commit again - that would start a\n'
      printf '   new batch number.\n'
      ;;
    *)
      printf '%d. Inspect each affected repo and bring it back to a clean state without losing work.\n' "$step"
      ;;
  esac
  step=$((step + 1))
  printf '%d. Finish sequence: repeat resolve -> `git add` -> ./mcrepo.sh continue until ./mcrepo.sh\n' "$step"
  printf '   status shows no inprogress= entries, confirm with ./mcrepo.sh resolve that nothing is\n'
  printf '   left, then run ./mcrepo.sh push to publish (it only force-with-leases branches that are\n'
  printf '   provably my own rebase and refuses genuinely diverged remotes).\n'
  printf '\nHard rules: never run `git push --force`, `git reset --hard`, `git rebase --skip`, or\n'
  printf 'wholesale `git checkout --ours/--theirs`, and never delete branches or stashes on your\n'
  printf 'own. If one of those seems necessary, stop and ask me first. Commits are allowed ONLY to\n'
  printf 'finish a paused merge/rebase or a repair commit these instructions name; new feature work\n'
  printf 'stays user-driven.\n'
}

print_agent_recovery_prompt() {
  {
    printf '\n'
    printf 'Need help resolving this? Paste the prompt between the lines below to your local coding agent:\n'
    printf -- '------------------------------------------------------------\n'
    _emit_agent_prompt_body "$@"
    printf -- '------------------------------------------------------------\n'
  } >&2
}

generate_commit_message() {
  local repo_dir="$1"
  local branch_name="$2"
  local repo_name="$3"
  local diff_summary
  diff_summary="$(git -C "$repo_dir" diff --stat HEAD 2>/dev/null | tail -1 | sed 's/^ *//')"
  if [ -z "$diff_summary" ]; then
    local file_count
    file_count="$(git -C "$repo_dir" status --short 2>/dev/null | wc -l | tr -d ' ')"
    diff_summary="$file_count file(s) changed"
  fi
  printf 'mcrepo push: %s on %s (%s)' "$repo_name" "$branch_name" "$diff_summary"
}

# --- Coordinated-commit helpers (shared by cmd_commit, cmd_merge, cmd_branch) ---

# Batch id: UTC timestamp + short random suffix. The suffix keeps two batches
# created in the same second (or by parallel invocations) distinguishable —
# the batch id is the identity that groups a coordinated commit for revert.
mcrepo_new_batch_id() { printf '%s-%04x' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$((RANDOM ^ $$))"; }

# Next coordinated-commit number: max #N reachable from HEAD across ALL given
# repo dirs, + 1. Counting only the meta-context (the old behavior) reused N
# whenever a batch touched no meta files. Defaults to "." when no dirs given.
mcrepo_next_seq() {
  local max=0 dir n
  [ "$#" -gt 0 ] || set -- .
  for dir in "$@"; do
    n="$(git -C "$dir" log --format='%s' 2>/dev/null \
      | sed -n 's/^mcrepo commit #\([0-9][0-9]*\) @.*/\1/p' \
      | sort -rn | head -1)"
    [ -n "$n" ] && [ "$n" -gt "$max" ] && max="$n"
  done
  printf '%d' "$((max + 1))"
}

mcrepo_commit_subject() {
  local seq="$1" batch="$2" msg="$3"
  [ -z "$msg" ] && msg="stopping point"
  printf 'mcrepo commit #%s @%s: %s' "$seq" "$batch" "$msg"
}

mcrepo_parse_batch_id() {
  printf '%s' "$1" | sed -n 's/^mcrepo commit #[0-9][0-9]* @\([^ ]*\):.*/\1/p'
}

mcrepo_parse_n() {
  printf '%s' "$1" | sed -n 's/^mcrepo commit #\([0-9][0-9]*\) @[^ ]*:.*/\1/p'
}

# git add -A && git commit -m <subject>. Returns 0 on success or clean-after-add.
# Args: repo_dir label subject
mcrepo_do_commit() {
  local dir="$1" label="$2" subject="$3"
  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet; then
    log "  $label: nothing to commit (clean after add)"
    return 0
  fi
  if git -C "$dir" commit -m "$subject" >/dev/null; then
    log "  $label: committed"
    return 0
  fi
  warn "$label: commit failed"
  return 1
}

cmd_list() {
  load_repos
  if [ -n "$GLOBAL_BRANCH" ]; then
    log "Global branch: $GLOBAL_BRANCH"
  else
    log "Global branch: (off - per-repo branches)"
  fi
  local i local_state branch repo_dir parent_info
  for i in "${!REPO_NAMES[@]}"; do
    repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    if is_repo_local "$i"; then
      local_state="🌱"
    elif [ -d "$repo_dir/.git" ]; then
      local_state="yes"
    else
      local_state="no"
    fi
    branch="$(repo_branch "$repo_dir")"
    parent_info=""
    if [ -n "${REPO_PARENTS[$i]:-}" ]; then
      parent_info=" parent=${REPO_PARENTS[$i]}"
    fi
    printf '%-20s mode=%-5s local=%-3s branch=%s%s\n' "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}" "$local_state" "$branch" "$parent_info"
  done
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local meta_branch meta_parent_info
    meta_branch="$(repo_branch ".")"
    meta_parent_info=""
    if [ -n "$META_PARENT" ]; then
      meta_parent_info=" parent=$META_PARENT"
    fi
    printf '%-20s %-11s local=%-3s branch=%s%s\n' "(meta-context)" "" "yes" "$meta_branch" "$meta_parent_info"
  fi
}

cmd_status() {
  load_repos
  if [ -n "$GLOBAL_BRANCH" ]; then
    log "Global branch: $GLOBAL_BRANCH"
  else
    log "Global branch: (off - per-repo branches)"
  fi
  local i local_state branch dirty repo_dir parent_info upstream inprogress extras
  for i in "${!REPO_NAMES[@]}"; do
    repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    if is_repo_local "$i"; then
      local_state="🌱"
    elif [ -d "$repo_dir/.git" ]; then
      local_state="yes"
    else
      local_state="no"
    fi
    branch="$(repo_branch "$repo_dir")"
    dirty="$(repo_dirty_state "$repo_dir")"
    parent_info=""
    if [ -n "${REPO_PARENTS[$i]:-}" ]; then
      parent_info=" parent=${REPO_PARENTS[$i]}"
    fi
    extras=""
    if [ "$local_state" = "yes" ]; then
      upstream="$(repo_upstream_state "$repo_dir")"
      [ -n "$upstream" ] && extras="$extras upstream=$upstream"
      inprogress="$(repo_inprogress_state "$repo_dir")"
      [ -n "$inprogress" ] && extras="$extras inprogress=$inprogress"
      local stash_count mstash_count
      stash_count="$(git -C "$repo_dir" stash list 2>/dev/null | grep -c . || true)"
      [ "${stash_count:-0}" -gt 0 ] && extras="$extras stash=$stash_count"
      mstash_count="$(repo_mcrepo_stash_count "$repo_dir")"
      [ "${mstash_count:-0}" -gt 0 ] && extras="$extras mcrepo-stash=$mstash_count"
      if [ -n "$GLOBAL_BRANCH" ] && [ "${REPO_MODES[$i]}" != "sleep" ] && [ -n "$branch" ] && [ "$branch" != "$GLOBAL_BRANCH" ]; then
        extras="$extras OFF-GLOBAL"
      fi
    elif [ "$local_state" = "🌱" ]; then
      extras="$extras incubator"
    fi
    printf '%-20s mode=%-5s local=%-3s branch=%-20s state=%s%s%s\n' "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}" "$local_state" "$branch" "$dirty" "$extras" "$parent_info"
  done
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local meta_branch meta_dirty meta_parent_info meta_upstream meta_inprogress meta_extras
    meta_branch="$(repo_branch ".")"
    meta_dirty="$(repo_dirty_state ".")"
    meta_parent_info=""
    if [ -n "$META_PARENT" ]; then
      meta_parent_info=" parent=$META_PARENT"
    fi
    meta_extras=""
    meta_upstream="$(repo_upstream_state ".")"
    [ -n "$meta_upstream" ] && meta_extras="$meta_extras upstream=$meta_upstream"
    meta_inprogress="$(repo_inprogress_state ".")"
    [ -n "$meta_inprogress" ] && meta_extras="$meta_extras inprogress=$meta_inprogress"
    local meta_stash_count meta_mstash_count
    meta_stash_count="$(git -C . stash list 2>/dev/null | grep -c . || true)"
    [ "${meta_stash_count:-0}" -gt 0 ] && meta_extras="$meta_extras stash=$meta_stash_count"
    meta_mstash_count="$(repo_mcrepo_stash_count ".")"
    [ "${meta_mstash_count:-0}" -gt 0 ] && meta_extras="$meta_extras mcrepo-stash=$meta_mstash_count"
    if [ -n "$GLOBAL_BRANCH" ] && [ -n "$meta_branch" ] && [ "$meta_branch" != "$GLOBAL_BRANCH" ]; then
      meta_extras="$meta_extras OFF-GLOBAL"
    fi
    printf '%-20s %-11s local=%-3s branch=%-20s state=%s%s%s\n' "(meta-context)" "" "yes" "$meta_branch" "$meta_dirty" "$meta_extras" "$meta_parent_info"
  fi
}

# Resume or abort a single repo's mid-operation. action is "continue" or "abort".
# Returns 0 = handled cleanly, 1 = no in-progress state found,
#         2 = handled but the repo is still stuck (conflicts remain).
_resume_inprogress() {
  local repo_dir="$1"
  local repo_name="$2"
  local action="$3"
  local state
  state="$(repo_inprogress_state "$repo_dir")"
  case "$state" in
    MERGING)
      log "  $repo_name: git merge --$action"
      if git -C "$repo_dir" merge "--$action"; then return 0; fi
      warn "merge --$action failed in '$repo_name' (see git output above)"
      return 2
      ;;
    REBASING)
      log "  $repo_name: git rebase --$action"
      if git -C "$repo_dir" rebase "--$action"; then return 0; fi
      warn "rebase --$action failed in '$repo_name' (see git output above)"
      return 2
      ;;
    CHERRY-PICKING)
      log "  $repo_name: git cherry-pick --$action"
      if git -C "$repo_dir" cherry-pick "--$action"; then return 0; fi
      warn "cherry-pick --$action failed in '$repo_name' (see git output above)"
      return 2
      ;;
    REVERTING)
      log "  $repo_name: git revert --$action"
      if git -C "$repo_dir" revert "--$action"; then return 0; fi
      warn "revert --$action failed in '$repo_name' (see git output above)"
      return 2
      ;;
    CONFLICTED)
      # Unmerged files with no op marker: squash-merge or stash-pop conflict.
      if [ "$action" = "abort" ]; then
        log "  $repo_name: git reset --merge (dropping unmerged entries; stashes are preserved)"
        git -C "$repo_dir" reset --merge || warn "reset --merge failed in '$repo_name' (see git output above)"
        return 0
      fi
      warn "$repo_name: unmerged files but no merge/rebase in progress (squash-merge or stash-pop conflict):"
      git -C "$repo_dir" diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/    /' >&2 || true
      warn "  Resolve them, 'git -C $repo_dir add' the files, then finish per 'mcrepo resolve'."
      return 2
      ;;
    *)
      return 1
      ;;
  esac
}

# After continue/abort handled the git-native states, surface leftover mcrepo
# stashes ("mcrepo: carry to ...", "mcrepo: auto-stash before rebase") in repos
# that are no longer mid-operation. Never auto-pop/auto-drop: git state alone
# cannot tell "still needs popping" from "popped with conflict, already
# applied". Increments the global _INPROGRESS_HANDLED per repo surfaced.
_finalize_mcrepo_stashes() {
  local i repo_dir count
  local -a names=() dirs=()
  for i in "${!REPO_NAMES[@]}"; do
    [ "${REPO_MODES[$i]}" != "sleep" ] || continue
    repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    [ -d "$repo_dir/.git" ] || continue
    names+=("${REPO_NAMES[$i]}")
    dirs+=("$repo_dir")
  done
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    names+=("(meta-context)")
    dirs+=(".")
  fi
  for i in "${!names[@]}"; do
    [ -z "$(repo_inprogress_state "${dirs[$i]}")" ] || continue
    count="$(repo_mcrepo_stash_count "${dirs[$i]}")"
    [ "${count:-0}" -gt 0 ] || continue
    _INPROGRESS_HANDLED=$((_INPROGRESS_HANDLED + 1))
    warn "${names[$i]}: $count leftover mcrepo stash(es):"
    git -C "${dirs[$i]}" stash list 2>/dev/null | grep 'mcrepo:' | sed 's/^/    /' >&2 || true
    if confirm "  Pop the top stash in '${names[$i]}' now (drop it instead if its changes were already applied)?" n; then
      if git -C "${dirs[$i]}" stash pop; then
        log "  ${names[$i]}: stash popped"
      else
        warn "  Stash pop conflicted in '${names[$i]}'. Resolve, 'git -C ${dirs[$i]} add', then 'git -C ${dirs[$i]} stash drop'."
      fi
    else
      warn "  Left as-is. Apply with 'git -C ${dirs[$i]} stash pop' or discard with 'git -C ${dirs[$i]} stash drop'."
    fi
  done
}

# Iterate write+read repos plus meta-context, applying continue/abort to any
# repo that is mid-merge, mid-rebase, mid-cherry-pick, mid-revert, or holding
# marker-less conflicts (CONFLICTED). Returns 2 while conflicts remain.
_iterate_inprogress() {
  local action="$1"
  load_repos
  _INPROGRESS_HANDLED=0
  local rc i repo_dir
  local -a still_stuck=()
  for i in "${!REPO_NAMES[@]}"; do
    [ "${REPO_MODES[$i]}" != "sleep" ] || continue
    repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    [ -d "$repo_dir/.git" ] || continue
    rc=0
    _resume_inprogress "$repo_dir" "${REPO_NAMES[$i]}" "$action" || rc=$?
    if [ "$rc" -ne 1 ]; then
      _INPROGRESS_HANDLED=$((_INPROGRESS_HANDLED + 1))
      [ "$rc" -eq 2 ] && still_stuck+=("${REPO_NAMES[$i]}|$repo_dir")
    fi
  done
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    rc=0
    _resume_inprogress "." "(meta-context)" "$action" || rc=$?
    if [ "$rc" -ne 1 ]; then
      _INPROGRESS_HANDLED=$((_INPROGRESS_HANDLED + 1))
      [ "$rc" -eq 2 ] && still_stuck+=("(meta-context)|.")
    fi
  fi
  _finalize_mcrepo_stashes
  if [ "$_INPROGRESS_HANDLED" -eq 0 ]; then
    log "No repository is mid-merge / mid-rebase / mid-cherry-pick / mid-revert."
    return 0
  fi
  if [ "${#still_stuck[@]}" -gt 0 ]; then
    warn "Conflicts remain in: $(printf '%s ' "${still_stuck[@]%%|*}")"
    warn "Run 'mcrepo resolve' for a paste-ready coding-agent prompt."
    if [ "$action" = "continue" ]; then
      scan_stuck_states
      print_stuck_prompts stderr
    fi
    return 2
  fi
  if [ "$action" = "continue" ]; then
    log "Next: 'mcrepo status' to verify; if you were syncing, re-run 'mcrepo rebase', then 'mcrepo merge'."
  else
    log "Next: 'mcrepo status' to verify the clean state."
  fi
  return 0
}

# Scan all active repos + meta-context for stuck states. Fills the parallel
# arrays STUCK_NAMES / STUCK_DIRS / STUCK_KINDS / STUCK_SITS, where kind is a
# repo_inprogress_state value or MCREPO-STASH, and sit is the matching
# _emit_agent_prompt_body situation id.
scan_stuck_states() {
  STUCK_NAMES=()
  STUCK_DIRS=()
  STUCK_KINDS=()
  STUCK_SITS=()
  local i repo_dir
  local -a names=() dirs=()
  for i in "${!REPO_NAMES[@]}"; do
    [ "${REPO_MODES[$i]}" != "sleep" ] || continue
    repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    [ -d "$repo_dir/.git" ] || continue
    names+=("${REPO_NAMES[$i]}")
    dirs+=("$repo_dir")
  done
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    names+=("(meta-context)")
    dirs+=(".")
  fi
  local kind sit mstash
  for i in "${!names[@]}"; do
    kind="$(repo_inprogress_state "${dirs[$i]}")"
    # A bisect is a user-driven debugging session, not an mcrepo conflict:
    # continue/abort cannot advance it (finish with 'git bisect reset') and it
    # must not block coordinated commands. status still shows BISECTING.
    [ "$kind" = "BISECTING" ] && kind=""
    mstash="$(repo_mcrepo_stash_count "${dirs[$i]}")"
    if [ -z "$kind" ]; then
      [ "${mstash:-0}" -gt 0 ] || continue
      kind="MCREPO-STASH"
    fi
    case "$kind" in
      REBASING) sit="rebase-conflict" ;;
      MERGING|CHERRY-PICKING|REVERTING) sit="merge-conflict" ;;
      CONFLICTED)
        if git -C "${dirs[$i]}" stash list 2>/dev/null | grep -q 'mcrepo: carry to '; then
          sit="carry-conflict"
        elif [ "${mstash:-0}" -gt 0 ]; then
          sit="stash-conflict"
        else
          sit="merge-conflict"
        fi
        ;;
      MCREPO-STASH)
        if git -C "${dirs[$i]}" stash list 2>/dev/null | grep -q 'mcrepo: carry to '; then
          sit="carry-conflict"
        else
          sit="stash-conflict"
        fi
        ;;
      *) sit="merge-conflict" ;;
    esac
    STUCK_NAMES+=("${names[$i]}")
    STUCK_DIRS+=("${dirs[$i]}")
    STUCK_KINDS+=("$kind")
    STUCK_SITS+=("$sit")
  done
}

# Group the STUCK_* entries by situation and print one agent prompt per group.
# mode "stdout": raw prompt bodies to stdout (the 'mcrepo resolve' contract).
# mode "stderr": framed prompts via print_agent_recovery_prompt.
print_stuck_prompts() {
  local mode="$1"
  local sit i first=1
  for sit in rebase-conflict merge-conflict stash-conflict carry-conflict; do
    local -a entries=()
    for i in "${!STUCK_SITS[@]}"; do
      [ "${STUCK_SITS[$i]}" = "$sit" ] || continue
      entries+=("${STUCK_NAMES[$i]}|${STUCK_DIRS[$i]}")
    done
    [ "${#entries[@]}" -gt 0 ] || continue
    if [ "$mode" = "stdout" ]; then
      [ "$first" -eq 1 ] || printf '\n============================================================\n\n'
      first=0
      _emit_agent_prompt_body "$sit" "${entries[@]}"
    else
      print_agent_recovery_prompt "$sit" "${entries[@]}"
    fi
  done
}

# Coordinated operations must not run over a workspace with unresolved
# conflicts or paused git operations — stashing unmerged files, committing
# conflict markers, or rebasing a paused rebase only deepens the mess (the
# classic "some repos pulled, some stuck" state). Leftover mcrepo stashes
# (MCREPO-STASH) do NOT block: they are pending work, and 'mcrepo branch'
# re-runs restore carry stashes itself.
_require_no_stuck_repos() {
  local cmd_label="$1"
  scan_stuck_states
  local i blocked=0
  for i in "${!STUCK_KINDS[@]}"; do
    [ "${STUCK_KINDS[$i]}" = "MCREPO-STASH" ] && continue
    if [ "$blocked" -eq 0 ]; then
      warn "Cannot run 'mcrepo $cmd_label' — these repos are mid-operation or conflicted:"
      blocked=1
    fi
    warn "  - ${STUCK_NAMES[$i]}  (${STUCK_KINDS[$i]})"
  done
  [ "$blocked" -eq 0 ] && return 0
  die "Finish them first: 'mcrepo resolve' prints the procedure (and a coding-agent prompt); then 'mcrepo continue' or 'mcrepo abort'."
}

cmd_continue() {
  if [ "$#" -gt 0 ]; then
    die "Unknown continue option: $1"
  fi
  _iterate_inprogress continue
}

cmd_abort() {
  if [ "$#" -gt 0 ]; then
    die "Unknown abort option: $1"
  fi
  _iterate_inprogress abort
}

# Read-only diagnosis: report every stuck repo (mid-operation, marker-less
# conflicts, leftover mcrepo stashes) and print the matching paste-ready
# coding-agent prompt(s) on stdout ('mcrepo resolve | pbcopy' works).
cmd_resolve() {
  if [ "$#" -gt 0 ]; then
    die "Unknown resolve option: $1"
  fi
  load_repos
  scan_stuck_states
  if [ "${#STUCK_NAMES[@]}" -eq 0 ]; then
    log "Nothing to resolve - no repo is mid-operation, conflicted, or holding mcrepo stashes." >&2
    return 0
  fi
  {
    log "Stuck repos:"
    local i
    for i in "${!STUCK_NAMES[@]}"; do
      printf '  %-20s %-13s (cd %s)\n' "${STUCK_NAMES[$i]}" "${STUCK_KINDS[$i]}" "${STUCK_DIRS[$i]}"
    done
    log ""
    log "Paste the prompt below to your local coding agent (or pipe: mcrepo resolve | pbcopy):"
  } >&2
  print_stuck_prompts stdout
}

# Guard for 'pull --reset': a hard reset that would discard COMMITTED work
# needs its own approval — the Phase-2 prompt only covers uncommitted changes.
# Returns 0 when resetting is approved, 1 when the repo must be skipped.
confirm_reset_discard_commits() {
  local rd="$1" rn="$2" rb="$3" assume_yes="$4"
  local ahead
  ahead="$(git -C "$rd" rev-list --count "origin/$rb..HEAD" 2>/dev/null || printf '0')"
  [ "${ahead:-0}" -gt 0 ] || return 0

  warn "'$rn': reset to origin/$rb would DISCARD $ahead local commit(s):"
  git -C "$rd" log --oneline "origin/$rb..HEAD" 2>/dev/null | head -10 | while IFS= read -r _lost; do
    warn "    $_lost"
  done
  if [ "$assume_yes" -eq 1 ]; then
    warn "  Discarding due to --yes."
    return 0
  fi
  if [ -t 0 ] && [ -t 1 ]; then
    confirm "Discard these commits in '$rn'? This cannot be undone." n
    return $?
  fi
  warn "  Non-interactive: keeping '$rn' untouched. Re-run with 'mcrepo pull --reset --yes' to discard."
  return 1
}

# One repo's pull-integrate step (the 'mcrepo pull' default), shared by
# sub-repos and the meta-context.
# The origin-side twin of 'mcrepo rebase': auto-stash dirty work, then either
# fast-forward or REALLY rebase local commits onto the upstream (the
# multi-device case — this device's commits replay on top of what another
# device pushed). Exception: when the divergence is provably a local
# 'mcrepo rebase' rebase (origin holds only stale pre-rebase history), rebasing
# onto it would resurrect the old commits — those repos are routed to
# 'mcrepo push' instead. Appends to the caller's result arrays (bash dynamic
# scoping): updated_repos, rebased_onto_origin, rebase_conflict_repos/_entries,
# stash_conflict_repos/_entries, diverged_rebased, failed_repos.
_pull_one_rebase() {
  local rd="$1" rn="$2" rb="$3" rp="$4" rdirty="$5"
  local stashed=0
  if [ "$rdirty" = "dirty" ]; then
    if _mcrepo_stash_push "$rd" "mcrepo: auto-stash before pull"; then
      stashed=1
    fi
  fi
  local class
  class="$(classify_divergence "$rd" "$rb" "$rp")"
  case "$class" in
    safe-force)
      [ "$stashed" -eq 1 ] && { git -C "$rd" stash pop 2>/dev/null || true; }
      diverged_rebased+=("$rn|$rd")
      return 0
      ;;
    ambiguous)
      # The remote may hold BOTH our stale pre-rebase history AND new work
      # stacked on it - rebasing could resurrect the old commits, forcing
      # could delete the new ones. Hand it to a human/agent untouched.
      [ "$stashed" -eq 1 ] && { git -C "$rd" stash pop 2>/dev/null || true; }
      diverged_conflict+=("$rn|$rd")
      warn "'$rn': diverged in a way mcrepo cannot prove safe — not rebasing, not force-publishing."
      return 0
      ;;
    remote-work)
      local upstream_ref
      upstream_ref="$(git -C "$rd" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
      [ -n "$upstream_ref" ] || upstream_ref="origin/$rb"
      log "Rebasing '$rn' onto $upstream_ref (remote has new work) ..."
      if ! git -C "$rd" rebase "$upstream_ref"; then
        rebase_conflict_repos+=("$rn")
        rebase_conflict_entries+=("$rn|$rd")
        warn "  Rebase conflicts in '$rn' while integrating $upstream_ref."
        if [ "$stashed" -eq 1 ]; then
          warn "  Resolve, run 'mcrepo continue' (or 'git -C $rd rebase --continue'), then 'git -C $rd stash pop'."
        else
          warn "  Resolve, then run 'mcrepo continue' (or 'git -C $rd rebase --continue')."
        fi
        return 0
      fi
      ;;
    *)
      # none (in-sync/ahead-only/no-upstream) or behind-only: plain fast-forward.
      if ! run_with_repo_prefix "$rn" git -C "$rd" pull --ff-only; then
        [ "$stashed" -eq 1 ] && { git -C "$rd" stash pop 2>/dev/null || true; }
        warn "Pull failed for '$rn'"
        failed_repos+=("$rn")
        return 0
      fi
      ;;
  esac
  if [ "$stashed" -eq 1 ]; then
    if ! git -C "$rd" stash pop 2>/dev/null; then
      warn "Stash pop conflict in '$rn'. Stash preserved — resolve, 'git -C $rd add', then 'git -C $rd stash drop'."
      stash_conflict_repos+=("$rn")
      stash_conflict_entries+=("$rn|$rd")
      return 0
    fi
  fi
  if [ "$class" = "remote-work" ]; then
    rebased_onto_origin+=("$rn")
    log "  '$rn': local commits now sit on top of the remote work."
  else
    updated_repos+=("$rn")
  fi
  return 0
}

cmd_pull() {
  # Default is INTEGRATE: auto-stash dirty work + rebase local commits onto
  # origin (the multi-device workflow). '--ff-only' opts into the conservative
  # pull: fast-forward only, dirty repos skipped, never stashes or rebases.
  local pull_mode="rebase"
  local assume_yes=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ff-only) pull_mode="ffonly" ;;
      --rebase)
        warn "Deprecation: '--rebase' is now the default 'mcrepo pull' behavior ('--ff-only' gives the old conservative pull)."
        pull_mode="rebase"
        ;;
      --reset) pull_mode="reset" ;;
      --yes|-y) assume_yes=1 ;;
      *) die "Unknown pull option: $1" ;;
    esac
    shift
  done

  load_repos
  _require_no_stuck_repos "pull"

  # --- Phase 1: Pre-flight - collect target repos ---
  local -a pull_dirs=()
  local -a pull_names=()
  local -a pull_branches=()
  local -a pull_dirty=()
  local -a pull_has_upstream=()
  local -a pull_parents=()

  local i repo_dir branch dirty
  for i in "${!REPO_NAMES[@]}"; do
    [ "${REPO_MODES[$i]}" != "sleep" ] || continue
    repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    [ -d "$repo_dir/.git" ] || continue
    branch="$(repo_branch "$repo_dir")"
    dirty="$(repo_dirty_state "$repo_dir")"
    local has_up=0
    if git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      has_up=1
    fi
    local pparent="${REPO_PARENTS[$i]##*,}"
    [ -n "$pparent" ] || pparent="$(detect_default_branch "$repo_dir")"
    pull_dirs+=("$repo_dir")
    pull_names+=("${REPO_NAMES[$i]}")
    pull_branches+=("$branch")
    pull_dirty+=("$dirty")
    pull_has_upstream+=("$has_up")
    pull_parents+=("$pparent")
  done

  # Meta-context repo
  local meta_dir="" meta_branch="" meta_dirty="" meta_has_upstream=0
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    meta_dir="."
    meta_branch="$(repo_branch ".")"
    meta_dirty="$(repo_dirty_state ".")"
    if git -C . rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      meta_has_upstream=1
    fi
  fi

  if [ "${#pull_dirs[@]}" -eq 0 ] && [ -z "$meta_dir" ]; then
    log "No active repos to pull."
    return 0
  fi

  # --- Phase 2: Handle --reset confirmation ---
  if [ "$pull_mode" = "reset" ]; then
    local -a reset_dirty_names=()
    for i in "${!pull_dirs[@]}"; do
      [ "${pull_dirty[$i]}" = "dirty" ] && reset_dirty_names+=("${pull_names[$i]}")
    done
    [ -n "$meta_dir" ] && [ "$meta_dirty" = "dirty" ] && reset_dirty_names+=("(meta-context)")

    if [ "${#reset_dirty_names[@]}" -gt 0 ]; then
      warn "WARNING: This will DISCARD all uncommitted changes in:"
      for rn in "${reset_dirty_names[@]}"; do
        warn "  $rn"
      done
      warn ""
      if [ "$assume_yes" -ne 1 ]; then
        if [ ! -t 0 ] || [ ! -t 1 ]; then
          die "pull --reset requires interactive confirmation (or --yes). Aborting."
        fi
        if ! confirm "This action cannot be undone. Proceed?" n; then
          log "Aborted."
          return 0
        fi
      fi
    fi
  fi

  # --- Phase 3: Plan display ---
  log "=== Pull ==="
  for i in "${!pull_dirs[@]}"; do
    local action
    if [ "${pull_has_upstream[$i]}" -eq 0 ]; then
      action="fetch only (no upstream)"
    elif [ "$pull_mode" = "ffonly" ] && [ "${pull_dirty[$i]}" = "dirty" ]; then
      action="fetch only (dirty)"
    elif [ "$pull_mode" = "reset" ]; then
      if [ "${pull_dirty[$i]}" = "dirty" ]; then
        action="discard + reset"
      else
        action="fetch + pull"
      fi
    elif [ "$pull_mode" = "rebase" ]; then
      if [ "${pull_dirty[$i]}" = "dirty" ]; then
        action="stash + rebase onto origin + pop"
      else
        action="fetch + rebase onto origin"
      fi
    else
      action="fetch + pull"
    fi
    printf '  %-20s branch=%-20s state=%-6s -> %s\n' "${pull_names[$i]}" "${pull_branches[$i]}" "${pull_dirty[$i]}" "$action"
  done
  if [ -n "$meta_dir" ]; then
    local meta_action
    if [ "$meta_has_upstream" -eq 0 ]; then
      meta_action="fetch only (no upstream)"
    elif [ "$pull_mode" = "reset" ] && [ "$meta_dirty" = "dirty" ]; then
      meta_action="discard + reset"
    elif [ "$pull_mode" = "rebase" ]; then
      if [ "$meta_dirty" = "dirty" ]; then
        meta_action="stash + rebase onto origin + pop"
      else
        meta_action="fetch + rebase onto origin"
      fi
    elif [ "$meta_dirty" = "dirty" ]; then
      meta_action="stash + pull + pop"
    else
      meta_action="fetch + pull"
    fi
    printf '  %-20s branch=%-20s state=%-6s -> %s\n' "(meta-context)" "$meta_branch" "$meta_dirty" "$meta_action"
  fi
  log ""

  # --- Phase 4: Execution ---
  local -a updated_repos=()
  local -a fetch_only_repos=()
  local -a stash_conflict_repos=()
  local -a stash_conflict_entries=()   # name|dir (for the agent recovery prompt)
  local -a rebase_conflict_repos=()    # --rebase: rebase paused on conflicts
  local -a rebase_conflict_entries=()  # name|dir
  local -a rebased_onto_origin=()      # --rebase: local commits replayed on top of remote work
  local -a failed_repos=()
  local -a diverged_rebased=()   # safe-force: rebased locally, just needs publishing
  local -a diverged_conflict=()  # remote-work: needs human/agent review (default mode)
  local -a reset_declined=()     # user declined discarding committed work (not a failure)
  local had_dirty=0

  for i in "${!pull_dirs[@]}"; do
    local rd="${pull_dirs[$i]}"
    local rn="${pull_names[$i]}"
    local rb="${pull_branches[$i]}"
    local rdirty="${pull_dirty[$i]}"
    local rup="${pull_has_upstream[$i]}"
    local rp="${pull_parents[$i]}"

    # Always fetch
    if ! git -C "$rd" fetch origin --prune 2>/dev/null; then
      warn "Fetch failed for '$rn'"
      failed_repos+=("$rn")
      continue
    fi

    if [ "$rup" -eq 0 ]; then
      fetch_only_repos+=("$rn (no upstream)")
      continue
    fi

    if [ "$pull_mode" = "reset" ] && [ "$rdirty" = "dirty" ]; then
      git -C "$rd" checkout -- . 2>/dev/null || true
      git -C "$rd" clean -fd 2>/dev/null || true
      if run_with_repo_prefix "$rn" git -C "$rd" pull --ff-only; then
        updated_repos+=("$rn")
      else
        # Diverged: hard reset to origin — but committed work needs its own approval
        if ! confirm_reset_discard_commits "$rd" "$rn" "$rb" "$assume_yes"; then
          reset_declined+=("$rn")
          continue
        fi
        git -C "$rd" reset --hard "origin/$rb" 2>/dev/null || { warn "Reset failed for '$rn'"; failed_repos+=("$rn"); continue; }
        updated_repos+=("$rn")
      fi
      continue
    fi

    if [ "$pull_mode" = "reset" ] && [ "$rdirty" = "clean" ]; then
      if run_with_repo_prefix "$rn" git -C "$rd" pull --ff-only; then
        updated_repos+=("$rn")
      else
        # Clean but diverged: the reset would silently drop committed work
        if ! confirm_reset_discard_commits "$rd" "$rn" "$rb" "$assume_yes"; then
          reset_declined+=("$rn")
          continue
        fi
        git -C "$rd" reset --hard "origin/$rb" 2>/dev/null || { warn "Reset failed for '$rn'"; failed_repos+=("$rn"); continue; }
        updated_repos+=("$rn")
      fi
      continue
    fi

    if [ "$pull_mode" = "rebase" ]; then
      _pull_one_rebase "$rd" "$rn" "$rb" "$rp" "$rdirty"
      continue
    fi

    if [ "$rdirty" = "dirty" ]; then
      had_dirty=1
      fetch_only_repos+=("$rn (dirty)")
      continue
    fi

    # Default mode, clean repo: ff-only pull
    if run_with_repo_prefix "$rn" git -C "$rd" pull --ff-only; then
      updated_repos+=("$rn")
    else
      case "$(classify_divergence "$rd" "$rb" "$rp")" in
        safe-force) diverged_rebased+=("$rn|$rd") ;;
        remote-work|ambiguous) diverged_conflict+=("$rn|$rd") ;;
        *) warn "Pull failed for '$rn' (diverged or conflict)"; failed_repos+=("$rn") ;;
      esac
    fi
  done

  # Meta-context repo
  if [ -n "$meta_dir" ]; then
    local meta_pull_parent="${META_PARENT##*,}"
    [ -n "$meta_pull_parent" ] || meta_pull_parent="$(detect_default_branch ".")"
    if ! git -C . fetch origin --prune 2>/dev/null; then
      warn "Fetch failed for (meta-context)"
      failed_repos+=("(meta-context)")
    elif [ "$meta_has_upstream" -eq 0 ]; then
      fetch_only_repos+=("(meta-context) (no upstream)")
    elif [ "$pull_mode" = "reset" ] && [ "$meta_dirty" = "dirty" ]; then
      git -C . checkout -- . 2>/dev/null || true
      git -C . clean -fd 2>/dev/null || true
      if run_with_repo_prefix "(meta-context)" git -C . pull --ff-only; then
        updated_repos+=("(meta-context)")
      elif ! confirm_reset_discard_commits "." "(meta-context)" "$meta_branch" "$assume_yes"; then
        reset_declined+=("(meta-context)")
      else
        git -C . reset --hard "origin/$meta_branch" 2>/dev/null || { warn "Reset failed for (meta-context)"; failed_repos+=("(meta-context)"); }
        updated_repos+=("(meta-context)")
      fi
    elif [ "$pull_mode" = "rebase" ]; then
      _pull_one_rebase "." "(meta-context)" "$meta_branch" "$meta_pull_parent" "$meta_dirty"
    elif [ "$meta_dirty" = "dirty" ]; then
      # Meta-context always auto-stashes on dirty so generator/unrelated edits don't block its pull.
      local meta_stashed=0
      if _mcrepo_stash_push "." "mcrepo: auto-stash before pull"; then
        meta_stashed=1
      fi
      if run_with_repo_prefix "(meta-context)" git -C . pull --ff-only; then
        if [ "$meta_stashed" -eq 1 ]; then
          if ! git -C . stash pop 2>/dev/null; then
            warn "Stash pop conflict in (meta-context). Resolve, 'git add', then 'git stash drop'."
            stash_conflict_repos+=("(meta-context)")
            stash_conflict_entries+=("(meta-context)|.")
          else
            updated_repos+=("(meta-context)")
          fi
        else
          updated_repos+=("(meta-context)")
        fi
      else
        warn "Pull failed for (meta-context) (diverged). Restoring stash."
        [ "$meta_stashed" -eq 1 ] && git -C . stash pop 2>/dev/null || true
        case "$(classify_divergence "." "$meta_branch" "$meta_pull_parent")" in
          safe-force) diverged_rebased+=("(meta-context)|.") ;;
          remote-work|ambiguous) diverged_conflict+=("(meta-context)|.") ;;
          *) failed_repos+=("(meta-context)") ;;
        esac
      fi
    else
      if run_with_repo_prefix "(meta-context)" git -C . pull --ff-only; then
        updated_repos+=("(meta-context)")
      else
        case "$(classify_divergence "." "$meta_branch" "$meta_pull_parent")" in
          safe-force) diverged_rebased+=("(meta-context)|.") ;;
          remote-work|ambiguous) diverged_conflict+=("(meta-context)|.") ;;
          *) warn "Pull failed for (meta-context) (diverged or conflict)"; failed_repos+=("(meta-context)") ;;
        esac
      fi
    fi
  fi

  # --- Phase 5: Summary ---
  log "=== Pull summary ==="
  if [ "${#updated_repos[@]}" -gt 0 ]; then
    log "  Updated:          ${updated_repos[*]}"
  fi
  if [ "${#fetch_only_repos[@]}" -gt 0 ]; then
    log "  Fetch only:       ${fetch_only_repos[*]}"
  fi
  if [ "${#rebased_onto_origin[@]}" -gt 0 ]; then
    log "  Rebased onto origin: ${rebased_onto_origin[*]}"
  fi
  if [ "${#rebase_conflict_repos[@]}" -gt 0 ]; then
    warn "  Rebase conflicts: ${rebase_conflict_repos[*]}"
  fi
  if [ "${#stash_conflict_repos[@]}" -gt 0 ]; then
    warn "  Stash conflicts:  ${stash_conflict_repos[*]}"
  fi
  if [ "${#diverged_rebased[@]}" -gt 0 ]; then
    local dr
    local -a dr_names=()
    for dr in "${diverged_rebased[@]}"; do dr_names+=("${dr%%|*}"); done
    log "  Rebased locally:  ${dr_names[*]}"
  fi
  if [ "${#diverged_conflict[@]}" -gt 0 ]; then
    local dc
    local -a dc_names=()
    for dc in "${diverged_conflict[@]}"; do dc_names+=("${dc%%|*}"); done
    warn "  Diverged:         ${dc_names[*]}"
  fi
  if [ "${#reset_declined[@]}" -gt 0 ]; then
    log "  Reset declined (local commits preserved): ${reset_declined[*]}"
  fi
  if [ "${#failed_repos[@]}" -gt 0 ]; then
    warn "  Failed:           ${failed_repos[*]}"
  fi
  if [ "${#updated_repos[@]}" -eq 0 ] && [ "${#fetch_only_repos[@]}" -eq 0 ] && [ "${#failed_repos[@]}" -eq 0 ] && [ "${#stash_conflict_repos[@]}" -eq 0 ] && [ "${#diverged_rebased[@]}" -eq 0 ] && [ "${#diverged_conflict[@]}" -eq 0 ] && [ "${#rebased_onto_origin[@]}" -eq 0 ] && [ "${#rebase_conflict_repos[@]}" -eq 0 ]; then
    log "  Everything up to date."
  fi

  local pull_left_stuck=0
  if [ "${#stash_conflict_repos[@]}" -gt 0 ] || [ "${#rebase_conflict_repos[@]}" -gt 0 ]; then
    pull_left_stuck=1
  fi

  if [ "$had_dirty" -eq 1 ] && [ "$pull_mode" = "ffonly" ]; then
    log ""
    if [ "$pull_left_stuck" -eq 1 ]; then
      log "Some repos skipped (dirty, --ff-only). First resolve the conflicts above ('mcrepo resolve'),"
      log "then run 'mcrepo pull' to bring dirty repos along (or 'mcrepo pull --reset' to discard)."
    else
      log "Some repos skipped (dirty, --ff-only). Run 'mcrepo pull' to auto-stash and integrate them,"
      log "or 'mcrepo pull --reset' to discard local changes."
    fi
  fi

  if [ "${#diverged_rebased[@]}" -gt 0 ]; then
    log ""
    log "These branches were rebased locally and just need publishing — this is expected after"
    log "'mcrepo rebase', NOT remote work from another machine. They can't fast-forward because"
    log "the rebase rewrote their commit hashes. Run 'mcrepo push' to publish them (it will safely"
    log "force-with-lease the rebased branches):"
    local dr2
    for dr2 in "${diverged_rebased[@]}"; do
      log "  - ${dr2%%|*}"
    done
  fi

  if [ "${#diverged_conflict[@]}" -gt 0 ]; then
    log ""
    if [ "$pull_mode" = "rebase" ]; then
      log "These branches diverged in a way mcrepo will not auto-resolve — the remote may hold your"
      log "own pre-rebase history AND new work stacked on it. Rebasing could resurrect old commits,"
      log "force-pushing could delete the new ones. Review with the prompt below before deciding:"
    else
      log "These branches diverged AND their remote contains new work (e.g. pushed from another"
      log "device) — a fast-forward-only pull can't integrate that. Run 'mcrepo pull' (without"
      log "--ff-only) to put your local commits on top of the remote work, or review manually first:"
    fi
    local dc2
    for dc2 in "${diverged_conflict[@]}"; do
      log "  - ${dc2%%|*}"
    done
    if [ "$pull_mode" = "ffonly" ] && [ "$pull_left_stuck" -eq 1 ]; then
      log "(first resolve the conflicts above — coordinated commands refuse to run over conflicted repos)"
    fi
    print_agent_recovery_prompt ambiguous-divergence "${diverged_conflict[@]}"
  fi

  if [ "${#rebase_conflict_entries[@]}" -gt 0 ]; then
    print_agent_recovery_prompt pull-rebase-conflict "${rebase_conflict_entries[@]}"
    warn "Next: resolve the conflicts (prompt above), 'git add' the files, run 'mcrepo continue', then re-run 'mcrepo pull'."
  fi

  if [ "${#stash_conflict_entries[@]}" -gt 0 ]; then
    print_agent_recovery_prompt stash-conflict "${stash_conflict_entries[@]}"
  fi

  if [ "${#rebased_onto_origin[@]}" -gt 0 ] && [ "${#rebase_conflict_repos[@]}" -eq 0 ] && [ "${#stash_conflict_repos[@]}" -eq 0 ] && [ "${#failed_repos[@]}" -eq 0 ]; then
    log ""
    log "Next: 'mcrepo push' to publish — your local commits now sit on top of the remote work (plain push, no force needed)."
  fi

  # Exit-code contract: 0 = success, 2 = partial per-repo failure.
  if [ "${#failed_repos[@]}" -gt 0 ] || [ "${#stash_conflict_repos[@]}" -gt 0 ] || [ "${#diverged_conflict[@]}" -gt 0 ] || [ "${#rebase_conflict_repos[@]}" -gt 0 ]; then
    return 2
  fi
}

# Gather target repos (write; read if include_read=1) + meta-context.
# Populates global-named arrays: CC_DIRS, CC_NAMES, and scalar CC_META_DIR.
_cc_gather_targets() {
  local include_read="$1"
  CC_DIRS=()
  CC_NAMES=()
  CC_META_DIR=""
  local i mode repo_dir
  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    if [ "$mode" = "write" ] || { [ "$include_read" -eq 1 ] && [ "$mode" = "read" ]; }; then
      repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "$mode")"
      [ -d "$repo_dir/.git" ] || continue
      CC_DIRS+=("$repo_dir")
      CC_NAMES+=("${REPO_NAMES[$i]}")
    fi
  done
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CC_META_DIR="."
  fi
}

_commit_forward() {
  local user_msg="$1"
  local include_read="$2"

  _cc_gather_targets "$include_read"

  local -a dirty_dirs=()
  local -a dirty_names=()
  local i
  for i in "${!CC_DIRS[@]}"; do
    if [ -n "$(git -C "${CC_DIRS[$i]}" status --porcelain 2>/dev/null)" ]; then
      dirty_dirs+=("${CC_DIRS[$i]}")
      dirty_names+=("${CC_NAMES[$i]}")
    fi
  done
  local meta_dirty=0
  if [ -n "$CC_META_DIR" ] && [ -n "$(git -C . status --porcelain 2>/dev/null)" ]; then
    meta_dirty=1
  fi

  if [ "${#dirty_dirs[@]}" -eq 0 ] && [ "$meta_dirty" -eq 0 ]; then
    log "Nothing to commit."
    return 0
  fi

  # Branch-alignment warning (not a blocker): committing on the wrong branch
  # makes the batch hard to merge/revert later; revert refuses cross-branch.
  if [ -n "$GLOBAL_BRANCH" ]; then
    local -a off_branch=()
    local ob_branch
    for i in "${!dirty_dirs[@]}"; do
      ob_branch="$(repo_branch "${dirty_dirs[$i]}")"
      if [ -n "$ob_branch" ] && [ "$ob_branch" != "$GLOBAL_BRANCH" ]; then
        off_branch+=("${dirty_names[$i]} (on '$ob_branch')")
      fi
    done
    if [ "$meta_dirty" -eq 1 ]; then
      ob_branch="$(repo_branch ".")"
      if [ -n "$ob_branch" ] && [ "$ob_branch" != "$GLOBAL_BRANCH" ]; then
        off_branch+=("(meta-context) (on '$ob_branch')")
      fi
    fi
    if [ "${#off_branch[@]}" -gt 0 ]; then
      warn "Global branch is '$GLOBAL_BRANCH' but these repos are elsewhere: ${off_branch[*]}"
      warn "The commit proceeds, but consider 'mcrepo branch $GLOBAL_BRANCH' to re-align first."
    fi
  fi

  local batch seq subject
  batch="$(mcrepo_new_batch_id)"
  local -a seq_dirs=()
  seq_dirs=("${dirty_dirs[@]+"${dirty_dirs[@]}"}")
  [ "$meta_dirty" -eq 1 ] && seq_dirs+=(".")
  seq="$(mcrepo_next_seq "${seq_dirs[@]+"${seq_dirs[@]}"}")"
  subject="$(mcrepo_commit_subject "$seq" "$batch" "$user_msg")"

  log ""
  log "Coordinated commit #$seq @$batch"
  log "Subject: $subject"
  log "Repos to commit:"
  if [ "${#dirty_names[@]}" -gt 0 ]; then
    for n in "${dirty_names[@]}"; do
      log "  $n"
    done
  fi
  [ "$meta_dirty" -eq 1 ] && log "  (meta-context)"
  log ""

  if ! confirm "Proceed?" y; then
    log "Aborted."
    return 0
  fi

  local -a commit_fail_entries=()
  if [ "${#dirty_dirs[@]}" -gt 0 ]; then
    for i in "${!dirty_dirs[@]}"; do
      mcrepo_do_commit "${dirty_dirs[$i]}" "${dirty_names[$i]}" "$subject" || \
        commit_fail_entries+=("${dirty_names[$i]}|${dirty_dirs[$i]}")
    done
  fi
  if [ "$meta_dirty" -eq 1 ]; then
    mcrepo_do_commit "." "(meta-context)" "$subject" || \
      commit_fail_entries+=("(meta-context)|.")
  fi

  if [ "${#commit_fail_entries[@]}" -gt 0 ]; then
    warn "One or more commits failed. The batch is incomplete — finish it with the SAME subject."
    MCREPO_RECOVERY_CONTEXT="Coordinated commit subject (use verbatim): $subject"
    print_agent_recovery_prompt partial-commit "${commit_fail_entries[@]}"
    return 1
  fi
  log "Coordinated commit #$seq complete."
  if [ -n "$GLOBAL_BRANCH" ]; then
    log "Next: keep working (commit again anytime) — when the feature is done: 'mcrepo rebase', then 'mcrepo merge'."
  else
    log "Next: keep working (commit again anytime) — or 'mcrepo push' to publish."
  fi
}

_commit_revert() {
  local include_read="$1"
  local force="$2"

  _cc_gather_targets "$include_read"

  local -a all_dirs=() all_names=()
  local i
  if [ "${#CC_DIRS[@]}" -gt 0 ]; then
    for i in "${!CC_DIRS[@]}"; do
      all_dirs+=("${CC_DIRS[$i]}")
      all_names+=("${CC_NAMES[$i]}")
    done
  fi
  if [ -n "$CC_META_DIR" ]; then
    all_dirs+=(".")
    all_names+=("(meta-context)")
  fi

  if [ "${#all_dirs[@]}" -eq 0 ]; then
    die "No target repos to inspect."
  fi

  # Collect (N, batch_id, branch) per repo. Empty N means not coordinated.
  local -a head_n=() head_batch=() head_branches=()
  local max_n=0
  for i in "${!all_dirs[@]}"; do
    local subj n batch
    subj="$(git -C "${all_dirs[$i]}" log -1 --format=%s 2>/dev/null || printf '')"
    n="$(mcrepo_parse_n "$subj")"
    batch="$(mcrepo_parse_batch_id "$subj")"
    head_n+=("$n")
    head_batch+=("$batch")
    head_branches+=("$(repo_branch "${all_dirs[$i]}" 2>/dev/null || printf '')")
    if [ -n "$n" ] && [ "$n" -gt "$max_n" ]; then
      max_n="$n"
    fi
  done

  if [ "$max_n" -eq 0 ]; then
    die "No coordinated commit at HEAD in any target repo; nothing to revert."
  fi

  # Branch-alignment preflight (like merge/pr): #N sequence numbers are
  # per-branch counts and routinely repeat across branches, so a repo sitting
  # on a different branch than the rest must never be grouped into the peel.
  local revert_ref_branch=""
  if [ -n "$GLOBAL_BRANCH" ]; then
    revert_ref_branch="$GLOBAL_BRANCH"
  else
    for i in "${!all_dirs[@]}"; do
      if [ -n "${head_n[$i]}" ] && [ "${head_n[$i]}" -eq "$max_n" ]; then
        revert_ref_branch="${head_branches[$i]}"
        break
      fi
    done
  fi

  local -a peel_dirs=() peel_names=() peel_batches=()
  local -a skip_names=() skip_reasons=()
  for i in "${!all_dirs[@]}"; do
    if [ -n "${head_n[$i]}" ] && [ "${head_n[$i]}" -eq "$max_n" ]; then
      if [ -n "$revert_ref_branch" ] && [ "${head_branches[$i]}" != "$revert_ref_branch" ]; then
        skip_names+=("${all_names[$i]}")
        skip_reasons+=("on branch '${head_branches[$i]}' (expected '$revert_ref_branch') — not part of this batch")
        continue
      fi
      peel_dirs+=("${all_dirs[$i]}")
      peel_names+=("${all_names[$i]}")
      peel_batches+=("${head_batch[$i]}")
    elif [ -z "${head_n[$i]}" ]; then
      skip_names+=("${all_names[$i]}")
      skip_reasons+=("HEAD not coordinated")
    else
      skip_names+=("${all_names[$i]}")
      skip_reasons+=("HEAD at #${head_n[$i]} (< #$max_n)")
    fi
  done

  # Sanity: all peel repos must share the same batch id. A mismatch means the
  # #N grouping is provably wrong — hard-resetting across unrelated batches is
  # exactly the data loss this check exists to prevent.
  local ref_batch=""
  if [ "${#peel_batches[@]}" -gt 0 ]; then
    ref_batch="${peel_batches[0]}"
    local batch_mismatch=0
    local b
    for b in "${peel_batches[@]}"; do
      [ "$b" != "$ref_batch" ] && batch_mismatch=1
    done
    if [ "$batch_mismatch" -eq 1 ]; then
      if [ "$force" -eq 1 ]; then
        warn "Peel repos at #$max_n do not share a single batch id — proceeding due to --force."
      else
        die "Peel repos at #$max_n carry DIFFERENT batch ids — they are not one coordinated commit. Revert them per-repo manually, or re-run with --force to override."
      fi
    fi
  fi

  # Pushed-check: refuse without --force if HEAD == upstream anywhere in peel.
  if [ "$force" -ne 1 ] && [ "${#peel_dirs[@]}" -gt 0 ]; then
    local pushed_blockers=0
    for i in "${!peel_dirs[@]}"; do
      local rd="${peel_dirs[$i]}"
      if git -C "$rd" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
        local head_sha up_sha
        head_sha="$(git -C "$rd" rev-parse HEAD 2>/dev/null || printf '')"
        up_sha="$(git -C "$rd" rev-parse '@{u}' 2>/dev/null || printf '')"
        if [ -n "$head_sha" ] && [ "$head_sha" = "$up_sha" ]; then
          warn "HEAD is pushed in ${peel_names[$i]}."
          pushed_blockers=1
        fi
      fi
    done
    if [ "$pushed_blockers" -eq 1 ]; then
      die "Refusing to rewrite pushed history. Re-run with --force to proceed."
    fi
  fi

  log ""
  log "Would revert (git reset --hard HEAD~1) coordinated commit #$max_n @$ref_batch in:"
  if [ "${#peel_names[@]}" -gt 0 ]; then
    for n in "${peel_names[@]}"; do log "  $n"; done
  fi
  if [ "${#skip_names[@]}" -gt 0 ]; then
    log "Skipping (not at top):"
    for i in "${!skip_names[@]}"; do
      log "  ${skip_names[$i]} — ${skip_reasons[$i]}"
    done
  fi
  log ""

  if [ "$force" -ne 1 ]; then
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      die "Non-interactive run requires --force."
    fi
    if ! confirm "This is destructive. Proceed?" n; then
      log "Aborted."
      return 0
    fi
  fi

  if [ "${#peel_dirs[@]}" -gt 0 ]; then
    for i in "${!peel_dirs[@]}"; do
      if git -C "${peel_dirs[$i]}" reset --hard HEAD~1 >/dev/null; then
        log "  ${peel_names[$i]}: reverted"
      else
        warn "  ${peel_names[$i]}: reset failed"
      fi
    done
  fi
  log "Reverted coordinated commit #$max_n in ${#peel_dirs[@]} repo(s); ${#skip_names[@]} skipped."
}

_commit_reset() {
  local include_read="$1"
  local force="$2"

  _cc_gather_targets "$include_read"

  local -a dirty_dirs=() dirty_names=()
  local i
  if [ "${#CC_DIRS[@]}" -gt 0 ]; then
    for i in "${!CC_DIRS[@]}"; do
      if [ -n "$(git -C "${CC_DIRS[$i]}" status --porcelain 2>/dev/null)" ]; then
        dirty_dirs+=("${CC_DIRS[$i]}")
        dirty_names+=("${CC_NAMES[$i]}")
      fi
    done
  fi
  local meta_dirty=0
  if [ -n "$CC_META_DIR" ] && [ -n "$(git -C . status --porcelain 2>/dev/null)" ]; then
    meta_dirty=1
  fi

  if [ "${#dirty_dirs[@]}" -eq 0 ] && [ "$meta_dirty" -eq 0 ]; then
    log "Nothing to reset."
    return 0
  fi

  log ""
  warn "WARNING: This will DISCARD all uncommitted changes in:"
  if [ "${#dirty_names[@]}" -gt 0 ]; then
    for n in "${dirty_names[@]}"; do warn "  $n"; done
  fi
  [ "$meta_dirty" -eq 1 ] && warn "  (meta-context)"
  warn ""

  if [ "$force" -ne 1 ]; then
    if [ ! -t 0 ] || [ ! -t 1 ]; then
      die "Non-interactive run requires --force."
    fi
    if ! confirm "This action cannot be undone. Proceed?" n; then
      log "Aborted."
      return 0
    fi
  fi

  if [ "${#dirty_dirs[@]}" -gt 0 ]; then
    for i in "${!dirty_dirs[@]}"; do
      git -C "${dirty_dirs[$i]}" reset --hard HEAD >/dev/null 2>&1 || true
      git -C "${dirty_dirs[$i]}" clean -fd >/dev/null 2>&1 || true
      log "  ${dirty_names[$i]}: reset"
    done
  fi
  if [ "$meta_dirty" -eq 1 ]; then
    git -C . reset --hard HEAD >/dev/null 2>&1 || true
    git -C . clean -fd >/dev/null 2>&1 || true
    log "  (meta-context): reset"
  fi
}

cmd_commit() {
  local user_msg=""
  local include_read=0
  local do_revert=0
  local do_reset=0
  local force=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m) shift; user_msg="${1:-}"; [ -n "$user_msg" ] || die "-m requires a message" ;;
      --include-read) include_read=1 ;;
      --revert) do_revert=1 ;;
      --reset)  do_reset=1 ;;
      --force)  force=1 ;;
      -h|--help) log "Usage: mcrepo commit [-m <msg>] [--include-read]"; log "       mcrepo commit --revert [--include-read] [--force]"; log "       mcrepo commit --reset  [--include-read] [--force]"; return 0 ;;
      *) die "Unknown commit option: $1" ;;
    esac
    shift
  done
  if [ "$do_revert" -eq 1 ] && [ "$do_reset" -eq 1 ]; then
    die "--revert and --reset are mutually exclusive."
  fi
  if [ "$do_reset" -eq 1 ] && [ -n "$user_msg" ]; then
    die "--reset does not accept -m."
  fi
  if [ "$do_revert" -eq 1 ] && [ -n "$user_msg" ]; then
    die "--revert does not accept -m."
  fi

  load_repos
  _require_no_stuck_repos "commit"

  if   [ "$do_revert" -eq 1 ]; then _commit_revert "$include_read" "$force"
  elif [ "$do_reset"  -eq 1 ]; then _commit_reset  "$include_read" "$force"
  else                              _commit_forward "$user_msg"    "$include_read"
  fi
}

cmd_push() {
  local commit_message=""
  local do_fetch=1
  local allow_force=1
  local include_read=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m) shift; commit_message="${1:-}"; [ -n "$commit_message" ] || die "-m requires a message" ;;
      --no-fetch) do_fetch=0 ;;
      --no-force) allow_force=0 ;;
      --include-read) include_read=1 ;;
      *) die "Unknown push option: $1" ;;
    esac
    shift
  done

  load_repos

  # --- Phase 1: Pre-flight - collect target repos ---
  local -a push_dirs=()
  local -a push_names=()
  local -a push_branches=()
  local -a push_dirty=()
  local -a push_has_upstream=()
  local -a push_ahead_count=()
  local -a push_behind_count=()
  local -a push_parents=()
  local -a push_is_empty=()
  local -a push_force=()
  local -a push_divclass=()   # "" | safe-force | remote-work | behind-only

  local i repo_dir branch dirty parent
  for i in "${!REPO_NAMES[@]}"; do
    if [ "${REPO_MODES[$i]}" != "write" ]; then
      # --include-read completes the branch/commit --include-read workflow:
      # coordinated commits in read repos must be publishable too.
      { [ "$include_read" -eq 1 ] && [ "${REPO_MODES[$i]}" = "read" ]; } || continue
    fi
    repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    [ -d "$repo_dir/.git" ] || continue
    branch="$(repo_branch "$repo_dir")"
    dirty="$(repo_dirty_state "$repo_dir")"
    # Immediate parent = rightmost of the comma stack; fallback to default branch.
    parent="${REPO_PARENTS[$i]##*,}"
    [ -n "$parent" ] || parent="$(detect_default_branch "$repo_dir")"
    push_dirs+=("$repo_dir")
    push_names+=("${REPO_NAMES[$i]}")
    push_branches+=("$branch")
    push_dirty+=("$dirty")
    push_has_upstream+=(0)
    push_ahead_count+=(0)
    push_behind_count+=(0)
    push_parents+=("$parent")
    push_is_empty+=(0)
    push_force+=(0)
    push_divclass+=("")
  done

  # Meta-context repo
  local meta_dir="" meta_branch="" meta_dirty="" meta_has_upstream=0 meta_ahead=0 meta_behind=0 meta_force=0 meta_divclass=""
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    meta_dir="."
    meta_branch="$(repo_branch ".")"
    meta_dirty="$(repo_dirty_state ".")"
  fi

  # --- Phase 1b: Pre-push fetch + ahead/behind from remote tip ---
  if [ "$do_fetch" -eq 1 ] && { [ "${#push_dirs[@]}" -gt 0 ] || [ -n "$meta_dir" ]; }; then
    log "Fetching origin for all push targets..."
  fi
  for i in "${!push_dirs[@]}"; do
    if [ "$do_fetch" -eq 1 ]; then
      git -C "${push_dirs[$i]}" fetch --quiet 2>/dev/null || warn "Fetch failed for '${push_names[$i]}' (continuing with local refs)"
    fi
    if git -C "${push_dirs[$i]}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      push_has_upstream[$i]=1
      local ab
      ab="$(git -C "${push_dirs[$i]}" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || printf '0\t0')"
      push_behind_count[$i]="$(printf '%s' "$ab" | awk '{print $1+0}')"
      push_ahead_count[$i]="$(printf '%s' "$ab" | awk '{print $2+0}')"
      # Classify any behind branch so we can message it precisely. Auto force-with-lease
      # only the safe-force case, only after a fresh fetch (current lease ref), and only
      # when --no-force was not passed.
      if [ "${push_behind_count[$i]}" -gt 0 ]; then
        push_divclass[$i]="$(classify_divergence "${push_dirs[$i]}" "${push_branches[$i]}" "${push_parents[$i]}")"
        if [ "${push_divclass[$i]}" = "safe-force" ] && [ "$allow_force" -eq 1 ] && [ "$do_fetch" -eq 1 ]; then
          push_force[$i]=1
        fi
      fi
    else
      # No upstream yet (branch never pushed): is this branch empty vs its parent?
      # Skip pushing branches that carry no commits beyond their parent so we don't
      # create empty remote branches across every subrepo.
      local parent="${push_parents[$i]}"
      local cmp_target=""
      if [ -n "$parent" ]; then
        if git -C "${push_dirs[$i]}" show-ref --verify --quiet "refs/remotes/origin/$parent"; then
          cmp_target="origin/$parent"
        elif git -C "${push_dirs[$i]}" show-ref --verify --quiet "refs/heads/$parent"; then
          cmp_target="$parent"
        fi
      fi
      if [ -n "$cmp_target" ]; then
        local cnt
        cnt="$(git -C "${push_dirs[$i]}" rev-list --count "$cmp_target..HEAD" 2>/dev/null || printf -- '-1')"
        [ "$cnt" = "0" ] && push_is_empty[$i]=1
      fi
    fi
  done
  if [ -n "$meta_dir" ]; then
    if [ "$do_fetch" -eq 1 ]; then
      git -C . fetch --quiet 2>/dev/null || warn "Fetch failed for (meta-context) (continuing with local refs)"
    fi
    if git -C . rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      meta_has_upstream=1
      local meta_ab
      meta_ab="$(git -C . rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || printf '0\t0')"
      meta_behind="$(printf '%s' "$meta_ab" | awk '{print $1+0}')"
      meta_ahead="$(printf '%s' "$meta_ab" | awk '{print $2+0}')"
      if [ "$meta_behind" -gt 0 ]; then
        local meta_parent="${META_PARENT##*,}"
        [ -n "$meta_parent" ] || meta_parent="$(detect_default_branch ".")"
        meta_divclass="$(classify_divergence "." "$meta_branch" "$meta_parent")"
        if [ "$meta_divclass" = "safe-force" ] && [ "$allow_force" -eq 1 ] && [ "$do_fetch" -eq 1 ]; then
          meta_force=1
        fi
      fi
    fi
  fi

  # --- Phase 2: Classify repos ---
  local -a dirty_indexes=()
  local -a ahead_indexes=()
  local -a uptodate_indexes=()
  local -a empty_indexes=()
  local -a stuck_names=()
  local -a push_stuck=()
  local meta_class="skip" # dirty, ahead, uptodate, skip

  for i in "${!push_dirs[@]}"; do
    # Mid-operation/conflicted repos are excluded entirely: auto-committing
    # them would immortalize conflict markers, and their branch ref is not
    # what the user thinks mid-rebase. Everything else still pushes.
    push_stuck[$i]=0
    if [ -n "$(repo_inprogress_state "${push_dirs[$i]}")" ]; then
      push_stuck[$i]=1
      stuck_names+=("${push_names[$i]}")
      continue
    fi
    if [ "${push_dirty[$i]}" = "dirty" ]; then
      dirty_indexes+=("$i")
    elif [ "${push_is_empty[$i]}" -eq 1 ]; then
      empty_indexes+=("$i")
    elif [ "${push_ahead_count[$i]}" -gt 0 ] || [ "${push_has_upstream[$i]}" -eq 0 ]; then
      ahead_indexes+=("$i")
    else
      uptodate_indexes+=("$i")
    fi
  done

  local meta_stuck=0
  if [ -n "$meta_dir" ]; then
    if [ -n "$(repo_inprogress_state ".")" ]; then
      meta_stuck=1
      stuck_names+=("(meta-context)")
    elif [ "$meta_dirty" = "dirty" ]; then
      meta_class="dirty"
    elif [ "$meta_ahead" -gt 0 ] || [ "$meta_has_upstream" -eq 0 ]; then
      meta_class="ahead"
    else
      meta_class="uptodate"
    fi
  fi

  if [ "${#stuck_names[@]}" -gt 0 ]; then
    warn "Skipping mid-operation/conflicted repos: ${stuck_names[*]} — finish them first ('mcrepo resolve')."
  fi

  # Check if there is anything to do
  local has_work=0
  if [ "${#dirty_indexes[@]}" -gt 0 ] || [ "${#ahead_indexes[@]}" -gt 0 ]; then
    has_work=1
  fi
  if [ "$meta_class" = "dirty" ] || [ "$meta_class" = "ahead" ]; then
    has_work=1
  fi
  if [ "$has_work" -eq 0 ]; then
    log "Nothing to push. All write-mode repos are up to date."
    return 0
  fi

  # --- Phase 3: Plan display ---
  log "=== Push plan ==="
  local -a behind_repos=()
  local -a remote_work_entries=()
  local -a force_disabled_entries=()   # rebased branches we won't auto-force (--no-force/--no-fetch)
  for i in "${!push_dirs[@]}"; do
    local action
    if [ "${push_stuck[$i]}" -eq 1 ]; then
      printf '  %-20s branch=%-20s -> %s\n' "${push_names[$i]}" "${push_branches[$i]}" "stuck (mid-operation/conflicted) -> skip"
      continue
    fi
    if [ "${push_dirty[$i]}" = "dirty" ]; then
      if [ -n "$commit_message" ]; then
        action="commit + push"
      else
        action="dirty (needs -m or interactive commit message)"
      fi
    elif [ "${push_is_empty[$i]}" -eq 1 ]; then
      action="empty (no commits vs ${push_parents[$i]}) -> skip"
    elif [ "${push_has_upstream[$i]}" -eq 0 ]; then
      action="push (new upstream)"
    elif [ "${push_force[$i]}" -eq 1 ]; then
      action="${push_ahead_count[$i]} ahead -> force-push (rebased)"
    elif [ "${push_ahead_count[$i]}" -gt 0 ]; then
      action="${push_ahead_count[$i]} ahead -> push"
    else
      action="up to date -> skip"
    fi
    if [ "${push_behind_count[$i]}" -gt 0 ]; then
      if [ "${push_force[$i]}" -eq 1 ]; then
        action="$action  [REBASED -> force-push]"
      elif [ "${push_divclass[$i]}" = "safe-force" ]; then
        # Rebased branch, but auto-force was disabled (--no-force / --no-fetch).
        action="$action  [REBASED -> needs force]"
        behind_repos+=("${push_names[$i]} (rebased, force disabled)")
        force_disabled_entries+=("${push_names[$i]}|${push_dirs[$i]}")
      else
        action="$action  [BEHIND ${push_behind_count[$i]}]"
        behind_repos+=("${push_names[$i]} (${push_behind_count[$i]} behind)")
        # Genuine or ambiguous remote work — never auto-force.
        case "${push_divclass[$i]}" in
          remote-work|ambiguous) remote_work_entries+=("${push_names[$i]}|${push_dirs[$i]}") ;;
        esac
      fi
    fi
    printf '  %-20s branch=%-20s -> %s\n' "${push_names[$i]}" "${push_branches[$i]}" "$action"
  done
  if [ -n "$meta_dir" ] && [ "$meta_stuck" -eq 1 ]; then
    printf '  %-20s branch=%-20s -> %s\n' "(meta-context)" "$meta_branch" "stuck (mid-operation/conflicted) -> skip"
  elif [ -n "$meta_dir" ]; then
    local meta_action
    if [ "$meta_class" = "dirty" ]; then
      if [ -n "$commit_message" ]; then
        meta_action="commit + push"
      else
        meta_action="dirty (needs -m or interactive commit message)"
      fi
    elif [ "$meta_has_upstream" -eq 0 ]; then
      meta_action="push (new upstream)"
    elif [ "$meta_force" -eq 1 ]; then
      meta_action="$meta_ahead ahead -> force-push (rebased)"
    elif [ "$meta_class" = "ahead" ]; then
      meta_action="$meta_ahead ahead -> push"
    else
      meta_action="up to date -> skip"
    fi
    if [ "$meta_behind" -gt 0 ]; then
      if [ "$meta_force" -eq 1 ]; then
        meta_action="$meta_action  [REBASED -> force-push]"
      elif [ "$meta_divclass" = "safe-force" ]; then
        meta_action="$meta_action  [REBASED -> needs force]"
        behind_repos+=("(meta-context) (rebased, force disabled)")
        force_disabled_entries+=("(meta-context)|.")
      else
        meta_action="$meta_action  [BEHIND $meta_behind]"
        behind_repos+=("(meta-context) ($meta_behind behind)")
        case "$meta_divclass" in
          remote-work|ambiguous) remote_work_entries+=("(meta-context)|.") ;;
        esac
      fi
    fi
    printf '  %-20s branch=%-20s -> %s\n' "(meta-context)" "$meta_branch" "$meta_action"
  fi
  log ""

  # --- Phase 3b: Abort if any target repo is behind origin ---
  if [ "${#behind_repos[@]}" -gt 0 ]; then
    warn "Some repos are behind their upstream:"
    local br
    for br in "${behind_repos[@]}"; do
      warn "  - $br"
    done
    log ""
    log "Refusing to push to avoid mid-run rejections."
    if [ "${#force_disabled_entries[@]}" -gt 0 ]; then
      log ""
      log "The following branches were only rebased onto their parent and just need re-publishing."
      log "Auto force-with-lease is disabled here (--no-force / --no-fetch). Re-run 'mcrepo push'"
      log "without those flags to publish them automatically, or force-push manually:"
      local fd
      for fd in "${force_disabled_entries[@]}"; do
        log "  - ${fd%%|*}:  git -C ${fd#*|} push --force-with-lease"
      done
    fi
    local plain_behind=$(( ${#behind_repos[@]} - ${#force_disabled_entries[@]} ))
    if [ "$plain_behind" -gt 0 ]; then
      log ""
      log "Sync first with one of:"
      log "  mcrepo pull           # fast-forward where possible"
      log "  mcrepo pull           # rebase local commits on top of upstream"
      log "Or rerun with --no-fetch to skip this safety check (still rejected by remote on real conflicts)."
    fi
    if [ "${#remote_work_entries[@]}" -gt 0 ]; then
      log ""
      log "Note: the following branches have diverged AND their remote already contains work that does"
      log "not look like your local rebase — so mcrepo will not force-push them. Review before deciding:"
      local rw
      for rw in "${remote_work_entries[@]}"; do
        log "  - ${rw%%|*}"
      done
      print_agent_recovery_prompt ambiguous-divergence "${remote_work_entries[@]}"
    fi
    return 1
  fi

  # --- Phase 4: Handle dirty repos - get commit message ---
  local do_commit=0
  if [ "${#dirty_indexes[@]}" -gt 0 ] || [ "$meta_class" = "dirty" ]; then
    if [ -n "$commit_message" ]; then
      do_commit=1
    elif [ -t 0 ] && [ -t 1 ]; then
      printf 'Uncommitted changes found. Enter commit message (empty = auto-generate): ' >&2
      IFS= read -r commit_message
      do_commit=1
    fi
  fi

  # --- Phase 5: Commit dirty repos ---
  local -a committed_pushed=()
  local -a pushed_repos=()
  local -a force_pushed_repos=()
  local -a skipped_dirty=()
  local -a skipped_uptodate=()
  local -a skipped_empty=()
  local -a failed_repos=()

  if [ "$do_commit" -eq 1 ] && [ "${#dirty_indexes[@]}" -gt 0 ]; then
    for i in "${dirty_indexes[@]}"; do
      local rd="${push_dirs[$i]}"
      local rn="${push_names[$i]}"
      local rb="${push_branches[$i]}"
      local msg="$commit_message"
      if [ -z "$msg" ]; then
        msg="$(generate_commit_message "$rd" "$rb" "$rn")"
      fi
      git -C "$rd" add -A
      if ! git -C "$rd" commit -m "$msg"; then
        warn "Commit failed in '$rn'. Skipping."
        failed_repos+=("$rn")
        continue
      fi
      log "  Committed '$rn'"
      push_dirty[$i]="committed"
    done
  fi

  # Commit meta-context if dirty
  if [ "$do_commit" -eq 1 ] && [ "$meta_class" = "dirty" ]; then
    local meta_msg="$commit_message"
    if [ -z "$meta_msg" ]; then
      meta_msg="$(generate_commit_message "." "$meta_branch" "(meta-context)")"
    fi
    git -C . add -A
    if ! git -C . commit -m "$meta_msg"; then
      warn "Commit failed in (meta-context). Skipping."
      failed_repos+=("(meta-context)")
      meta_class="failed"
    else
      log "  Committed (meta-context)"
      meta_class="ahead"
    fi
  fi

  # --- Phase 6: Push repos ---
  # Push sub-repos first, then meta-context last
  for i in "${!push_dirs[@]}"; do
    local rd="${push_dirs[$i]}"
    local rn="${push_names[$i]}"
    local rb="${push_branches[$i]}"
    local was_dirty="${push_dirty[$i]}"

    # Mid-operation/conflicted repos were excluded in Phase 2 (mid-rebase the
    # branch ref is stale; unmerged trees must never be auto-committed).
    if [ "${push_stuck[$i]}" -eq 1 ]; then
      continue
    fi

    # Skip empty branches (no commits beyond their parent) so we don't create
    # empty remote branches across subrepos that have no real changes.
    if [ "${push_is_empty[$i]}" -eq 1 ] && [ "$was_dirty" != "committed" ]; then
      skipped_empty+=("$rn")
      continue
    fi

    # Skip up-to-date repos
    if [ "$was_dirty" != "committed" ] && [ "${push_ahead_count[$i]}" -eq 0 ] && [ "${push_has_upstream[$i]}" -eq 1 ]; then
      skipped_uptodate+=("$rn")
      continue
    fi

    # Skip dirty repos that were not committed (no -m given, non-interactive)
    if [ "$was_dirty" = "dirty" ]; then
      skipped_dirty+=("$rn")
      continue
    fi

    # Push
    log "--- Pushing $rn ---"
    if [ "${push_has_upstream[$i]}" -eq 0 ]; then
      if ! git -C "$rd" push -u origin "$rb"; then
        warn "Push failed for '$rn' (see git output above)"
        failed_repos+=("$rn")
        continue
      fi
    elif [ "${push_force[$i]}" -eq 1 ]; then
      log "  (rebased branch — publishing with --force-with-lease)"
      if ! git -C "$rd" push --force-with-lease; then
        warn "Force-push failed for '$rn' (remote moved since fetch?). See git output above."
        failed_repos+=("$rn")
        continue
      fi
    else
      if ! git -C "$rd" push; then
        warn "Push failed for '$rn' (see git output above)"
        failed_repos+=("$rn")
        continue
      fi
    fi

    if [ "$was_dirty" = "committed" ]; then
      committed_pushed+=("$rn")
    elif [ "${push_force[$i]}" -eq 1 ]; then
      force_pushed_repos+=("$rn")
    else
      pushed_repos+=("$rn")
    fi
  done

  # Push meta-context last
  if [ -n "$meta_dir" ] && [ "$meta_class" = "ahead" ]; then
    log "--- Pushing (meta-context) ---"
    if ! git -C . remote get-url origin >/dev/null 2>&1; then
      # Not published yet — that is a normal state, not a failure.
      log "  (meta-context): no 'origin' remote configured — skipping. Use 'mcrepo publish-base <git-url>' to publish the workspace."
      skipped_uptodate+=("(meta-context) (no remote)")
    elif [ "$meta_has_upstream" -eq 0 ]; then
      if ! git -C . push -u origin "$meta_branch"; then
        warn "Push failed for (meta-context) (see git output above)"
        failed_repos+=("(meta-context)")
      else
        if [ "$meta_dirty" = "dirty" ]; then
          committed_pushed+=("(meta-context)")
        else
          pushed_repos+=("(meta-context)")
        fi
      fi
    elif [ "$meta_force" -eq 1 ]; then
      log "  (rebased branch — publishing with --force-with-lease)"
      if ! git -C . push --force-with-lease; then
        warn "Force-push failed for (meta-context) (remote moved since fetch?). See git output above."
        failed_repos+=("(meta-context)")
      else
        force_pushed_repos+=("(meta-context)")
      fi
    else
      if ! git -C . push; then
        warn "Push failed for (meta-context) (see git output above)"
        failed_repos+=("(meta-context)")
      else
        if [ "$meta_dirty" = "dirty" ]; then
          committed_pushed+=("(meta-context)")
        else
          pushed_repos+=("(meta-context)")
        fi
      fi
    fi
  elif [ -n "$meta_dir" ] && [ "$meta_class" = "uptodate" ]; then
    skipped_uptodate+=("(meta-context)")
  elif [ -n "$meta_dir" ] && [ "$meta_class" = "dirty" ]; then
    skipped_dirty+=("(meta-context)")
  fi

  # --- Phase 7: Summary ---
  log "=== Push summary ==="
  if [ "${#committed_pushed[@]}" -gt 0 ]; then
    log "  Committed + pushed:    ${committed_pushed[*]}"
  fi
  if [ "${#pushed_repos[@]}" -gt 0 ]; then
    log "  Pushed:                ${pushed_repos[*]}"
  fi
  if [ "${#force_pushed_repos[@]}" -gt 0 ]; then
    log "  Force-pushed (rebased): ${force_pushed_repos[*]}"
  fi
  if [ "${#skipped_uptodate[@]}" -gt 0 ]; then
    log "  Skipped (up to date):  ${skipped_uptodate[*]}"
  fi
  if [ "${#skipped_empty[@]}" -gt 0 ]; then
    log "  Skipped (empty, no commits): ${skipped_empty[*]}"
  fi
  if [ "${#skipped_dirty[@]}" -gt 0 ]; then
    warn "  Skipped (dirty, no -m): ${skipped_dirty[*]}"
    log ""
    log "Use 'mcrepo push -m \"message\"' to commit and push dirty repos."
  fi
  if [ "${#stuck_names[@]}" -gt 0 ]; then
    warn "  Skipped (stuck):       ${stuck_names[*]} — finish with 'mcrepo resolve' first"
  fi
  if [ "${#failed_repos[@]}" -gt 0 ]; then
    warn "  Failed:                ${failed_repos[*]}"
    # Exit-code contract: 0 = success, 2 = partial per-repo failure.
    return 2
  fi
  if [ "${#committed_pushed[@]}" -gt 0 ] || [ "${#pushed_repos[@]}" -gt 0 ] || [ "${#force_pushed_repos[@]}" -gt 0 ]; then
    if [ -n "$GLOBAL_BRANCH" ]; then
      log ""
      log "Next: 'mcrepo pr' to open coordinated PRs for review — or keep working and 'mcrepo rebase' + 'mcrepo merge' when the feature is done."
    fi
  fi
}

parse_skill_config_list() {
  local section="$1"
  [ -f "$SKILLS_CONFIG_FILE" ] || return 0

  awk -v section="$section" '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    function unquote(s) {
      s = trim(s)
      if ((s ~ /^".*"$/) || (s ~ /^\047.*\047$/)) {
        return substr(s, 2, length(s) - 2)
      }
      return s
    }
    {
      line = $0
      if (line ~ /^[ \t]*#/ || line ~ /^[ \t]*$/) {
        next
      }
      if (line ~ /^[ \t]*enabled:[ \t]*/) {
        in_section = (section == "enabled")
        next
      }
      if (line ~ /^[ \t]*disabled:[ \t]*/) {
        in_section = (section == "disabled")
        next
      }
      if (in_section && line ~ /^[ \t]*-[ \t]*/) {
        sub(/^[ \t]*-[ \t]*/, "", line)
        print unquote(line)
      }
    }
  ' "$SKILLS_CONFIG_FILE"
}

list_skill_ids() {
  local base_dir="${1:-$SUPPORT_SKILLS_DIR}"
  local skill_dir skill_id
  [ -d "$base_dir" ] || return 0

  shopt -s nullglob
  for skill_dir in "$base_dir"/*; do
    [ -d "$skill_dir" ] || continue
    skill_id="$(basename "$skill_dir")"
    [ "$skill_id" = "_templates" ] && continue
    if [ ! -f "$skill_dir/skill.md" ] && [ ! -f "$skill_dir/SKILL.md" ]; then
      continue
    fi
    printf '%s\n' "$skill_id"
  done
  shopt -u nullglob
}

sync_workspace_skills_to_opencode() {
  local skill_id src_dir dst_dir description

  mkdir -p "$OPENCODE_PROJECT_SKILLS_DIR"
  while IFS= read -r skill_id; do
    [ -n "$skill_id" ] || continue
    src_dir="$SUPPORT_SKILLS_DIR/$skill_id"
    dst_dir="$OPENCODE_PROJECT_SKILLS_DIR/$skill_id"

    rm -rf "$dst_dir"
    mkdir -p "$dst_dir"
    cp -R "$src_dir"/. "$dst_dir"/

    if [ -f "$src_dir/SKILL.md" ]; then
      cp "$src_dir/SKILL.md" "$dst_dir/SKILL.md"
      continue
    fi

    description="Workspace governance skill '$skill_id' for this MC-Repo."
    {
      printf -- '---\n'
      printf 'name: %s\n' "$skill_id"
      printf 'description: %s\n' "$description"
      printf -- '---\n\n'
      if [ -f "$src_dir/skill.md" ]; then
        cat "$src_dir/skill.md"
      fi
      printf '\n'
    } >"$dst_dir/SKILL.md"
  done < <(list_skill_ids)
}

severity_rank() {
  case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
    LOW) printf '1' ;;
    MEDIUM) printf '2' ;;
    HIGH) printf '3' ;;
    CRITICAL) printf '4' ;;
    *) printf '0' ;;
  esac
}

is_http_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

is_github_url() {
  case "$1" in
    http://github.com/*|https://github.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_clawhub_url() {
  case "$1" in
    http://clawhub.ai/*|https://clawhub.ai/*|http://www.clawhub.ai/*|https://www.clawhub.ai/*|http://clawhub.com/*|https://clawhub.com/*|http://www.clawhub.com/*|https://www.clawhub.com/*) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_imported_skill_id() {
  local id
  id="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
  id="${id#-}"
  id="${id%-}"
  while [[ "$id" == *--* ]]; do
    id="${id//--/-}"
  done
  if [ -z "$id" ]; then
    id="imported-skill"
  fi
  printf '%s' "$id"
}

extract_json_from_mixed_output() {
  awk 'BEGIN{p=0} /^[[:space:]]*\{/ {p=1} p {print}'
}

parse_clawhub_slug_candidates() {
  local url="$1"
  local no_scheme path
  no_scheme="${url#http://}"
  no_scheme="${no_scheme#https://}"
  path="${no_scheme#*/}"
  path="${path%%\?*}"
  path="${path%%\#*}"
  path="${path#/}"

  local first second
  first="${path%%/*}"
  if [ "$first" = "$path" ]; then
    first=""
  fi
  second="${path#*/}"
  if [ "$second" = "$path" ]; then
    second=""
  fi

  if [ "$first" = "skills" ] && [ -n "$second" ]; then
    printf '%s\n' "${second%%/*}"
    return 0
  fi

  if [ -n "$first" ] && [ -n "$second" ]; then
    printf '%s\n' "$first/$second"
    printf '%s\n' "$second"
    return 0
  fi

  if [ -n "$path" ]; then
    printf '%s\n' "$path"
  fi
}

clawhub_inspect_json() {
  local slug="$1"
  shift
  local out
  out="$(npx -y clawhub@latest inspect "$slug" --json "$@" 2>/dev/null || true)"
  if [ -z "$out" ]; then
    return 1
  fi
  printf '%s\n' "$out" | extract_json_from_mixed_output
}

scan_clawhub_skill() {
  local skill_url="$1"
  local skip_scan="$2"
  local require_scan="$3"
  local max_severity="$4"

  if [ "$skip_scan" -eq 1 ]; then
    return 0
  fi

  command -v curl >/dev/null 2>&1 || {
    if [ "$require_scan" -eq 1 ]; then
      die "curl is required for --require-scan"
    fi
    warn "curl not found; skipping scan."
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    if [ "$require_scan" -eq 1 ]; then
      die "jq is required for --require-scan"
    fi
    warn "jq not found; skipping scan."
    return 0
  }

  local payload response http_code body status severity reasons
  payload="{\"skillUrl\":\"$skill_url\"}"

  if ! response="$(curl --silent --show-error --location --write-out $'\n%{http_code}' --request POST --url "https://ai.gendigital.com/api/scan/lookup" --header "Content-Type: application/json" --data "$payload" 2>/dev/null)"; then
    if [ "$require_scan" -eq 1 ]; then
      die "Skill scan failed and --require-scan is set."
    fi
    warn "Skill scan service unavailable, continuing install. Use --require-scan to enforce."
    return 0
  fi

  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [ "$http_code" != "200" ]; then
    if [ "$require_scan" -eq 1 ]; then
      die "Skill scan rejected this URL (HTTP $http_code) and --require-scan is set."
    fi
    warn "Skill scan not applicable for this URL (HTTP $http_code), continuing."
    return 0
  fi

  status="$(printf '%s' "$body" | jq -r '.status // empty' 2>/dev/null || true)"
  if [ "$status" = "error" ]; then
    local message
    message="$(printf '%s' "$body" | jq -r '.message // "scan error"' 2>/dev/null || true)"
    if [ "$require_scan" -eq 1 ]; then
      die "Skill scan could not verify URL: $message"
    fi
    warn "Skill scan could not verify URL: $message (continuing)."
    return 0
  fi

  severity="$(printf '%s' "$body" | jq -r '.severity // "UNKNOWN"' 2>/dev/null || true)"
  reasons="$(printf '%s' "$body" | jq -r '.reasons[]? // empty' 2>/dev/null || true)"
  if [ -n "$severity" ] && [ "$severity" != "UNKNOWN" ]; then
    log "Skill scan severity: $severity"
  fi
  if [ -n "$reasons" ]; then
    warn "Skill scan reasons:"
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      warn "  - $line"
    done <<<"$reasons"
  fi

  if [ "$(severity_rank "$severity")" -ge "$(severity_rank "$max_severity")" ] && [ "$(severity_rank "$max_severity")" -gt 0 ]; then
    die "Skill install blocked by scan policy (severity=$severity threshold=$max_severity)."
  fi

  if [ "$(severity_rank "$severity")" -ge "$(severity_rank "HIGH")" ]; then
    warn "High-risk scan result detected; review files before use."
  fi
}

resolve_scope_dir() {
  local scope_repo="$1"
  local for_write="$2"

  SKILL_SCOPE_KIND="workspace"
  SKILL_SCOPE_DIR="$SUPPORT_SKILLS_DIR"

  if [ -z "$scope_repo" ]; then
    return 0
  fi

  load_repos
  local idx
  idx="$(find_repo_index "$scope_repo")" || die "Repo not found: $scope_repo"

  local mode repo_name repo_dir
  mode="${REPO_MODES[$idx]}"
  repo_name="${REPO_NAMES[$idx]}"
  if [ "$for_write" -eq 1 ] && [ "$mode" != "write" ]; then
    die "Skill install into sub-repo requires mode=write. '$repo_name' is mode '$mode'."
  fi

  repo_dir="$(get_repo_dir "$repo_name" "$mode")"
  if [ "$for_write" -eq 1 ] && [ ! -d "$repo_dir" ]; then
    die "Sub-repo directory not found: $repo_dir"
  fi

  SKILL_SCOPE_KIND="repo"
  SKILL_SCOPE_DIR="$repo_dir/$OPENCODE_PROJECT_SKILLS_DIR"
}

discover_single_skill_source_dir() {
  local base_dir="$1"
  local -a hits=()
  local dir

  if [ -f "$base_dir/SKILL.md" ] || [ -f "$base_dir/skill.md" ]; then
    printf '%s' "$base_dir"
    return 0
  fi

  shopt -s nullglob
  for dir in "$base_dir"/* "$base_dir"/skills/*; do
    [ -d "$dir" ] || continue
    if [ -f "$dir/SKILL.md" ] || [ -f "$dir/skill.md" ]; then
      hits+=("$dir")
    fi
  done
  shopt -u nullglob

  if [ "${#hits[@]}" -eq 1 ]; then
    printf '%s' "${hits[0]}"
    return 0
  fi

  if [ "${#hits[@]}" -eq 0 ]; then
    return 1
  fi

  die "Source contains multiple skills; use a direct skill folder URL (for example GitHub tree URL)."
}

install_skill_from_github_url() {
  local source_url="$1"
  local target_root="$2"
  local url no_scheme path owner rest repo tail clone_url branch subpath tmp_dir source_root source_dir

  url="${source_url%%\#*}"
  url="${url%%\?*}"
  no_scheme="${url#http://}"
  no_scheme="${no_scheme#https://}"
  path="${no_scheme#github.com/}"
  [ "$path" != "$no_scheme" ] || die "Invalid GitHub URL: $source_url"

  owner="${path%%/*}"
  rest="${path#*/}"
  repo="${rest%%/*}"
  tail="${rest#*/}"

  repo="${repo%.git}"
  [ -n "$owner" ] || die "Invalid GitHub URL owner: $source_url"
  [ -n "$repo" ] || die "Invalid GitHub URL repo: $source_url"
  command -v git >/dev/null 2>&1 || die "git is required for GitHub skill installs"

  branch=""
  subpath=""
  if [ "$tail" != "$rest" ] && [[ "$tail" == tree/* ]]; then
    tail="${tail#tree/}"
    branch="${tail%%/*}"
    subpath="${tail#*/}"
    if [ "$subpath" = "$tail" ]; then
      subpath=""
    fi
  fi

  tmp_dir="$(mktemp -d)"
  clone_url="https://github.com/$owner/$repo.git"
  if [ -n "$branch" ]; then
    git clone --depth 1 --branch "$branch" "$clone_url" "$tmp_dir/repo" >/dev/null 2>&1 || die "Failed to clone GitHub source: $clone_url"
  else
    git clone --depth 1 "$clone_url" "$tmp_dir/repo" >/dev/null 2>&1 || die "Failed to clone GitHub source: $clone_url"
  fi

  source_root="$tmp_dir/repo"
  if [ -n "$subpath" ]; then
    source_root="$source_root/$subpath"
  fi
  [ -d "$source_root" ] || die "Source path not found in GitHub repo: $subpath"

  source_dir="$(discover_single_skill_source_dir "$source_root")" || die "No skill folder found in source URL."

  local skill_id target_dir
  skill_id="$(normalize_imported_skill_id "$(basename "$source_dir")")"
  target_dir="$target_root/$skill_id"
  [ ! -e "$target_dir" ] || die "Skill already exists: $skill_id"

  mkdir -p "$target_dir"
  cp -R "$source_dir"/. "$target_dir"/
  if [ ! -f "$target_dir/SKILL.md" ] && [ -f "$target_dir/skill.md" ]; then
    cp "$target_dir/skill.md" "$target_dir/SKILL.md"
  fi
  [ -f "$target_dir/SKILL.md" ] || die "Imported GitHub skill missing SKILL.md/skill.md"

  printf '%s' "$skill_id"
}

resolve_clawhub_slug() {
  local source_url="$1"
  local candidate json slug
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    json="$(clawhub_inspect_json "$candidate")"
    [ -n "$json" ] || continue
    slug="$(printf '%s' "$json" | jq -r '.skill.slug // empty' 2>/dev/null || true)"
    if [ -n "$slug" ]; then
      printf '%s' "$slug"
      return 0
    fi
  done < <(parse_clawhub_slug_candidates "$source_url")
  return 1
}

install_skill_from_clawhub_url() {
  local source_url="$1"
  local target_root="$2"
  local slug metadata_json files_json files skill_id target_dir file_path file_json file_content

  command -v jq >/dev/null 2>&1 || die "jq is required for ClawHub skill installs"
  command -v npx >/dev/null 2>&1 || die "npx is required for ClawHub skill installs"

  slug="$(resolve_clawhub_slug "$source_url")" || die "Could not resolve ClawHub skill slug from URL: $source_url"
  metadata_json="$(clawhub_inspect_json "$slug")"
  [ -n "$metadata_json" ] || die "Failed to fetch ClawHub metadata for slug: $slug"
  files_json="$(clawhub_inspect_json "$slug" --files)"
  [ -n "$files_json" ] || die "Failed to fetch ClawHub files for slug: $slug"

  files="$(printf '%s' "$files_json" | jq -r '.version.files[]?.path // empty' 2>/dev/null || true)"
  [ -n "$files" ] || die "No files found for ClawHub skill: $slug"

  skill_id="$(printf '%s' "$metadata_json" | jq -r '.skill.slug // empty' 2>/dev/null || true)"
  [ -n "$skill_id" ] || skill_id="$(normalize_imported_skill_id "${slug##*/}")"
  skill_id="$(normalize_imported_skill_id "$skill_id")"

  target_dir="$target_root/$skill_id"
  [ ! -e "$target_dir" ] || die "Skill already exists: $skill_id"
  mkdir -p "$target_dir"

  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    file_json="$(clawhub_inspect_json "$slug" --file "$file_path")"
    [ -n "$file_json" ] || die "Failed fetching ClawHub file: $file_path"
    file_content="$(printf '%s' "$file_json" | jq -r '.file.content // empty' 2>/dev/null || true)"

    mkdir -p "$target_dir/$(dirname "$file_path")"
    printf '%s' "$file_content" >"$target_dir/$file_path"
    if [[ "$file_path" == *.sh ]]; then
      chmod +x "$target_dir/$file_path"
    fi
  done <<<"$files"

  [ -f "$target_dir/SKILL.md" ] || die "Downloaded ClawHub skill is missing SKILL.md"
  printf '%s' "$skill_id"
}

install_skill_from_url() {
  local source_url="$1"
  local target_root="$2"
  local skip_scan="$3"
  local require_scan="$4"
  local max_severity="$5"

  if is_github_url "$source_url"; then
    install_skill_from_github_url "$source_url" "$target_root"
    return 0
  fi

  if is_clawhub_url "$source_url"; then
    scan_clawhub_skill "$source_url" "$skip_scan" "$require_scan" "$max_severity"
    install_skill_from_clawhub_url "$source_url" "$target_root"
    return 0
  fi

  die "Unsupported skill source URL. Use GitHub or ClawHub URL."
}

array_contains() {
  local needle="$1"
  shift || true
  local item
  for item in "$@"; do
    if [ "$item" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

array_remove_item() {
  local needle="$1"
  shift || true
  local item
  for item in "$@"; do
    if [ "$item" != "$needle" ]; then
      printf '%s\n' "$item"
    fi
  done
}

write_skills_config() {
  local -a enabled_ids=("$@")
  local disabled_marker="__MCREPO_DISABLED_SPLIT__"
  local -a disabled_ids=()
  local -a new_enabled=()
  local parsing_disabled=0
  local id

  for id in "${enabled_ids[@]}"; do
    if [ "$id" = "$disabled_marker" ]; then
      parsing_disabled=1
      continue
    fi
    if [ "$parsing_disabled" -eq 1 ]; then
      disabled_ids+=("$id")
    else
      new_enabled+=("$id")
    fi
  done

  mkdir -p "$SUPPORT_SKILLS_DIR"
  {
    printf '# Optional workspace governance for skill activation.\n'
    printf '# If this file is missing, all discovered skills are treated as active.\n'
    printf 'enabled:\n'
    if [ "${#new_enabled[@]}" -eq 0 ]; then
      printf '  []\n'
    else
      for id in "${new_enabled[@]}"; do
        printf '  - %s\n' "$id"
      done
    fi
    printf 'disabled:\n'
    if [ "${#disabled_ids[@]}" -eq 0 ]; then
      printf '  []\n'
    else
      for id in "${disabled_ids[@]}"; do
        printf '  - %s\n' "$id"
      done
    fi
  } >"$SKILLS_CONFIG_FILE"
}

workspace_enable_skill() {
  local skill_id="$1"
  [ -f "$SKILLS_CONFIG_FILE" ] || return 0

  # bash-3.2-safe: filter the needle while reading (no mapfile on macOS stock bash)
  local id
  local -a enabled_ids=()
  local -a disabled_ids=()
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$id" != "$skill_id" ] || continue
    enabled_ids+=("$id")
  done < <(parse_skill_config_list "enabled")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$id" != "$skill_id" ] || continue
    disabled_ids+=("$id")
  done < <(parse_skill_config_list "disabled")

  enabled_ids+=("$skill_id")
  write_skills_config "${enabled_ids[@]}" "__MCREPO_DISABLED_SPLIT__" "${disabled_ids[@]+"${disabled_ids[@]}"}"
}

is_skill_active() {
  local skill_id="$1"
  local -a enabled_ids=()
  local -a disabled_ids=()
  local id

  if [ ! -f "$SKILLS_CONFIG_FILE" ]; then
    return 0
  fi

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    enabled_ids+=("$id")
  done < <(parse_skill_config_list "enabled")

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    disabled_ids+=("$id")
  done < <(parse_skill_config_list "disabled")

  if array_contains "$skill_id" "${disabled_ids[@]+"${disabled_ids[@]}"}"; then
    return 1
  fi

  if [ "${#enabled_ids[@]}" -gt 0 ]; then
    array_contains "$skill_id" "${enabled_ids[@]}"
    return $?
  fi

  return 0
}

validate_skill_id() {
  case "$1" in
    ''|*[!a-z0-9-]*|-*|*-) return 1 ;;
    *) return 0 ;;
  esac
}

cmd_skill() {
  local scope_repo=""
  local subcmd="${1:-list}"

  case "$subcmd" in
    list|new|install|enable|disable|validate)
      shift || true
      ;;
    '')
      subcmd="list"
      ;;
    *)
      scope_repo="$subcmd"
      shift || true
      subcmd="${1:-list}"
      shift || true
      ;;
  esac

  case "$subcmd" in
    list|new|install|enable|disable|validate) ;;
    *) die "Unknown skill subcommand: $subcmd" ;;
  esac

  local require_write=0
  if [ "$subcmd" = "new" ] || [ "$subcmd" = "install" ]; then
    require_write=1
  fi
  resolve_scope_dir "$scope_repo" "$require_write"

  case "$subcmd" in
    list)
      local ids_only=0
      if [ "${1:-}" = "--ids" ]; then
        ids_only=1
        shift
      fi
      [ "$#" -eq 0 ] || die "Usage: ./mcrepo.sh skill [repo-name] list [--ids]"

      local id
      if [ "$ids_only" -eq 1 ]; then
        list_skill_ids "$SKILL_SCOPE_DIR" | sort
        return 0
      fi

      if [ ! -d "$SKILL_SCOPE_DIR" ]; then
        log "No skills directory found: $SKILL_SCOPE_DIR"
        return 0
      fi

      while IFS= read -r id; do
        if [ "$SKILL_SCOPE_KIND" = "workspace" ]; then
          if is_skill_active "$id"; then
            printf '%-30s state=enabled\n' "$id"
          else
            printf '%-30s state=disabled\n' "$id"
          fi
        else
          printf '%-30s state=enabled\n' "$id"
        fi
      done < <(list_skill_ids "$SKILL_SCOPE_DIR" | sort)
      ;;
    new)
      [ "$#" -eq 1 ] || die "Usage: ./mcrepo.sh skill [repo-name] new <skill-id>"
      local source="$1"
      if is_http_url "$source"; then
        die "'new' creates a template skill. Use 'install' for URLs: ./mcrepo.sh skill [repo-name] install <github-url|clawhub-url>"
      fi

      local skill_id skill_dir
      mkdir -p "$SKILL_SCOPE_DIR"
      validate_skill_id "$source" || die "Invalid skill id '$source' (allowed: lowercase letters, digits, hyphen)"
      skill_id="$source"
      skill_dir="$SKILL_SCOPE_DIR/$skill_id"
      [ ! -e "$skill_dir" ] || die "Skill already exists: $skill_id"
      mkdir -p "$skill_dir"

      if [ "$SKILL_SCOPE_KIND" = "workspace" ]; then
        cat >"$skill_dir/skill.md" <<EOF
# $skill_id

## Purpose
Describe what this skill does.

## When to Apply
- Add triggers for using this skill.

## Procedure
1. Add the first actionable step.
2. Add validation steps.

## Optional Helpers
- \`run.sh\` for task automation
- \`check.sh\` for verification
EOF
      else
        cat >"$skill_dir/SKILL.md" <<EOF
---
name: $skill_id
description: Describe what this skill does.
---

# $skill_id

## Purpose
Describe what this skill does.

## When to Apply
- Add triggers for using this skill.

## Procedure
1. Add the first actionable step.
2. Add validation steps.
EOF
      fi

      cat >"$skill_dir/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "Implement task-specific helper logic here."
EOF
      chmod +x "$skill_dir/run.sh"

      log "Created skill: $skill_id"

      if [ "$SKILL_SCOPE_KIND" = "workspace" ]; then
        workspace_enable_skill "$skill_id"
        sync_workspace_skills_to_opencode
      fi
      ;;
    install)
      [ "$#" -ge 1 ] || die "Usage: ./mcrepo.sh skill [repo-name] install <github-url|clawhub-url> [--skip-scan] [--require-scan] [--max-severity CRITICAL|HIGH|MEDIUM|LOW]
Tip: Browse skills at https://clawhub.ai/skills"

      local source="$1"
      shift
      is_http_url "$source" || die "install requires a URL source"

      local skip_scan=0
      local require_scan=0
      local max_severity="CRITICAL"
      local opt
      while [ "$#" -gt 0 ]; do
        opt="$1"
        case "$opt" in
          --skip-scan) skip_scan=1 ;;
          --require-scan) require_scan=1 ;;
          --max-severity)
            shift
            [ "$#" -gt 0 ] || die "Missing value for --max-severity"
            max_severity="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
            ;;
          *) die "Unknown skill install option: $opt" ;;
        esac
        shift
      done
      if [ "$(severity_rank "$max_severity")" -eq 0 ]; then
        die "Invalid --max-severity value '$max_severity' (use LOW|MEDIUM|HIGH|CRITICAL)"
      fi

      local skill_id
      mkdir -p "$SKILL_SCOPE_DIR"
      skill_id="$(install_skill_from_url "$source" "$SKILL_SCOPE_DIR" "$skip_scan" "$require_scan" "$max_severity")"
      log "Installed skill '$skill_id' from $source"

      if [ "$SKILL_SCOPE_KIND" = "workspace" ]; then
        workspace_enable_skill "$skill_id"
        sync_workspace_skills_to_opencode
      fi
      ;;
    enable|disable)
      [ "$SKILL_SCOPE_KIND" = "workspace" ] || die "enable/disable is only supported for workspace skills"
      [ "$#" -eq 1 ] || die "Usage: ./mcrepo.sh skill $subcmd <skill-id>"
      local target_id="$1"
      local target_dir="$SUPPORT_SKILLS_DIR/$target_id"
      if [ ! -f "$target_dir/skill.md" ] && [ ! -f "$target_dir/SKILL.md" ]; then
        die "Skill not found: $target_id"
      fi

      local id
      local -a enabled_ids=()
      local -a disabled_ids=()
      local explicit_mode=0

      # bash-3.2-safe: filter the target while reading (no mapfile on macOS stock bash)
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        if [ "$id" = "$target_id" ]; then
          explicit_mode=1
          continue
        fi
        enabled_ids+=("$id")
      done < <(parse_skill_config_list "enabled")

      while IFS= read -r id; do
        [ -n "$id" ] || continue
        [ "$id" != "$target_id" ] || continue
        disabled_ids+=("$id")
      done < <(parse_skill_config_list "disabled")

      if [ "${#enabled_ids[@]}" -gt 0 ]; then
        explicit_mode=1
      fi

      if [ ! -f "$SKILLS_CONFIG_FILE" ]; then
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          [ "$id" != "$target_id" ] || continue
          enabled_ids+=("$id")
        done < <(list_skill_ids "$SUPPORT_SKILLS_DIR")
        explicit_mode=1
      fi

      if [ "$subcmd" = "enable" ]; then
        if [ "$explicit_mode" -eq 1 ]; then
          enabled_ids+=("$target_id")
        fi
      else
        disabled_ids+=("$target_id")
      fi

      write_skills_config "${enabled_ids[@]+"${enabled_ids[@]}"}" "__MCREPO_DISABLED_SPLIT__" "${disabled_ids[@]+"${disabled_ids[@]}"}"
      sync_workspace_skills_to_opencode
      log "Skill '$target_id' set to $subcmd"
      ;;
    validate)
      [ "$#" -eq 0 ] || die "Usage: ./mcrepo.sh skill [repo-name] validate"

      local failures=0
      local id skill_dir
      while IFS= read -r id; do
        skill_dir="$SKILL_SCOPE_DIR/$id"
        if [ ! -f "$skill_dir/skill.md" ] && [ ! -f "$skill_dir/SKILL.md" ]; then
          warn "Missing skill.md or SKILL.md for '$id'"
          failures=$((failures + 1))
        fi
        if [ -f "$skill_dir/run.sh" ] && [ ! -x "$skill_dir/run.sh" ]; then
          warn "run.sh is not executable for '$id'"
          failures=$((failures + 1))
        fi
      done < <(list_skill_ids "$SKILL_SCOPE_DIR")

      if [ "$SKILL_SCOPE_KIND" = "workspace" ] && [ -f "$SKILLS_CONFIG_FILE" ]; then
        for id in $(parse_skill_config_list "enabled"; parse_skill_config_list "disabled"); do
          [ -z "$id" ] && continue
          if [ ! -f "$SUPPORT_SKILLS_DIR/$id/skill.md" ] && [ ! -f "$SUPPORT_SKILLS_DIR/$id/SKILL.md" ]; then
            warn "Configured skill missing on disk: $id"
            failures=$((failures + 1))
          fi
        done
      fi

      if [ "$failures" -gt 0 ]; then
        die "Skill validation failed with $failures issue(s)."
      fi

      if [ "$SKILL_SCOPE_KIND" = "workspace" ]; then
        sync_workspace_skills_to_opencode
      fi
      log "Skill validation passed."
      ;;
  esac
}

cmd_open() {
  [ "$#" -eq 1 ] || die "Usage: ./mcrepo.sh open <repo-name>"
  local repo_name="$1"

  load_repos
  local idx
  idx="$(find_repo_index "$repo_name")" || die "Repo not found: $repo_name"

  local mode
  mode="${REPO_MODES[$idx]}"
  if [ "$mode" != "write" ]; then
    die "You should only open projects that are in write mode. '$repo_name' is in mode '$mode'."
  fi

  local repo_dir
  repo_dir="$(ensure_repo_dir_mode "${REPO_NAMES[$idx]}" "write")"

  if [ ! -d "$repo_dir" ]; then
    die "Repository directory does not exist: $repo_dir"
  fi

  if ! command -v code >/dev/null 2>&1; then
    die "VS Code CLI 'code' not found in PATH.
Install it in VS Code:
  1) Open VS Code
  2) Press Cmd+Shift+P (or F1) to open Command Palette
  3) Run: Shell Command: Install 'code' command in PATH
  4) Restart terminal
  5) Verify: code --version"
  fi

  code "$repo_dir"
  log "Opened '$repo_name' in VS Code: $repo_dir"
}

# Detect the default branch of a repo when no parent is recorded in mcrepo.yaml.
# Uses a 3-layer fallback: (1) local symbolic-ref for origin/HEAD (fast, no network),
# (2) ls-remote query to origin (network, caches result via set-head),
# (3) heuristic check for common branch names (main/master/develop/trunk).
# Returns empty string if detection fails.
# ─── Capability / platform layer ────────────────────────────────────────────
# These helpers underpin the origin/upstream (fork) workflow. All gh-dependent
# helpers DEGRADE GRACEFULLY: when gh is missing/unauthenticated they return a
# non-zero status or "unknown" rather than calling die(), so plain-git workflows
# (clone/push/branch/merge) keep working without GitHub CLI.

# Parse a git URL (https, ssh git@host:owner/repo.git, ssh://) into components.
# Sets globals GU_HOST, GU_OWNER, GU_REPO. Returns 1 if it cannot be parsed.
parse_git_url() {
  local url="$1"
  GU_HOST=""; GU_OWNER=""; GU_REPO=""
  [ -n "$url" ] || return 1
  url="${url%%\#*}"; url="${url%%\?*}"
  local rest
  case "$url" in
    git@*:*)
      # scp-like: git@host:owner/repo(.git)
      GU_HOST="${url#git@}"; GU_HOST="${GU_HOST%%:*}"
      rest="${url#*:}"
      ;;
    ssh://*)
      rest="${url#ssh://}"; rest="${rest#*@}"   # drop optional user@
      GU_HOST="${rest%%/*}"; GU_HOST="${GU_HOST%%:*}"  # strip optional :port
      rest="${rest#*/}"
      ;;
    http://*|https://*)
      rest="${url#*://}"; rest="${rest#*@}"
      GU_HOST="${rest%%/*}"
      rest="${rest#*/}"
      ;;
    *)
      return 1
      ;;
  esac
  GU_OWNER="${rest%%/*}"
  local tail="${rest#*/}"
  GU_REPO="${tail%%/*}"
  GU_REPO="${GU_REPO%.git}"
  [ -n "$GU_HOST" ] && [ -n "$GU_OWNER" ] && [ -n "$GU_REPO" ]
}

# True if the URL points at github.com (door left open for other platforms later).
url_is_github() {
  parse_git_url "$1" >/dev/null 2>&1 || return 1
  [ "$GU_HOST" = "github.com" ]
}

# Cached gh readiness: gh installed AND authenticated. 0 = ready.
_GH_READY_CACHE=""
gh_ready() {
  if [ -z "$_GH_READY_CACHE" ]; then
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      _GH_READY_CACHE="yes"
    else
      _GH_READY_CACHE="no"
    fi
  fi
  [ "$_GH_READY_CACHE" = "yes" ]
}

# Authenticated GitHub login (fork owner). Empty if gh not ready.
gh_login() {
  gh_ready || { printf ''; return 1; }
  gh api user --jq '.login' 2>/dev/null || printf ''
}

# Fetch repo info for <owner/repo>. Prints TSV: viewerPermission, isFork,
# parentNameWithOwner, defaultBranch. Returns 1 if gh not ready or lookup fails.
gh_repo_info() {
  local slug="$1"
  gh_ready || return 1
  gh repo view "$slug" --json viewerPermission,isFork,parent,defaultBranchRef \
    --jq '[.viewerPermission, (.isFork|tostring), (.parent.nameWithOwner // ""), (.defaultBranchRef.name // "")] | @tsv' 2>/dev/null
}

# True if the viewerPermission string grants push access.
gh_perm_can_push() {
  case "$1" in ADMIN|MAINTAIN|WRITE) return 0 ;; *) return 1 ;; esac
}

# Ensure a git remote named 'upstream' exists in repo_dir pointing at url.
ensure_upstream_remote() {
  local repo_dir="$1" url="$2"
  [ -n "$url" ] || return 0
  [ -d "$repo_dir/.git" ] || return 0
  if ! validate_repo_url "$url"; then
    warn "Refusing to wire upstream for '$repo_dir': unsupported or unsafe URL '$url'."
    return 1
  fi
  local cur
  cur="$(git -C "$repo_dir" remote get-url upstream 2>/dev/null || true)"
  if [ -z "$cur" ]; then
    git -C "$repo_dir" remote add upstream "$url" 2>/dev/null || true
  elif [ "$cur" != "$url" ]; then
    git -C "$repo_dir" remote set-url upstream "$url" 2>/dev/null || true
  fi
}

# Detect the default branch of a given remote (default: origin). Mirrors the
# origin-only detection but parameterized so we can ask the 'upstream' remote.
detect_default_branch_remote() {
  local repo_dir="$1"
  local remote="${2:-origin}"
  local branch

  # Layer 1: Local symbolic ref (fast, no network)
  branch=$(git -C "$repo_dir" symbolic-ref "refs/remotes/$remote/HEAD" 2>/dev/null | sed "s|refs/remotes/$remote/||")
  if [ -n "$branch" ]; then
    printf '%s' "$branch"
    return 0
  fi

  # Layer 2: Remote query (needs network)
  branch=$(git -C "$repo_dir" ls-remote --symref "$remote" HEAD 2>/dev/null | head -1 | sed 's|.*refs/heads/||; s|\t.*||')
  if [ -n "$branch" ]; then
    git -C "$repo_dir" remote set-head "$remote" "$branch" 2>/dev/null
    printf '%s' "$branch"
    return 0
  fi

  # Layer 3: Heuristic fallback
  local candidate
  for candidate in main master develop trunk; do
    if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/$remote/$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  printf ''
}

detect_default_branch() {
  detect_default_branch_remote "$1" "origin"
}

switch_repo_branch() {
  local repo_dir="$1"
  local target_branch="$2"
  # Chokepoint validation: the branch may come straight from mcrepo.yaml
  # (branch:/parent: of a shared workspace), not only from CLI args.
  if ! validate_branch_name "$target_branch"; then
    warn "Skipping '$repo_dir': invalid branch name '$target_branch'"
    return 1
  fi
  if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "Skipping '$repo_dir' (not a local git repo)"
    return 0
  fi

  if ! git -C "$repo_dir" fetch --all --prune; then
    warn "Fetch failed in '$repo_dir' before switching to '$target_branch'"
  fi

  if git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    if ! git -C "$repo_dir" pull --ff-only; then
      warn "Pull failed in '$repo_dir' before switching to '$target_branch'"
    fi
  fi

  if git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
    if ! git -C "$repo_dir" fetch origin --prune; then
      warn "Fetch origin failed in '$repo_dir' before switching to '$target_branch'"
    fi
  fi

  if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$target_branch"; then
    git -C "$repo_dir" checkout "$target_branch"
    return 0
  fi

  if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
    git -C "$repo_dir" checkout --track "origin/$target_branch"
    return 0
  fi

  git -C "$repo_dir" checkout -b "$target_branch"
}

# List branches across write-mode repos (and meta-context). Shows the currently
# active global/coordinated branch, branches present in every participating
# repo (fully coordinated), and branches only present in some repos (partial).
cmd_branch_list() {
  load_repos

  log ""
  log "=== Coordinated branches ==="
  log ""

  if [ -n "$GLOBAL_BRANCH" ]; then
    log "Active global branch: $GLOBAL_BRANCH"
  else
    log "Active global branch: (none — repos are on their default/parent branches)"
  fi

  local i mode repo_name repo_dir
  local -a part_names=()
  local -a part_dirs=()

  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    [ "$mode" = "write" ] || continue
    repo_name="${REPO_NAMES[$i]}"
    repo_dir="$(get_repo_dir "$repo_name" "$mode")"
    [ -d "$repo_dir/.git" ] || continue
    part_names+=("$repo_name")
    part_dirs+=("$repo_dir")
  done

  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    part_names+=("(meta-context)")
    part_dirs+=(".")
  fi

  local repo_count="${#part_names[@]}"
  if [ "$repo_count" -eq 0 ]; then
    log ""
    log "No write-mode repositories available to list branches from."
    return 0
  fi

  log ""
  log "Participating repos ($repo_count):"
  for i in "${!part_names[@]}"; do
    log "  - ${part_names[$i]}"
  done

  local -a branch_list=()
  local -a branch_counts=()
  local j k dir branch found
  for j in "${!part_dirs[@]}"; do
    dir="${part_dirs[$j]}"
    while IFS= read -r branch; do
      [ -n "$branch" ] || continue
      found=-1
      for k in "${!branch_list[@]}"; do
        if [ "${branch_list[$k]}" = "$branch" ]; then
          found="$k"
          break
        fi
      done
      if [ "$found" = "-1" ]; then
        branch_list+=("$branch")
        branch_counts+=(1)
      else
        branch_counts[$found]=$(( ${branch_counts[$found]} + 1 ))
      fi
    done < <(git -C "$dir" for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null)
  done

  if [ "${#branch_list[@]}" -eq 0 ]; then
    log ""
    log "No local branches found in participating repos."
    return 0
  fi

  local -a full_lines=()
  local -a partial_lines=()
  local b c marker
  for k in "${!branch_list[@]}"; do
    b="${branch_list[$k]}"
    c="${branch_counts[$k]}"
    marker=" "
    if [ -n "$GLOBAL_BRANCH" ] && [ "$b" = "$GLOBAL_BRANCH" ]; then
      marker="*"
    fi
    if [ "$c" -eq "$repo_count" ]; then
      full_lines+=("  $marker $b")
    else
      partial_lines+=("  $marker $b  ($c/$repo_count repos)")
    fi
  done

  log ""
  if [ "${#full_lines[@]}" -gt 0 ]; then
    log "Branches present in all $repo_count repo(s):"
    printf '%s\n' "${full_lines[@]}" | LC_ALL=C sort
  else
    log "No branches are present across all $repo_count repo(s)."
  fi

  if [ "${#partial_lines[@]}" -gt 0 ]; then
    log ""
    log "Branches present in some repos only:"
    printf '%s\n' "${partial_lines[@]}" | LC_ALL=C sort
  fi

  log ""
  log "Legend: '*' marks the currently active coordinated branch."
  log "Use './mcrepo.sh branch <name>' to switch or create a coordinated branch."
}

# Switch all target repos (and meta-context) to a branch. Handles two modes:
#   Fork (new branch): confirms with user, records current branch as parent.
#   Jump (existing branch): switches without recording parent.
# If uncommitted changes exist, offers interactive options:
#   [a]bort, [c]ommit, [r] carry (dry-run stash+pop), [d]iscard.
# Also handles --off (disable coordination), --delete (discard branch),
# and 'list' / no args (list coordinated branches).
cmd_branch() {
  if [ "$#" -eq 0 ] || [ "${1:-}" = "list" ] || [ "${1:-}" = "--list" ]; then
    cmd_branch_list
    return 0
  fi

  # Handle "branch --off" (and deprecated "branch off") — turn off global branch coordination
  if [ "${1:-}" = "--off" ]; then
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --include-read) die "'--include-read' is not supported with 'branch --off'." ;;
        *) die "Unknown branch option: $1" ;;
      esac
      shift
    done
    load_repos
    if [ -z "$GLOBAL_BRANCH" ]; then
      log "Global branch coordination is already off."
      return 0
    fi
    GLOBAL_BRANCH=""
    # Clear all parent stacks — branch history is no longer meaningful
    # once coordination is off, since repos manage branches independently.
    local i
    for i in "${!REPO_PARENTS[@]}"; do
      REPO_PARENTS[$i]=""
    done
    META_PARENT=""
    save_repos
    log "Global branch coordination turned off. Repos keep their current branches."
    warn "Repos remain on their current branches without coordination."
    warn "Cleaner alternatives: 'mcrepo merge' (integrate changes) or 'mcrepo branch --delete' (discard branch)."
    return 0
  fi

  # Handle "branch --delete" — delete global branch, revert to parent branches
  if [ "${1:-}" = "--delete" ]; then
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        *) die "Unknown option for branch --delete: $1" ;;
      esac
    done
    cmd_branch_delete
    return 0
  fi

  # Flags may appear before or after the branch name. A leading-dash value is
  # never accepted as a branch name (git forbids them anyway) — this catches
  # typos like '--delte' before they trigger a slow fetch across all repos.
  local branch_name="" include_read=0 dirty_action_flag=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --include-read) include_read=1 ;;
      --dirty)
        shift
        dirty_action_flag="${1:-}"
        case "$dirty_action_flag" in
          abort|commit|carry|discard) ;;
          *) die "--dirty must be one of: abort|commit|carry|discard" ;;
        esac
        ;;
      -*) die "Unknown branch option: $1" ;;
      *)
        if [ -z "$branch_name" ]; then
          branch_name="$1"
        else
          die "Unexpected argument: $1 (branch name already given: '$branch_name')"
        fi
        ;;
    esac
    shift
  done
  [ -n "$branch_name" ] || die "Usage: ./mcrepo.sh branch <branch-name> [--include-read] [--dirty abort|commit|carry|discard]"
  [ "$branch_name" != "off" ] || die "'mcrepo branch off' was removed. Use 'mcrepo branch --off' to turn off coordination."
  validate_branch_name "$branch_name" || die "Invalid branch name: '$branch_name'"

  load_repos
  _require_no_stuck_repos "branch"

  # --- Phase 1: Fetch and classify repos (fork vs jump) ---
  local i mode repo_dir
  local -a target_indexes=()
  local -a target_dirs=()
  local -a target_is_fork=()
  local -a fork_names=()
  local -a jump_names=()
  local meta_is_target=0
  local meta_is_fork=0

  log "Fetching remotes to detect fork vs. jump ..."
  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    if [ "$mode" = "write" ] || { [ "$include_read" -eq 1 ] && [ "$mode" = "read" ]; }; then
      repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "$mode")"
      if [ -d "$repo_dir/.git" ]; then
        # Fetch to ensure remote refs are current for fork-vs-jump detection
        printf '  fetching %s ...\r' "${REPO_NAMES[$i]}" >&2
        git -C "$repo_dir" fetch --all --prune 2>/dev/null || true

        local is_fork=1
        if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch_name" || \
           git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
          is_fork=0
        fi

        target_indexes+=("$i")
        target_dirs+=("$repo_dir")
        target_is_fork+=("$is_fork")
        if [ "$is_fork" -eq 1 ]; then
          fork_names+=("${REPO_NAMES[$i]}")
        else
          jump_names+=("${REPO_NAMES[$i]}")
        fi
      fi
    fi
  done

  # Meta-context repo classification
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    meta_is_target=1
    printf '  fetching %s ...\r' "(meta-context)" >&2
    git -C . fetch --all --prune 2>/dev/null || true
    if git -C . show-ref --verify --quiet "refs/heads/$branch_name" || \
       git -C . show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
      meta_is_fork=0
    else
      meta_is_fork=1
    fi
    if [ "$meta_is_fork" -eq 1 ]; then
      fork_names+=("(meta-context)")
    else
      jump_names+=("(meta-context)")
    fi
  fi

  # --- Phase 2: Fork confirmation (interactive, only if at least one fork) ---
  if [ "${#fork_names[@]}" -eq 0 ] && [ "${#jump_names[@]}" -gt 0 ]; then
    log ""
    log "Branch '$branch_name' already exists in all target repos — switching to existing branch (no new branch will be created)."
    log "  Jump targets: ${jump_names[*]}"
    log ""
  fi
  if [ "${#fork_names[@]}" -gt 0 ]; then
    log ""
    log "Branch '$branch_name' would be NEW (fork) in: ${fork_names[*]}"
    if [ "${#jump_names[@]}" -gt 0 ]; then
      log "Branch '$branch_name' already exists (jump) in: ${jump_names[*]}"
    fi
    log "Parent branch per fork (current branch → recorded as parent):"
    for idx in "${!target_indexes[@]}"; do
      if [ "${target_is_fork[$idx]}" -eq 1 ]; then
        local ti="${target_indexes[$idx]}"
        local rname="${REPO_NAMES[$ti]}"
        local rdir="${target_dirs[$idx]}"
        local rcur
        rcur="$(repo_branch "$rdir" 2>/dev/null || echo "unknown")"
        log "  $rname → $rcur"
      fi
    done
    if [ "$meta_is_target" -eq 1 ] && [ "$meta_is_fork" -eq 1 ]; then
      local meta_cur
      meta_cur="$(repo_branch "." 2>/dev/null || echo "unknown")"
      log "  (meta-context) → $meta_cur"
    fi
    log ""

    if ! confirm "Proceed?" y; then
      log "Aborted."
      return 0
    fi
  fi

  # --- Phase 3: Dirty-repo detection ---
  local dirty_found=0
  local -a dirty_repos=()
  local -a dirty_repo_dirs=()

  for idx in "${!target_indexes[@]}"; do
    local ti="${target_indexes[$idx]}"
    repo_dir="${target_dirs[$idx]}"
    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
      dirty_found=1
      dirty_repos+=("${REPO_NAMES[$ti]} ($repo_dir)")
      dirty_repo_dirs+=("$repo_dir")
    fi
  done

  local meta_dirty=0
  if [ "$meta_is_target" -eq 1 ]; then
    if [ -n "$(git -C . status --porcelain 2>/dev/null)" ]; then
      dirty_found=1
      meta_dirty=1
      dirty_repos+=("meta-context repo (.)")
      dirty_repo_dirs+=(".")
    fi
  fi

  # --- Phase 4: Interactive dirty handling ---
  local dirty_action="abort"
  if [ "$dirty_found" -eq 1 ]; then
    log ""
    log "Uncommitted changes in: ${dirty_repos[*]}"
    log ""

    if [ -n "$dirty_action_flag" ]; then
      dirty_action="$dirty_action_flag"
      log "Handling uncommitted changes with --dirty $dirty_action."
    elif [ -t 0 ] && [ -t 1 ]; then
      printf 'How would you like to handle uncommitted changes?\n' >&2
      printf '  [a] Abort  — stop and handle manually\n' >&2
      printf '  [c] Commit — auto-commit to current branch before switching\n' >&2
      printf '  [r] Carry  — carry changes into the target branch (stash + pop)\n' >&2
      printf '  [d] Discard — discard all uncommitted changes\n' >&2
      printf '\n' >&2
      printf 'Choice [a/c/r/d]: ' >&2
      local choice
      IFS= read -r choice
      case "$choice" in
        c|C) dirty_action="commit" ;;
        r|R) dirty_action="carry" ;;
        d|D) dirty_action="discard" ;;
        *) dirty_action="abort" ;;
      esac
    fi

    if [ "$dirty_action" = "abort" ]; then
      die "Uncommitted changes found in: ${dirty_repos[*]}. Commit, stash, or discard them and run branch again."
    fi

    if [ "$dirty_action" = "commit" ]; then
      local _bb _bs _bsubj
      _bb="$(mcrepo_new_batch_id)"
      _bs="$(mcrepo_next_seq "${dirty_repo_dirs[@]+"${dirty_repo_dirs[@]}"}")"
      _bsubj="$(mcrepo_commit_subject "$_bs" "$_bb" "pre-branch-switch to $branch_name")"
      log "Coordinated commit #$_bs before switching ..."
      for ddir in "${dirty_repo_dirs[@]}"; do
        if [ -n "$(git -C "$ddir" status --porcelain 2>/dev/null)" ]; then
          mcrepo_do_commit "$ddir" "$ddir" "$_bsubj" || die "Coordinated commit failed in '$ddir'. Please commit manually."
        fi
      done
    fi

    if [ "$dirty_action" = "discard" ]; then
      log "Discarding uncommitted changes ..."
      for ddir in "${dirty_repo_dirs[@]}"; do
        if [ -n "$(git -C "$ddir" status --porcelain 2>/dev/null)" ]; then
          git -C "$ddir" checkout -- . 2>/dev/null || true
          git -C "$ddir" clean -fd 2>/dev/null || true
          log "  Discarded in $ddir"
        fi
      done
    fi

    if [ "$dirty_action" = "carry" ]; then
      # Dry-run: verify stash carry would succeed on target branch BEFORE modifying anything
      log "Checking if changes can be carried to '$branch_name' ..."
      local carry_ok=1
      local -a carry_fail_repos=()

      for ddir in "${dirty_repo_dirs[@]}"; do
        if [ -z "$(git -C "$ddir" status --porcelain 2>/dev/null)" ]; then
          continue
        fi

        local ddir_name="$ddir"
        if [ "$ddir" = "." ]; then
          ddir_name="(meta-context)"
        fi

        # Reset per repo: 'git stash create' returns nothing for untracked-only
        # changes, and a stale value from the previous iteration must not leak
        # into this repo's untracked-collision check below.
        local target_ref=""

        # Create stash commit without modifying working tree (returns SHA)
        local stash_sha
        stash_sha="$(git -C "$ddir" stash create 2>/dev/null || true)"

        if [ -n "$stash_sha" ]; then
          # Determine effective target tree (the branch we're switching to)
          if git -C "$ddir" show-ref --verify --quiet "refs/heads/$branch_name"; then
            target_ref="$branch_name"
          elif git -C "$ddir" show-ref --verify --quiet "refs/remotes/origin/$branch_name"; then
            target_ref="origin/$branch_name"
          fi

          if [ -n "$target_ref" ]; then
            # Test if tracked-change patch applies against target branch tree
            local tmpindex
            tmpindex="$(mktemp)"
            GIT_INDEX_FILE="$tmpindex" git -C "$ddir" read-tree "$target_ref" 2>/dev/null || true
            if ! git -C "$ddir" stash show -p "$stash_sha" 2>/dev/null | \
                 GIT_INDEX_FILE="$tmpindex" git -C "$ddir" apply --check --cached 2>/dev/null; then
              carry_ok=0
              carry_fail_repos+=("$ddir_name")
            fi
            rm -f "$tmpindex"
          fi
          # If target_ref is empty, this is a fork (new branch from current HEAD).
          # Stash pop on same tree content always works — no conflict possible.
        fi

        # Check untracked files: would they collide with files on the target branch?
        if [ -n "$target_ref" ]; then
          local untracked_file
          while IFS= read -r untracked_file; do
            [ -n "$untracked_file" ] || continue
            if git -C "$ddir" ls-tree --name-only "$target_ref" -- "$untracked_file" 2>/dev/null | grep -q .; then
              carry_ok=0
              # Only add if not already in the fail list
              local already_listed=0
              local cr
              for cr in "${carry_fail_repos[@]:-}"; do
                if [ "$cr" = "$ddir_name" ]; then already_listed=1; break; fi
              done
              if [ "$already_listed" -eq 0 ]; then
                carry_fail_repos+=("$ddir_name")
              fi
              break
            fi
          done < <(git -C "$ddir" ls-files --others --exclude-standard 2>/dev/null)
        fi
      done

      if [ "$carry_ok" -eq 0 ]; then
        log ""
        log "Cannot carry changes to '$branch_name'. Conflicts would occur in:"
        local cfr
        for cfr in "${carry_fail_repos[@]}"; do
          log "  - $cfr"
        done
        log ""
        log "The changes are too different from the branch you want to switch to."
        log "Please commit your changes to the current branch or discard them, then try again."
        die "Carry aborted — no changes were made."
      fi

      # Dry-run passed — stash all dirty repos
      log "Stashing changes ..."
      for ddir in "${dirty_repo_dirs[@]}"; do
        if [ -n "$(git -C "$ddir" status --porcelain 2>/dev/null)" ]; then
          git -C "$ddir" stash push -m "mcrepo: carry to $branch_name" --include-untracked
          log "  Stashed in $ddir"
        fi
      done
    fi
  fi

  # --- Phase 5: Switch branches (with fork-vs-jump parent tracking) ---
  # Safety trap: save partial progress if the script aborts mid-loop (set -e,
  # Ctrl-C). Parent stacks are pushed only AFTER each repo's switch succeeds,
  # so this persists exactly the repos that actually moved — and it records the
  # new global branch only when at least one repo is on it (a first-repo abort
  # must not flag the whole workspace OFF-GLOBAL).
  _BRANCH_SWITCHED_COUNT=0
  _branch_switch_exit_trap() {
    if [ "${_BRANCH_SWITCHED_COUNT:-0}" -gt 0 ]; then
      GLOBAL_BRANCH="$branch_name"
      save_repos
      warn "Branch switch interrupted after $_BRANCH_SWITCHED_COUNT repo(s). Unswitched repos show as OFF-GLOBAL in 'mcrepo status'. Re-run 'mcrepo branch $branch_name' to finish (carried stashes are restored automatically)."
    fi
  }
  trap '_branch_switch_exit_trap' EXIT

  for idx in "${!target_indexes[@]}"; do
    local ti="${target_indexes[$idx]}"
    repo_dir="${target_dirs[$idx]}"
    local rname="${REPO_NAMES[$ti]}"
    local parent_for_log=""

    # Capture the pre-switch branch; the parent stack is pushed after the
    # switch succeeds (see trap note above).
    if [ "${target_is_fork[$idx]}" -eq 1 ]; then
      parent_for_log="$(repo_branch "$repo_dir")"
    fi

    switch_repo_branch "$repo_dir" "$branch_name"
    _BRANCH_SWITCHED_COUNT=$((_BRANCH_SWITCHED_COUNT + 1))

    if [ "${target_is_fork[$idx]}" -eq 1 ]; then
      # Stack format: "grandparent,parent" — rightmost is immediate parent.
      if [ -n "${REPO_PARENTS[$ti]:-}" ]; then
        REPO_PARENTS[$ti]="${REPO_PARENTS[$ti]},$parent_for_log"
      else
        REPO_PARENTS[$ti]="$parent_for_log"
      fi
      log "  '$rname': created NEW branch '$branch_name' off parent '$parent_for_log'."
    else
      log "  '$rname': switched to EXISTING branch '$branch_name' (no parent recorded)."
    fi
  done

  # Meta-context repo: fork-vs-jump parent tracking + switch
  if [ "$meta_is_target" -eq 1 ]; then
    local meta_parent_for_log=""
    if [ "$meta_is_fork" -eq 1 ]; then
      meta_parent_for_log="$(repo_branch ".")"
    fi
    switch_repo_branch "." "$branch_name"
    _BRANCH_SWITCHED_COUNT=$((_BRANCH_SWITCHED_COUNT + 1))

    if [ "$meta_is_fork" -eq 1 ]; then
      if [ -n "$META_PARENT" ]; then
        META_PARENT="${META_PARENT},$meta_parent_for_log"
      else
        META_PARENT="$meta_parent_for_log"
      fi
      log "  '(meta-context)': created NEW branch '$branch_name' off parent '$meta_parent_for_log'."
    else
      log "  '(meta-context)': switched to EXISTING branch '$branch_name' (no parent recorded)."
    fi
  fi

  # --- Phase 6: Restore carried stashes ---
  # Scan ALL target repos, not just the ones stashed in THIS run: if a previous
  # 'branch <name>' was interrupted between stash and pop (Ctrl-C during the
  # network-bound switch loop), the carried work sits in per-repo stashes while
  # every tree looks clean — restore it now instead of losing it silently.
  local -a carry_scan_dirs=()
  for idx in "${!target_indexes[@]}"; do
    carry_scan_dirs+=("${target_dirs[$idx]}")
  done
  [ "$meta_is_target" -eq 1 ] && carry_scan_dirs+=(".")
  local restored_any=0
  local -a carry_fail_entries=()
  for ddir in "${carry_scan_dirs[@]}"; do
    local stash_msg
    stash_msg="$(git -C "$ddir" stash list -1 2>/dev/null | head -1)"
    if echo "$stash_msg" | grep -q "mcrepo: carry to $branch_name"; then
      [ "$restored_any" -eq 1 ] || log "Restoring carried changes ..."
      restored_any=1
      if ! git -C "$ddir" stash pop; then
        warn "Stash pop had issues in '$ddir'. Resolve the conflicted files, 'git -C $ddir add' them, then 'git -C $ddir stash drop'."
        carry_fail_entries+=("$ddir|$ddir")
      else
        log "  Restored in $ddir"
      fi
    fi
  done
  if [ "${#carry_fail_entries[@]}" -gt 0 ]; then
    MCREPO_RECOVERY_CONTEXT="Stash name: mcrepo: carry to $branch_name"
    print_agent_recovery_prompt carry-conflict "${carry_fail_entries[@]}"
  fi

  GLOBAL_BRANCH="$branch_name"
  trap - EXIT
  save_repos

  log "Branch operation complete. Global branch set to '$GLOBAL_BRANCH'."
  log "Next: work on the feature; checkpoint anytime with 'mcrepo commit -m \"...\"'. When done: 'mcrepo rebase', then 'mcrepo merge'."
}

# Delete the current global branch in each write-repo and meta-context,
# switch repos back to their parent branches, and pop the parent stack.
# Counterpart to 'mcrepo merge' (which saves work). This discards the branch.
cmd_branch_delete() {
  load_repos

  if [ -z "$GLOBAL_BRANCH" ]; then
    die "No global branch set. Nothing to delete."
  fi

  local source_branch="$GLOBAL_BRANCH"

  # Phase 1: Pre-flight — collect repos and check for dirty state
  log ""
  log "=== Branch --delete: removing '$source_branch' ==="
  log ""

  local i mode repo_dir repo_name
  local -a del_indexes=()
  local -a del_dirs=()
  local -a del_parents=()
  local -a dirty_repos=()
  local -a preflight_errors=()

  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    [ "$mode" = "write" ] || continue
    repo_name="${REPO_NAMES[$i]}"
    repo_dir="$(get_repo_dir "$repo_name" "$mode")"
    [ -d "$repo_dir/.git" ] || continue

    # Check if repo is on the global branch
    local actual_branch
    actual_branch="$(repo_branch "$repo_dir")"
    if [ "$actual_branch" != "$source_branch" ]; then
      # Not on the global branch — check if the branch even exists here
      if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$source_branch"; then
        log "  '$repo_name': branch '$source_branch' does not exist. Skipping."
        continue
      fi
    fi

    # Determine parent branch (pop target)
    local parent_branch=""
    if [ -n "${REPO_PARENTS[$i]:-}" ]; then
      parent_branch="${REPO_PARENTS[$i]##*,}"
    fi
    if [ -z "$parent_branch" ]; then
      parent_branch="$(detect_default_branch "$repo_dir")"
    fi
    if [ -z "$parent_branch" ]; then
      preflight_errors+=("'$repo_name': no parent branch recorded and cannot detect default branch.")
      continue
    fi

    # Source == parent guard
    if [ "$source_branch" = "$parent_branch" ]; then
      log "  '$repo_name': already on parent branch '$parent_branch'. Skipping."
      continue
    fi

    # Dirty check
    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
      dirty_repos+=("$repo_name ($repo_dir)")
    fi

    del_indexes+=("$i")
    del_dirs+=("$repo_dir")
    del_parents+=("$parent_branch")
  done

  # Meta-context repo pre-flight
  local meta_parent_branch=""
  local meta_included=0
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local meta_actual
    meta_actual="$(repo_branch ".")"
    if [ -n "$META_PARENT" ]; then
      meta_parent_branch="${META_PARENT##*,}"
    fi
    if [ -z "$meta_parent_branch" ]; then
      meta_parent_branch="$(detect_default_branch ".")"
    fi

    if [ -n "$meta_parent_branch" ] && [ "$meta_parent_branch" != "$source_branch" ]; then
      if [ "$meta_actual" = "$source_branch" ] || git -C . show-ref --verify --quiet "refs/heads/$source_branch"; then
        if [ -n "$(git -C . status --porcelain 2>/dev/null)" ]; then
          dirty_repos+=("meta-context repo (.)")
        fi
        meta_included=1
      fi
    fi
  fi

  if [ "${#dirty_repos[@]}" -gt 0 ]; then
    die "Uncommitted changes found in: ${dirty_repos[*]}. Commit or discard changes first, or use 'mcrepo branch --off' to leave as-is."
  fi

  if [ "${#preflight_errors[@]}" -gt 0 ]; then
    log "Pre-flight errors:"
    local err
    for err in "${preflight_errors[@]}"; do
      log "  - $err"
    done
    die "Fix the above issues and try again."
  fi

  if [ "${#del_indexes[@]}" -eq 0 ] && [ "$meta_included" -eq 0 ]; then
    log "No repos have branch '$source_branch' to delete."
    return 0
  fi

  # Phase 2: Switch to parent and delete the feature branch
  # Safety trap: save partial progress if the script aborts mid-loop.
  trap 'save_repos' EXIT

  log "Delete plan:"
  local idx
  for idx in "${!del_indexes[@]}"; do
    printf '  %-20s delete %s, switch to %s\n' "${REPO_NAMES[${del_indexes[$idx]}]}" "$source_branch" "${del_parents[$idx]}"
  done
  if [ "$meta_included" -eq 1 ]; then
    printf '  %-20s delete %s, switch to %s\n' "(meta-context)" "$source_branch" "$meta_parent_branch"
  fi
  log ""

  for idx in "${!del_indexes[@]}"; do
    local ri="${del_indexes[$idx]}"
    repo_name="${REPO_NAMES[$ri]}"
    repo_dir="${del_dirs[$idx]}"
    local target="${del_parents[$idx]}"

    log "Processing '$repo_name' ..."

    # Ensure parent branch exists locally
    if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$target"; then
      if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$target"; then
        git -C "$repo_dir" branch --track "$target" "origin/$target" 2>/dev/null || true
      else
        warn "  Parent branch '$target' not found. Skipping."
        continue
      fi
    fi

    git -C "$repo_dir" checkout "$target"
    # Safe delete first; if unmerged commits exist, ask before force-deleting
    if ! git -C "$repo_dir" branch -d "$source_branch" 2>/dev/null; then
      warn "  '$repo_name': branch '$source_branch' has unmerged/unpushed commits."
      if confirm "  Force-delete anyway? Unpushed commits will be lost." n; then
        git -C "$repo_dir" branch -D "$source_branch" 2>/dev/null || true
      else
        warn "  Kept branch '$source_branch' in '$repo_name'. Merge or push it first."
      fi
    fi
    log "  Switched to '$target'."

    # Pop parent stack one level
    local current_parent="${REPO_PARENTS[$ri]:-}"
    if [[ "$current_parent" == *,* ]]; then
      REPO_PARENTS[$ri]="${current_parent%,*}"
    else
      REPO_PARENTS[$ri]=""
    fi
  done

  # Meta-context repo
  if [ "$meta_included" -eq 1 ]; then
    log "Processing '(meta-context)' ..."

    if ! git -C . show-ref --verify --quiet "refs/heads/$meta_parent_branch"; then
      if git -C . show-ref --verify --quiet "refs/remotes/origin/$meta_parent_branch"; then
        git -C . branch --track "$meta_parent_branch" "origin/$meta_parent_branch" 2>/dev/null || true
      fi
    fi

    git -C . checkout "$meta_parent_branch"
    # Safe delete for meta-context
    if ! git -C . branch -d "$source_branch" 2>/dev/null; then
      warn "  (meta-context): branch '$source_branch' has unmerged/unpushed commits."
      if confirm "  Force-delete anyway? Unpushed commits will be lost." n; then
        git -C . branch -D "$source_branch" 2>/dev/null || true
      else
        warn "  Kept branch '$source_branch' in meta-context. Merge or push it first."
      fi
    fi
    log "  Switched to '$meta_parent_branch'."

    # Pop META_PARENT one level
    if [[ "$META_PARENT" == *,* ]]; then
      META_PARENT="${META_PARENT%,*}"
    else
      META_PARENT=""
    fi
  fi

  # Phase 3: Update GLOBAL_BRANCH
  local first_target="${del_parents[0]:-}"
  local all_same=1
  for idx in "${!del_parents[@]}"; do
    if [ "${del_parents[$idx]}" != "$first_target" ]; then
      all_same=0
      break
    fi
  done
  if [ "$meta_included" -eq 1 ] && [ -n "$first_target" ] && [ "$meta_parent_branch" != "$first_target" ]; then
    all_same=0
  fi

  if [ "$all_same" -eq 1 ] && [ -n "$first_target" ]; then
    GLOBAL_BRANCH="$first_target"
    log ""
    log "Global branch updated to '$GLOBAL_BRANCH'."
  else
    GLOBAL_BRANCH=""
    log ""
    log "Repos reverted to different parent branches. Global branch coordination turned off."
  fi

  trap - EXIT
  save_repos

  log ""
  log "Branch '$source_branch' deleted. Changes are local only."
  if [ -n "$GLOBAL_BRANCH" ]; then
    local has_more_parents=0
    for i in "${!REPO_PARENTS[@]}"; do
      if [ -n "${REPO_PARENTS[$i]:-}" ]; then
        has_more_parents=1
        break
      fi
    done
    if [ -n "$META_PARENT" ]; then
      has_more_parents=1
    fi
    if [ "$has_more_parents" -eq 1 ]; then
      log "Hint: run 'mcrepo branch --delete' again to delete the next branch level."
    fi
  fi
  log "Next: 'mcrepo status' to verify — repos are back on their parent branches."
}

# A branch is "synced" when it already contains its parent tip — then the
# merge back into the parent can never conflict. Checks local <parent> AND
# origin/<parent> (after a best-effort fetch); returns 1 when either is ahead.
_merge_repo_synced() {
  local dir="$1" parent="$2"
  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$dir" fetch origin "$parent" --quiet 2>/dev/null || true
  fi
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$parent"; then
    git -C "$dir" merge-base --is-ancestor "$parent" HEAD 2>/dev/null || return 1
  fi
  if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$parent"; then
    git -C "$dir" merge-base --is-ancestor "origin/$parent" HEAD 2>/dev/null || return 1
  fi
  return 0
}

# Roll a repo back to exactly its pre-merge state after a failed merge attempt:
# abort any in-progress merge, clear staged/unmerged squash leftovers, return
# to the source branch. Best-effort; warns when residue remains.
_merge_rollback_repo() {
  local dir="$1" name="$2" source_branch="$3"
  if git -C "$dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    git -C "$dir" merge --abort 2>/dev/null || true
  fi
  # Failed squash-merge (unmerged entries) or failed squash-commit (staged
  # diff): both are reproducible from the source branch, so dropping is safe.
  git -C "$dir" reset --merge 2>/dev/null || git -C "$dir" reset --hard HEAD 2>/dev/null || true
  git -C "$dir" checkout "$source_branch" 2>/dev/null || \
    warn "  $name: could not switch back to '$source_branch' — check manually."
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    warn "  $name: rollback left residue in the working tree — check manually."
  fi
}

# Merge $source_branch into $target inside one repo. On success the repo sits
# on $target with the merge committed. On any failure the repo is rolled back
# to its pre-merge state on $source_branch and the function returns 1.
_merge_execute_one() {
  local dir="$1" name="$2" target="$3" source_branch="$4" do_squash="$5" commit_message="$6"
  if ! git -C "$dir" checkout "$target"; then
    warn "  $name: could not check out '$target'."
    return 1
  fi
  # Fast-forward the local parent to origin/<parent> when it is simply behind,
  # so the merge lands on the same history 'mcrepo rebase' rebased onto —
  # otherwise the parent gets the remote changes as content but not ancestry,
  # and push later reports phantom divergence.
  if git -C "$dir" show-ref --verify --quiet "refs/remotes/origin/$target"; then
    git -C "$dir" merge --ff-only "origin/$target" >/dev/null 2>&1 || true
  fi
  if [ "$do_squash" -eq 1 ]; then
    local subject="${commit_message:-$source_branch}"
    if ! git -C "$dir" merge --squash "$source_branch"; then
      _merge_rollback_repo "$dir" "$name" "$source_branch"
      return 1
    fi
    if git -C "$dir" diff --cached --quiet; then
      log "  Already up to date."
    else
      if ! git -C "$dir" commit -m "$subject"; then
        _merge_rollback_repo "$dir" "$name" "$source_branch"
        return 1
      fi
      log "  Done."
    fi
  else
    local nf_subject="${commit_message:-Merge branch '$source_branch' into $target}"
    if ! git -C "$dir" merge --no-ff "$source_branch" -m "$nf_subject"; then
      _merge_rollback_repo "$dir" "$name" "$source_branch"
      return 1
    fi
    log "  Done."
  fi
  return 0
}

# EXIT trap during merge execution: persist the manifest (stacks popped so far)
# and tell the user how to resume when the run was interrupted mid-loop.
_MERGE_DONE_COUNT=0
_merge_exit_trap() {
  save_repos
  if [ "${_MERGE_DONE_COUNT:-0}" -gt 0 ]; then
    warn "merge interrupted after ${_MERGE_DONE_COUNT} repo(s) — re-run 'mcrepo merge' to finish the rest."
  fi
}

# Merge the global branch into each write-repo's parent branch (local only, no push).
# '--rebase' is a deprecated alias for 'mcrepo rebase' (rebase onto parent).
#
# Default strategy is squash: collapses all commits on the source branch into a single
# commit on the parent, with the branch name as the default subject. Use --no-squash
# to fall back to the legacy `git merge --no-ff` behavior.
#
# Workflow: pre-flight → sync gate → dry-run → execute → update parent stacks.
# The sync gate requires each repo's branch to already contain its parent tip
# (run 'mcrepo rebase' first), so the merge itself cannot conflict. Repos not on
# the source branch are skipped (already merged or manually switched), which
# makes re-running 'mcrepo merge' the resume path after a partial failure: a
# failed repo is rolled back to the source branch, the rest keep merging, and
# each successful repo's parent stack is popped immediately.
cmd_merge() {
  local do_rebase=0
  local do_squash=1
  local commit_message=""
  local include_read=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rebase) do_rebase=1 ;;
      --no-squash) do_squash=0 ;;
      --squash) do_squash=1 ;;
      --include-read) include_read=1 ;;
      -m) shift; commit_message="${1:-}"; [ -n "$commit_message" ] || die "-m requires a message" ;;
      *) die "Unknown merge option: $1" ;;
    esac
    shift
  done

  load_repos
  _require_no_stuck_repos "merge"

  if [ -z "$GLOBAL_BRANCH" ]; then
    die "No feature branch active — repos are on their default/parent branch already, so there is nothing to merge here. Use 'mcrepo commit' and 'mcrepo push' to send changes directly to origin, or run 'mcrepo branch <name>' to start a new feature branch first."
  fi

  local source_branch="$GLOBAL_BRANCH"

  if [ "$do_rebase" -eq 1 ]; then
    warn "Deprecation: 'mcrepo merge --rebase' is now 'mcrepo rebase' (same behavior)."
    _rebase_run "$source_branch" "$include_read"
    return $?
  fi

  # --- mcrepo merge: merge current branch INTO parent ---

  # Phase 1: Pre-flight checks
  log ""
  log "=== Pre-flight checks ==="
  log ""

  local i mode repo_dir repo_name
  local -a merge_indexes=()
  local -a merge_dirs=()
  local -a merge_parents=()
  local -a preflight_errors=()
  local -a wrong_branch_actuals=()
  local -a skipped_names=()
  local -a dirty_repos=()
  local -a dirty_repo_dirs=()

  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    if [ "$mode" != "write" ]; then
      # --include-read completes the branch/commit --include-read workflow:
      # read repos switched onto the global branch must be mergeable too, or
      # their coordinated commits strand on the feature branch.
      { [ "$include_read" -eq 1 ] && [ "$mode" = "read" ]; } || continue
    fi
    repo_name="${REPO_NAMES[$i]}"
    repo_dir="$(get_repo_dir "$repo_name" "$mode")"
    [ -d "$repo_dir/.git" ] || continue

    # Read immediate parent (last element of comma-separated stack)
    local parent_branch=""
    if [ -n "${REPO_PARENTS[$i]:-}" ]; then
      parent_branch="${REPO_PARENTS[$i]##*,}"
    fi

    # Fallback: detect default branch
    if [ -z "$parent_branch" ]; then
      parent_branch="$(detect_default_branch "$repo_dir")"
    fi

    if [ -z "$parent_branch" ]; then
      preflight_errors+=("'$repo_name': no parent branch recorded and cannot detect default branch.")
      continue
    fi

    # A repo not on the source branch is skipped, not an error: it was already
    # merged by a previous (partial) run or manually switched. Merge only what
    # is actually on the branch; die later only if nothing is left.
    local actual_branch
    actual_branch="$(repo_branch "$repo_dir")"
    if [ "$actual_branch" != "$source_branch" ]; then
      skipped_names+=("$repo_name (on '$actual_branch')")
      wrong_branch_actuals+=("$actual_branch")
      continue
    fi

    # Verify parent branch exists locally
    if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$parent_branch" && \
       ! git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$parent_branch"; then
      preflight_errors+=("'$repo_name': parent branch '$parent_branch' not found locally or on origin.")
    fi

    # Source == parent guard
    if [ "$source_branch" = "$parent_branch" ]; then
      preflight_errors+=("'$repo_name': source '$source_branch' is the same as parent '$parent_branch'.")
      continue
    fi

    # Dirty check
    if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
      dirty_repos+=("$repo_name ($repo_dir)")
      dirty_repo_dirs+=("$repo_dir")
    fi

    merge_indexes+=("$i")
    merge_dirs+=("$repo_dir")
    merge_parents+=("$parent_branch")
  done

  # Meta-context repo pre-flight
  local meta_parent_branch=""
  local meta_included=0
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$META_PARENT" ]; then
      meta_parent_branch="${META_PARENT##*,}"
    fi
    if [ -z "$meta_parent_branch" ]; then
      meta_parent_branch="$(detect_default_branch ".")"
    fi

    if [ -n "$meta_parent_branch" ] && [ "$meta_parent_branch" != "$source_branch" ]; then
      local meta_actual
      meta_actual="$(repo_branch ".")"
      if [ "$meta_actual" != "$source_branch" ]; then
        skipped_names+=("(meta-context) (on '$meta_actual')")
        wrong_branch_actuals+=("$meta_actual")
      else
        if [ -n "$(git -C . status --porcelain 2>/dev/null)" ]; then
          dirty_repos+=("meta-context repo (.)")
          dirty_repo_dirs+=(".")
        fi
        meta_included=1
      fi
    fi
  fi

  if [ "${#dirty_repos[@]}" -gt 0 ]; then
    log ""
    log "Uncommitted changes in: ${dirty_repos[*]}"
    local merge_dirty_choice="abort"
    if [ -t 0 ] && [ -t 1 ]; then
      printf 'How would you like to handle uncommitted changes?\n' >&2
      printf '  [a] Abort  — stop and handle manually\n' >&2
      printf '  [c] Commit — coordinated commit now, then continue merge\n' >&2
      printf 'Choice [a/c]: ' >&2
      local md_reply; IFS= read -r md_reply
      case "$md_reply" in c|C) merge_dirty_choice="commit" ;; esac
    fi
    case "$merge_dirty_choice" in
      abort)
        die "Uncommitted changes found in: ${dirty_repos[*]}. Commit or stash them first."
        ;;
      commit)
        local _mb _ms _msubj
        _mb="$(mcrepo_new_batch_id)"
        _ms="$(mcrepo_next_seq "${dirty_repo_dirs[@]+"${dirty_repo_dirs[@]}"}")"
        _msubj="$(mcrepo_commit_subject "$_ms" "$_mb" "pre-merge stopping point")"
        log "Creating coordinated commit #$_ms @$_mb before merge."
        local _md
        for _md in "${dirty_repo_dirs[@]}"; do
          mcrepo_do_commit "$_md" "$_md" "$_msubj" || die "Coordinated pre-merge commit failed in $_md."
        done
        ;;
    esac
  fi

  if [ "${#preflight_errors[@]}" -gt 0 ]; then
    log "Pre-flight errors:"
    local err
    for err in "${preflight_errors[@]}"; do
      log "  - $err"
    done
    die "Fix the above issues and try again."
  fi

  if [ "${#skipped_names[@]}" -gt 0 ]; then
    log ""
    log "Skipping repos not on '$source_branch' (already merged or manually switched):"
    local sk
    for sk in "${skipped_names[@]}"; do
      log "  - $sk"
    done
  fi

  if [ "${#merge_indexes[@]}" -eq 0 ] && [ "$meta_included" -eq 0 ]; then
    if [ "${#wrong_branch_actuals[@]}" -gt 0 ]; then
      local common="${wrong_branch_actuals[0]}"
      local all_same_actual=1
      local wa
      for wa in "${wrong_branch_actuals[@]}"; do
        if [ "$wa" != "$common" ]; then all_same_actual=0; break; fi
      done
      if [ "$all_same_actual" -eq 1 ] && [ "$common" != "$source_branch" ]; then
        log ""
        log "Hint: all repos are on '$common' but mcrepo.yaml says 'branch: $source_branch'."
        log "  If '$common' is the branch you want to merge, run:"
        log "    mcrepo branch $common"
        log "  to re-align the coordinated branch state, then retry 'mcrepo merge'."
      fi
    fi
    die "No repos on branch '$source_branch' to merge."
  fi

  # Sync gate (strict two-step model): every participating branch must already
  # contain its parent tip, so the merge itself cannot conflict. Conflicts are
  # resolved on the feature branch via 'mcrepo rebase', never during the merge.
  local -a unsynced_names=()
  local sidx
  for sidx in "${!merge_indexes[@]}"; do
    _merge_repo_synced "${merge_dirs[$sidx]}" "${merge_parents[$sidx]}" || \
      unsynced_names+=("${REPO_NAMES[${merge_indexes[$sidx]}]}")
  done
  if [ "$meta_included" -eq 1 ]; then
    _merge_repo_synced "." "$meta_parent_branch" || unsynced_names+=("(meta-context)")
  fi
  if [ "${#unsynced_names[@]}" -gt 0 ]; then
    log ""
    log "Branch '$source_branch' is behind its parent in: ${unsynced_names[*]}"
    die "Run 'mcrepo rebase' first — it rebases the branch onto each parent so this merge cannot conflict. Resolve any conflicts there (then 'mcrepo continue'), and re-run 'mcrepo merge'."
  fi

  if ! git_supports_merge_tree_write_tree; then
    die "mcrepo merge needs git >= 2.38 for its conflict dry-run ('git merge-tree --write-tree'). Installed: $(git --version 2>/dev/null). Please upgrade git."
  fi

  # Phase 2: Dry-run merge verification
  log ""
  log "=== Dry-run merge verification ==="
  log ""

  log "Merge plan:"
  local idx
  for idx in "${!merge_indexes[@]}"; do
    printf '  %-20s %s -> %s\n' "${REPO_NAMES[${merge_indexes[$idx]}]}" "$source_branch" "${merge_parents[$idx]}"
  done
  if [ "$meta_included" -eq 1 ]; then
    printf '  %-20s %s -> %s\n' "(meta-context)" "$source_branch" "$meta_parent_branch"
  fi
  log ""

  local merge_ok=1
  local -a conflict_repos=()

  for idx in "${!merge_indexes[@]}"; do
    local ri="${merge_indexes[$idx]}"
    repo_name="${REPO_NAMES[$ri]}"
    repo_dir="${merge_dirs[$idx]}"
    local target="${merge_parents[$idx]}"

    log "Checking '$repo_name' ..."

    # Ensure target branch exists locally
    if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$target"; then
      if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$target"; then
        git -C "$repo_dir" branch --track "$target" "origin/$target" 2>/dev/null || true
      else
        merge_ok=0
        conflict_repos+=("$repo_name (target branch '$target' not found)")
        continue
      fi
    fi

    # Dry-run using git merge-tree --write-tree (git 2.38+, checked above)
    if git -C "$repo_dir" merge-tree --write-tree "$target" "$source_branch" >/dev/null 2>&1; then
      log "  OK"
    else
      merge_ok=0
      conflict_repos+=("$repo_name")
    fi
  done

  # Dry-run meta-context
  if [ "$meta_included" -eq 1 ]; then
    log "Checking '(meta-context)' ..."
    if ! git -C . show-ref --verify --quiet "refs/heads/$meta_parent_branch"; then
      if git -C . show-ref --verify --quiet "refs/remotes/origin/$meta_parent_branch"; then
        git -C . branch --track "$meta_parent_branch" "origin/$meta_parent_branch" 2>/dev/null || true
      fi
    fi
    if git -C . merge-tree --write-tree "$meta_parent_branch" "$source_branch" >/dev/null 2>&1; then
      log "  OK"
    else
      merge_ok=0
      conflict_repos+=("(meta-context)")
    fi
  fi

  log ""

  if [ "$merge_ok" -eq 0 ]; then
    log "Merge blocked. Conflicts detected in:"
    local cr
    for cr in "${conflict_repos[@]}"; do
      log "  - $cr"
    done
    die "Run 'mcrepo rebase' to rebase onto the parent branch and resolve conflicts first."
  fi

  log "All repos can merge cleanly."

  # Phase 3: Execute merges (meta-context last, as the final array element).
  # A failed repo is rolled back to the source branch and the loop keeps
  # going; each successful repo's parent stack is popped immediately, so a
  # partial merge is fully represented in the manifest and re-running
  # 'mcrepo merge' finishes the rest.
  local -a exec_names=()
  local -a exec_dirs=()
  local -a exec_parents=()
  local -a exec_repo_idx=()   # REPO_* index, or "meta"
  for idx in "${!merge_indexes[@]}"; do
    exec_names+=("${REPO_NAMES[${merge_indexes[$idx]}]}")
    exec_dirs+=("${merge_dirs[$idx]}")
    exec_parents+=("${merge_parents[$idx]}")
    exec_repo_idx+=("${merge_indexes[$idx]}")
  done
  if [ "$meta_included" -eq 1 ]; then
    exec_names+=("(meta-context)")
    exec_dirs+=(".")
    exec_parents+=("$meta_parent_branch")
    exec_repo_idx+=("meta")
  fi

  _MERGE_DONE_COUNT=0
  trap '_merge_exit_trap' EXIT

  log ""
  log "=== Executing merges ==="
  log ""

  local strategy_label
  if [ "$do_squash" -eq 1 ]; then
    strategy_label="squash"
  else
    strategy_label="merge commit (--no-ff)"
  fi
  log "Strategy: $strategy_label"
  log ""

  local -a merged_names=()
  local -a failed_names=()
  local -a failed_entries=()
  local exec_i rid current_parent
  for exec_i in "${!exec_names[@]}"; do
    repo_name="${exec_names[$exec_i]}"
    repo_dir="${exec_dirs[$exec_i]}"
    local target="${exec_parents[$exec_i]}"
    rid="${exec_repo_idx[$exec_i]}"

    if [ "$rid" = "meta" ] && [ "${#failed_names[@]}" -gt 0 ]; then
      warn "Skipping meta-context merge: ${#failed_names[@]} repo(s) failed — it merges on the next 'mcrepo merge' run."
      continue
    fi

    log "Merging in '$repo_name' ($source_branch -> $target) ..."
    if _merge_execute_one "$repo_dir" "$repo_name" "$target" "$source_branch" "$do_squash" "$commit_message"; then
      merged_names+=("$repo_name")
      _MERGE_DONE_COUNT=$((_MERGE_DONE_COUNT + 1))
      # Pop this repo's parent stack now: "main,feature" → "main", "main" → "".
      if [ "$rid" = "meta" ]; then
        if [[ "$META_PARENT" == *,* ]]; then
          META_PARENT="${META_PARENT%,*}"
        else
          META_PARENT=""
        fi
      else
        current_parent="${REPO_PARENTS[$rid]:-}"
        if [[ "$current_parent" == *,* ]]; then
          REPO_PARENTS[$rid]="${current_parent%,*}"
        else
          REPO_PARENTS[$rid]=""
        fi
      fi
    else
      failed_names+=("$repo_name")
      failed_entries+=("$repo_name|$repo_dir")
      warn "  $repo_name: merge failed — rolled back to '$source_branch'; continuing with the remaining repos."
    fi
  done

  if [ "${#failed_names[@]}" -gt 0 ]; then
    # Partial merge: the feature branch stays active; merged repos already had
    # their stacks popped, failed repos keep theirs and sit rolled-back on the
    # source branch. Re-running 'mcrepo merge' skips the merged repos.
    trap - EXIT
    save_repos
    log ""
    log "=== Merge summary (PARTIAL) ==="
    if [ "${#merged_names[@]}" -gt 0 ]; then
      log "Merged: ${merged_names[*]}"
    fi
    log "Failed: ${failed_names[*]}"
    warn "Fix the failed repos, then re-run 'mcrepo merge' — already-merged repos are skipped automatically."
    local merged_list="(none)"
    [ "${#merged_names[@]}" -gt 0 ] && merged_list="${merged_names[*]}"
    MCREPO_RECOVERY_CONTEXT="Failed repos were rolled back to '$source_branch'; their merges did not happen.
Already merged onto their parent branch: $merged_list.
After repairing the cause, re-run: ./mcrepo.sh merge"
    print_agent_recovery_prompt merge-conflict "${failed_entries[@]}"
    return 2
  fi

  # Phase 4: Determine new GLOBAL_BRANCH (stacks were popped per-repo above)
  local first_target="${exec_parents[0]:-}"
  local all_same=1
  for idx in "${!exec_parents[@]}"; do
    if [ "${exec_parents[$idx]}" != "$first_target" ]; then
      all_same=0
      break
    fi
  done

  if [ "$all_same" -eq 1 ] && [ -n "$first_target" ]; then
    GLOBAL_BRANCH="$first_target"
    log ""
    log "Global branch updated to '$GLOBAL_BRANCH'."
  else
    GLOBAL_BRANCH=""
    log ""
    log "Repos merged into different parent branches. Global branch coordination turned off."
  fi

  trap - EXIT
  save_repos

  # Phase 4.4: Commit the post-merge state in mcrepo.yaml so it lives in git
  # history and can be pushed alongside the merge — instead of sitting as an
  # orphan dirty change in the meta-context right after a successful merge.
  # Stages ONLY mcrepo.yaml so unrelated dirty files (if any) are left alone.
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
     [ -n "$(git -C . status --porcelain -- "$REPOS_FILE" 2>/dev/null)" ]; then
    log ""
    local yaml_subject
    if [ "$all_same" -eq 1 ] && [ -n "$first_target" ]; then
      yaml_subject="mcrepo: post-merge state — '$source_branch' merged into '$first_target'"
    else
      yaml_subject="mcrepo: post-merge state — '$source_branch' merged"
    fi
    log "Committing post-merge state to '$REPOS_FILE' in meta-context ..."
    if ! git -C . add -- "$REPOS_FILE"; then
      warn "  git add of '$REPOS_FILE' failed; commit it manually."
    elif ! git -C . commit -m "$yaml_subject"; then
      warn "  git commit of '$REPOS_FILE' failed; unstaging."
      git -C . reset HEAD -- "$REPOS_FILE" >/dev/null 2>&1 || true
    else
      log "  Done."
    fi
  fi

  # Phase 4.5: Offer to clean up the merged source branch locally.
  # Squash-merge breaks `git branch -d` reachability, so the squash path uses
  # force-delete with an explicit prompt; the --no-ff path keeps safe-delete.
  local do_delete=0
  if [ "$do_squash" -eq 1 ]; then
    if confirm "Branch '$source_branch' was squash-merged; safe-delete won't detect it — force-delete from all repos?" n; then
      do_delete=1
    fi
  else
    if [ -t 0 ] && [ -t 1 ]; then
      if confirm "Delete merged branch '$source_branch' from all repos?" y; then
        do_delete=1
      fi
    fi
  fi

  if [ "$do_delete" -eq 1 ]; then
    log ""
    log "Deleting '$source_branch' ..."
    for exec_i in "${!exec_names[@]}"; do
      repo_name="${exec_names[$exec_i]}"
      repo_dir="${exec_dirs[$exec_i]}"
      if [ "$do_squash" -eq 1 ]; then
        if git -C "$repo_dir" branch -D "$source_branch" 2>/dev/null; then
          log "  $repo_name: deleted (forced)."
        else
          warn "  $repo_name: could not delete '$source_branch'."
        fi
      else
        if git -C "$repo_dir" branch -d "$source_branch" 2>/dev/null; then
          log "  $repo_name: deleted."
        else
          warn "  $repo_name: could not safe-delete '$source_branch' (has unmerged commits). Run 'mcrepo branch --delete' to force."
        fi
      fi
    done
  fi

  log ""
  log "Merge complete. Changes are local only."
  log "Next: run 'mcrepo push' to publish the merged parent branches."
  if [ "$do_delete" -eq 0 ]; then
    log "Hint: run 'mcrepo branch --delete' to remove '$source_branch' when you're ready."
  fi
  if [ -n "$GLOBAL_BRANCH" ]; then
    local has_more_parents=0
    for i in "${!REPO_PARENTS[@]}"; do
      if [ -n "${REPO_PARENTS[$i]:-}" ]; then
        has_more_parents=1
        break
      fi
    done
    if [ -n "$META_PARENT" ]; then
      has_more_parents=1
    fi
    if [ "$has_more_parents" -eq 1 ]; then
      log "Hint: run 'mcrepo merge' again to merge into the next parent level."
    else
      log "Hint: run 'mcrepo branch --off' to turn off branch coordination."
    fi
  fi
}

# Markers wrapping the coordinated-PR cross-link block inside each PR body.
MCREPO_PR_BLOCK_BEGIN='<!-- mcrepo:coordinated-prs -->'
MCREPO_PR_BLOCK_END='<!-- /mcrepo:coordinated-prs -->'

# Print $existing_body with any previous coordinated-PR block stripped and the new
# $block appended. Idempotent across re-runs (drops the old marker block first).
# Args: $1 = existing body (possibly multi-line/empty), $2 = new block (multi-line).
pr_body_with_block() {
  local existing="$1" block="$2" stripped
  stripped="$(printf '%s' "$existing" | awk -v b="$MCREPO_PR_BLOCK_BEGIN" -v e="$MCREPO_PR_BLOCK_END" '
    index($0, b) { skip=1 }
    skip==0 { buf[n++]=$0 }
    index($0, e) { skip=0 }
    END {
      while (n>0 && buf[n-1] ~ /^[ \t]*$/) n--
      for (i=0;i<n;i++) print buf[i]
    }')"
  if [ -n "$stripped" ]; then
    printf '%s\n\n%s\n' "$stripped" "$block"
  else
    printf '%s\n' "$block"
  fi
}

# Create coordinated GitHub pull requests across write-mode repos (+ meta-context).
# One PR per repo that has commits vs its parent (base = parent, head = GLOBAL_BRANCH),
# then cross-link all PRs to each other inside their bodies (fallback: a comment).
cmd_pr() {
  local title=""
  local do_draft=0
  local do_push=1
  local include_read=0
  local opt_target=""   # "", "origin", or "upstream" (global override)

  while [ "$#" -gt 0 ]; do
    case "$1" in
      -m|--title) shift; title="${1:-}"; [ -n "$title" ] || die "-m/--title requires a value" ;;
      --draft) do_draft=1 ;;
      --no-push) do_push=0 ;;
      --include-read) include_read=1 ;;
      --target) shift; opt_target="${1:-}"; case "$opt_target" in origin|upstream) ;; *) die "--target must be origin|upstream" ;; esac ;;
      *) die "Unknown pr option: $1" ;;
    esac
    shift
  done

  load_repos

  if [ -z "$GLOBAL_BRANCH" ]; then
    die "No feature branch active — start one with 'mcrepo branch <name>' first, then create coordinated PRs with 'mcrepo pr'."
  fi
  local source_branch="$GLOBAL_BRANCH"
  [ -n "$title" ] || title="$source_branch"

  # --- Phase 0: prerequisites (PRs always need gh) ---
  gh_ready || die "Pull requests need the GitHub CLI. Install gh and run 'gh auth login' (see 'mcrepo doctor')."

  # --- Phase 1: collect candidates (repos with commits vs their base branch) ---
  # Per candidate we record the PR TARGET: same-repo (origin) or cross-repo (fork
  # -> upstream). Parallel arrays carry the gh repo slug (-R) and head ref.
  local i mode repo_dir repo_name base actual cmp_target cnt
  local -a cand_dirs=() cand_names=() cand_bases=() cand_counts=()
  local -a cand_slugs=() cand_heads=() cand_kinds=()
  local -a skipped_empty=() skipped_other=() dirty_repos=()

  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    if [ "$mode" != "write" ]; then
      { [ "$include_read" -eq 1 ] && [ "$mode" = "read" ]; } || continue
    fi
    repo_name="${REPO_NAMES[$i]}"
    repo_dir="$(get_repo_dir "$repo_name" "$mode")"
    [ -d "$repo_dir/.git" ] || continue

    local origin_url upstream_url target
    origin_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
    upstream_url="${REPO_UPSTREAMS[$i]:-}"

    # Decide PR target for this repo.
    target="origin"
    if [ -n "$upstream_url" ] && [ "$opt_target" != "origin" ]; then
      target="upstream"
    fi
    if [ "$opt_target" = "upstream" ] && [ -z "$upstream_url" ]; then
      warn "Skipping '$repo_name': --target upstream but no upstream configured (set with 'mcrepo upstream $repo_name <url>')."
      skipped_other+=("$repo_name")
      continue
    fi

    # Repo must be on the coordinated branch.
    actual="$(repo_branch "$repo_dir")"
    if [ "$actual" != "$source_branch" ]; then
      warn "Skipping '$repo_name': on '$actual', expected '$source_branch' (realign with 'mcrepo branch $actual')."
      skipped_other+=("$repo_name")
      continue
    fi

    local slug="" head="" cmp_remote=""
    if [ "$target" = "upstream" ]; then
      # Cross-repo PR: head = <forkOwner>:<branch> on origin; base repo = upstream.
      if ! url_is_github "$upstream_url"; then
        warn "Skipping '$repo_name': upstream is not a github.com URL."
        skipped_other+=("$repo_name"); continue
      fi
      parse_git_url "$upstream_url" >/dev/null
      slug="$GU_OWNER/$GU_REPO"
      if [ -z "$origin_url" ] || ! url_is_github "$origin_url"; then
        warn "Skipping '$repo_name': need a GitHub origin (your fork) to open a PR to upstream. Try 'mcrepo fork $repo_name'."
        skipped_other+=("$repo_name"); continue
      fi
      parse_git_url "$origin_url" >/dev/null
      head="$GU_OWNER:$source_branch"
      # Make sure the upstream remote + its refs are available for base detection.
      ensure_upstream_remote "$repo_dir" "$upstream_url"
      git -C "$repo_dir" fetch upstream --quiet 2>/dev/null || true
      base="${REPO_PARENTS[$i]##*,}"
      if [ -z "$base" ] || ! git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/upstream/$base"; then
        base="$(detect_default_branch_remote "$repo_dir" upstream)"
      fi
      cmp_remote="upstream"
    else
      # Same-repo PR (your own repo): base = parent / default branch.
      if [ -z "$origin_url" ] || ! url_is_github "$origin_url"; then
        warn "Skipping '$repo_name': origin is not a GitHub remote."
        skipped_other+=("$repo_name"); continue
      fi
      base="${REPO_PARENTS[$i]##*,}"
      [ -n "$base" ] || base="$(detect_default_branch "$repo_dir")"
      head="$source_branch"
      cmp_remote="origin"
    fi

    if [ -z "$base" ]; then
      warn "Skipping '$repo_name': cannot determine base branch on $cmp_remote."
      skipped_other+=("$repo_name"); continue
    fi
    if [ "$base" = "$source_branch" ]; then
      warn "Skipping '$repo_name': base equals current branch '$source_branch'."
      skipped_other+=("$repo_name"); continue
    fi

    # Has commits vs base? Prefer <cmp_remote>/<base>, fall back to local.
    cmp_target=""
    if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/$cmp_remote/$base"; then
      cmp_target="$cmp_remote/$base"
    elif git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$base"; then
      cmp_target="$base"
    fi
    if [ -z "$cmp_target" ]; then
      warn "Skipping '$repo_name': base branch '$base' not found on $cmp_remote or locally."
      skipped_other+=("$repo_name"); continue
    fi
    cnt="$(git -C "$repo_dir" rev-list --count "$cmp_target..HEAD" 2>/dev/null || printf -- '-1')"
    if [ "$cnt" -le 0 ]; then
      skipped_empty+=("$repo_name")
      continue
    fi

    [ "$(repo_dirty_state "$repo_dir")" = "dirty" ] && dirty_repos+=("$repo_name")

    cand_dirs+=("$repo_dir"); cand_names+=("$repo_name"); cand_bases+=("$base"); cand_counts+=("$cnt")
    cand_slugs+=("$slug"); cand_heads+=("$head"); cand_kinds+=("$target")
  done

  # Meta-context repo: same-repo by default, or fork->upstream when META_UPSTREAM set.
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local meta_base meta_actual meta_origin meta_cmp meta_cnt
    local meta_target="origin" meta_slug="" meta_head="$source_branch" meta_cmp_remote="origin"
    meta_actual="$(repo_branch ".")"
    meta_origin="$(git -C . remote get-url origin 2>/dev/null || true)"

    if [ -n "$META_UPSTREAM" ] && [ "$opt_target" != "origin" ]; then
      meta_target="upstream"
    fi

    if [ "$meta_actual" = "$source_branch" ] && [ -n "$meta_origin" ] && url_is_github "$meta_origin"; then
      if [ "$meta_target" = "upstream" ] && url_is_github "$META_UPSTREAM"; then
        parse_git_url "$META_UPSTREAM" >/dev/null; meta_slug="$GU_OWNER/$GU_REPO"
        parse_git_url "$meta_origin" >/dev/null; meta_head="$GU_OWNER:$source_branch"
        ensure_upstream_remote "." "$META_UPSTREAM"
        git -C . fetch upstream --quiet 2>/dev/null || true
        meta_base="${META_PARENT##*,}"
        if [ -z "$meta_base" ] || ! git -C . show-ref --verify --quiet "refs/remotes/upstream/$meta_base"; then
          meta_base="$(detect_default_branch_remote "." upstream)"
        fi
        meta_cmp_remote="upstream"
      else
        meta_base="${META_PARENT##*,}"
        [ -n "$meta_base" ] || meta_base="$(detect_default_branch ".")"
      fi

      if [ -n "$meta_base" ] && [ "$meta_base" != "$source_branch" ]; then
        meta_cmp=""
        if git -C . show-ref --verify --quiet "refs/remotes/$meta_cmp_remote/$meta_base"; then
          meta_cmp="$meta_cmp_remote/$meta_base"
        elif git -C . show-ref --verify --quiet "refs/heads/$meta_base"; then
          meta_cmp="$meta_base"
        fi
        if [ -n "$meta_cmp" ]; then
          meta_cnt="$(git -C . rev-list --count "$meta_cmp..HEAD" 2>/dev/null || printf -- '-1')"
          if [ "$meta_cnt" -gt 0 ]; then
            [ "$(repo_dirty_state ".")" = "dirty" ] && dirty_repos+=("(meta-context)")
            cand_dirs+=("."); cand_names+=("(meta-context)"); cand_bases+=("$meta_base"); cand_counts+=("$meta_cnt")
            cand_slugs+=("$meta_slug"); cand_heads+=("$meta_head"); cand_kinds+=("$meta_target")
          else
            skipped_empty+=("(meta-context)")
          fi
        fi
      fi
    fi
  fi

  if [ "${#cand_dirs[@]}" -eq 0 ]; then
    log "No repos with commits against their base — nothing to open a PR for."
    [ "${#skipped_empty[@]}" -gt 0 ] && log "  Skipped (no commits vs base): ${skipped_empty[*]}"
    return 0
  fi

  # --- Phase 2: plan + confirm ---
  log "=== PR plan (branch '$source_branch') ==="
  local idx
  for idx in "${!cand_dirs[@]}"; do
    local tgt_label
    if [ "${cand_kinds[$idx]}" = "upstream" ]; then
      tgt_label="upstream ${cand_slugs[$idx]}"
    else
      tgt_label="origin"
    fi
    printf '  %-20s %s -> %s (%s)  [%s commit(s)]\n' \
      "${cand_names[$idx]}" "$source_branch" "${cand_bases[$idx]}" "$tgt_label" "${cand_counts[$idx]}"
  done
  [ "${#skipped_empty[@]}" -gt 0 ] && log "  Skipped (no commits vs base): ${skipped_empty[*]}"
  if [ "${#dirty_repos[@]}" -gt 0 ]; then
    warn "Uncommitted changes in: ${dirty_repos[*]} — these will NOT be included in the PR(s)."
  fi
  log ""
  if ! confirm "Create ${#cand_dirs[@]} coordinated PR(s)?" y; then
    log "Aborted."
    return 0
  fi

  # --- Phase 3: auto-push feature branch to origin (your fork), unless --no-push ---
  local -a pr_dirs=() pr_names=() pr_bases=() pr_slugs=() pr_heads=() pr_urls=()
  local -a failed=()
  for idx in "${!cand_dirs[@]}"; do
    repo_dir="${cand_dirs[$idx]}"; repo_name="${cand_names[$idx]}"
    if [ "$do_push" -eq 1 ]; then
      log "--- Pushing '$repo_name' ($source_branch -> origin) ---"
      if ! git -C "$repo_dir" push -u origin "$source_branch"; then
        warn "Push failed for '$repo_name' — skipping PR."
        failed+=("$repo_name")
        continue
      fi
    fi
    pr_dirs+=("$repo_dir"); pr_names+=("$repo_name"); pr_bases+=("${cand_bases[$idx]}")
    pr_slugs+=("${cand_slugs[$idx]}"); pr_heads+=("${cand_heads[$idx]}")
  done

  if [ "${#pr_dirs[@]}" -eq 0 ]; then
    warn "No PRs created."
    [ "${#failed[@]}" -gt 0 ] && warn "  Failed: ${failed[*]}"
    return 1
  fi

  # --- Phase 4: create or reuse PRs ---
  local -a created=() reused=()
  for idx in "${!pr_dirs[@]}"; do
    repo_dir="${pr_dirs[$idx]}"; repo_name="${pr_names[$idx]}"
    base="${pr_bases[$idx]}"; local slug="${pr_slugs[$idx]}" head="${pr_heads[$idx]}"
    # -R <slug> for cross-repo (upstream) PRs; empty for same-repo. ${arr[@]+...}
    # is the bash 3.2 + `set -u` safe expansion of a possibly-empty array.
    local rflag=()
    [ -n "$slug" ] && rflag=(-R "$slug")
    local url=""
    url="$(cd "$repo_dir" && gh pr list ${rflag[@]+"${rflag[@]}"} --head "$head" --base "$base" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
    if [ -n "$url" ]; then
      log "Reusing existing PR for '$repo_name': $url"
      reused+=("$repo_name")
    else
      local base_body
      base_body="Coordinated mcrepo change on branch \`$source_branch\` (repo: $repo_name)."
      local draft_flag=()
      [ "$do_draft" -eq 1 ] && draft_flag=(--draft)
      url="$(cd "$repo_dir" && gh pr create ${rflag[@]+"${rflag[@]}"} --base "$base" --head "$head" \
              --title "$title" --body "$base_body" ${draft_flag[@]+"${draft_flag[@]}"} 2>/dev/null || true)"
      if [ -z "$url" ]; then
        warn "Failed to create PR for '$repo_name'."
        failed+=("$repo_name")
        continue
      fi
      log "Created PR for '$repo_name': $url"
      created+=("$repo_name")
    fi
    pr_urls+=("$url")
  done

  # Rebuild parallel arrays for repos that actually got a URL (filter failures).
  local -a link_names=() link_urls=()
  local u_i=0
  for idx in "${!pr_dirs[@]}"; do
    repo_name="${pr_names[$idx]}"
    case " ${failed[*]-} " in *" $repo_name "*) continue ;; esac
    link_names+=("$repo_name"); link_urls+=("${pr_urls[$u_i]}")
    u_i=$((u_i+1))
  done

  # --- Phase 5: cross-link all PRs (addressed by URL — works across repos) ---
  local -a linked=() commented=()
  if [ "${#link_urls[@]}" -gt 0 ]; then
    local block
    block="$MCREPO_PR_BLOCK_BEGIN
### Coordinated PRs (branch \`$source_branch\`)
"
    local li
    for li in "${!link_names[@]}"; do
      block="$block- ${link_names[$li]}: ${link_urls[$li]}
"
    done
    block="$block$MCREPO_PR_BLOCK_END"

    for li in "${!link_urls[@]}"; do
      local url="${link_urls[$li]}"; repo_name="${link_names[$li]}"
      local cur_body new_body
      cur_body="$(gh pr view "$url" --json body --jq '.body' 2>/dev/null || true)"
      new_body="$(pr_body_with_block "$cur_body" "$block")"
      if gh pr edit "$url" --body "$new_body" >/dev/null 2>&1; then
        linked+=("$repo_name")
      elif gh pr comment "$url" --body "$block" >/dev/null 2>&1; then
        commented+=("$repo_name")
      else
        warn "Could not add cross-link to '$repo_name' (neither edit nor comment worked)."
        failed+=("$repo_name")
      fi
    done
  fi

  # --- Phase 6: summary ---
  log ""
  log "=== PR summary ==="
  [ "${#created[@]}"  -gt 0 ] && log "  Created:     ${created[*]}"
  [ "${#reused[@]}"   -gt 0 ] && log "  Reused:      ${reused[*]}"
  [ "${#linked[@]}"   -gt 0 ] && log "  Cross-linked (body):    ${linked[*]}"
  [ "${#commented[@]}" -gt 0 ] && log "  Cross-linked (comment): ${commented[*]}"
  [ "${#skipped_empty[@]}" -gt 0 ] && log "  Skipped (no commits vs base): ${skipped_empty[*]}"
  [ "${#skipped_other[@]}" -gt 0 ] && log "  Skipped (other):        ${skipped_other[*]}"
  if [ "${#failed[@]}" -gt 0 ]; then
    warn "  Failed:      ${failed[*]}"
    # Exit-code contract: 0 = success, 2 = partial per-repo failure.
    return 2
  fi
  if [ "${#created[@]}" -gt 0 ] || [ "${#reused[@]}" -gt 0 ]; then
    log ""
    log "Next: after the PRs are reviewed and merged upstream, run 'mcrepo pull' to update the parent branches."
  fi
}

# Sync: rebase the current global branch onto each parent branch so the later
# merge back into the parent is conflict-free. Per repo: fetch → stash dirty
# work (incl. untracked) → rebase onto parent (prefers 'origin/<parent>') →
# pop stash. Processes ALL repos even if some conflict (full summary at end);
# on rebase conflict the stash is left untouched, on stash-pop conflict the
# stash stays in the stack (drop it after resolving).
# Implementation behind 'mcrepo rebase' ('merge --rebase' is a deprecated alias).
# The meta-context participates as the last element of the target arrays.
# Sets REBASE_CONFLICTS to the number of repos left conflicted and returns 2
# when any conflict remains, 0 otherwise.
_rebase_run() {
  local source_branch="$1"
  local include_read="${2:-0}"
  REBASE_CONFLICTS=0

  log ""
  log "=== Rebase: bringing the branch up to date with its parent ==="
  log ""

  # Phase 1: Pre-flight
  local i mode repo_dir repo_name
  local -a rebase_names=()
  local -a rebase_dirs=()
  local -a rebase_parents=()
  local -a preflight_errors=()
  local -a read_repos_skipped=()

  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    repo_name="${REPO_NAMES[$i]}"
    case "$mode" in
      write) ;;
      read)
        if [ "$include_read" -ne 1 ]; then
          repo_dir="$(get_repo_dir "$repo_name" "$mode")"
          if [ -d "$repo_dir/.git" ] && [ "$(repo_branch "$repo_dir")" = "$source_branch" ]; then
            read_repos_skipped+=("$repo_name")
          fi
          continue
        fi
        ;;
      *) continue ;;
    esac
    repo_dir="$(get_repo_dir "$repo_name" "$mode")"
    [ -d "$repo_dir/.git" ] || continue

    local parent_branch=""
    if [ -n "${REPO_PARENTS[$i]:-}" ]; then
      parent_branch="${REPO_PARENTS[$i]##*,}"
    fi
    if [ -z "$parent_branch" ]; then
      parent_branch="$(detect_default_branch "$repo_dir")"
    fi
    if [ -z "$parent_branch" ]; then
      preflight_errors+=("'$repo_name': no parent branch recorded and cannot detect default branch.")
      continue
    fi

    local actual_branch
    actual_branch="$(repo_branch "$repo_dir")"
    if [ "$actual_branch" != "$source_branch" ]; then
      preflight_errors+=("'$repo_name' is on branch '$actual_branch', expected '$source_branch'.")
    fi

    if [ "$source_branch" = "$parent_branch" ]; then
      continue  # nothing to rebase from
    fi

    if ! git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$parent_branch" && \
       ! git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$parent_branch"; then
      preflight_errors+=("'$repo_name': parent branch '$parent_branch' not found locally or on origin.")
      continue
    fi

    rebase_names+=("$repo_name")
    rebase_dirs+=("$repo_dir")
    rebase_parents+=("$parent_branch")
  done

  # Meta-context pre-flight: joins the same target arrays as the Nth repo.
  local meta_parent_branch=""
  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$META_PARENT" ]; then
      meta_parent_branch="${META_PARENT##*,}"
    fi
    if [ -z "$meta_parent_branch" ]; then
      meta_parent_branch="$(detect_default_branch ".")"
    fi
    if [ -n "$meta_parent_branch" ] && [ "$meta_parent_branch" != "$source_branch" ]; then
      local meta_actual
      meta_actual="$(repo_branch ".")"
      if [ "$meta_actual" != "$source_branch" ]; then
        preflight_errors+=("meta-context repo is on branch '$meta_actual', expected '$source_branch'.")
      else
        rebase_names+=("(meta-context)")
        rebase_dirs+=(".")
        rebase_parents+=("$meta_parent_branch")
      fi
    fi
  fi

  if [ "${#preflight_errors[@]}" -gt 0 ]; then
    log "Pre-flight errors:"
    local err
    for err in "${preflight_errors[@]}"; do
      log "  - $err"
    done
    die "Fix the above issues and try again."
  fi

  if [ "${#read_repos_skipped[@]}" -gt 0 ]; then
    warn "Read-mode repos on '$source_branch' will NOT be synced: ${read_repos_skipped[*]} — re-run with --include-read to include them."
  fi

  if [ "${#rebase_names[@]}" -eq 0 ]; then
    log "All repos are already in sync with their parent branches."
    return 0
  fi

  # Phase 2: Fetch + stash + rebase + pop per repo (meta-context included)
  local -a clean_repos=()
  local -a merge_conflict_repos=()
  local -a stash_conflict_repos=()
  local -a merge_conflict_entries=()   # name|dir
  local -a stash_conflict_entries=()   # name|dir
  local -a clean_entries=()            # name|dir (for post-rebase publish detection)

  local idx
  for idx in "${!rebase_names[@]}"; do
    repo_name="${rebase_names[$idx]}"
    repo_dir="${rebase_dirs[$idx]}"
    local parent="${rebase_parents[$idx]}"

    # Fetch first so origin/<parent> reflects the latest state
    local has_origin=0
    if git -C "$repo_dir" remote get-url origin >/dev/null 2>&1; then
      git -C "$repo_dir" fetch origin --prune 2>/dev/null || true
      has_origin=1
    fi

    # Prefer origin/<parent> as the rebase target (freshest), else local <parent>
    local rebase_target="$parent"
    if [ "$has_origin" -eq 1 ] && git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$parent"; then
      rebase_target="origin/$parent"
    fi

    log "Rebasing '$repo_name' ($source_branch onto $rebase_target) ..."

    # Stash if dirty (only counts when a stash entry was actually created —
    # otherwise a later pop would grab an unrelated pre-existing stash)
    local did_stash=0
    local dirty
    dirty="$(git -C "$repo_dir" status --porcelain 2>/dev/null)"
    if [ -n "$dirty" ] && _mcrepo_stash_push "$repo_dir" "mcrepo: auto-stash before rebase"; then
      did_stash=1
    fi

    # Rebase current branch onto target
    if ! git -C "$repo_dir" rebase "$rebase_target"; then
      merge_conflict_repos+=("$repo_name")
      merge_conflict_entries+=("$repo_name|$repo_dir")
      # Per-repo conflict context: the three sides that collided.
      warn "  Rebase conflicts in '$repo_name'. The conflict is between three sides:"
      warn "    - local feature branch : $source_branch (your work)"
      warn "    - parent target        : $rebase_target (latest main being rebased onto)"
      if git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$source_branch"; then
        warn "    - stale remote branch  : origin/$source_branch (pre-rebase history, still on the server)"
      fi
      warn "    Conflicts may mix real feature work with mcrepo coordination commits (#N) — keep the intended final state."
      if [ "$did_stash" -eq 1 ]; then
        warn "  Resolve, run 'mcrepo continue' (or 'git -C $repo_dir rebase --continue'), then 'git -C $repo_dir stash pop' to restore your changes."
      else
        warn "  Resolve, then run 'mcrepo continue' (or 'git -C $repo_dir rebase --continue')."
      fi
      continue
    fi

    # Pop stash
    if [ "$did_stash" -eq 1 ]; then
      if ! git -C "$repo_dir" stash pop; then
        stash_conflict_repos+=("$repo_name")
        stash_conflict_entries+=("$repo_name|$repo_dir")
        warn "  Stash pop conflicts. Resolve, then run 'git -C $repo_dir stash drop'."
        continue
      fi
    fi

    clean_repos+=("$repo_name")
    clean_entries+=("$repo_name|$repo_dir")
    log "  Done."
  done

  # Phase 3: Summary
  log ""
  log "=== Rebase summary ==="
  if [ "${#clean_repos[@]}" -gt 0 ]; then
    log "Synced cleanly: ${clean_repos[*]}"
  fi
  if [ "${#merge_conflict_repos[@]}" -gt 0 ]; then
    log "Rebase conflicts (resolve, run 'mcrepo continue', then 'git stash pop' if stashed): ${merge_conflict_repos[*]}"
  fi
  if [ "${#stash_conflict_repos[@]}" -gt 0 ]; then
    log "Stash conflicts (resolve, then 'git stash drop'): ${stash_conflict_repos[*]}"
  fi

  # Conflict recovery: offer a paste-ready prompt for a local coding agent.
  if [ "${#merge_conflict_entries[@]}" -gt 0 ]; then
    print_agent_recovery_prompt rebase-conflict "${merge_conflict_entries[@]}"
  fi
  if [ "${#stash_conflict_entries[@]}" -gt 0 ]; then
    print_agent_recovery_prompt stash-conflict "${stash_conflict_entries[@]}"
  fi

  REBASE_CONFLICTS=$(( ${#merge_conflict_repos[@]} + ${#stash_conflict_repos[@]} ))
  if [ "$REBASE_CONFLICTS" -gt 0 ]; then
    warn "Next: resolve the conflicts (prompt above), 'git add' the files, run 'mcrepo continue', then re-run 'mcrepo rebase'."
    return 2
  fi

  log ""
  log "All repos synced."
  log "Next: run 'mcrepo merge' to fold the branch back into the parent branches."
  # The rebase rewrote commit hashes. Any cleanly-rebased branch that was already
  # pushed now diverges from its origin/<branch> and must be re-published.
  local -a republish_names=()
  local ce ce_name ce_dir
  for ce in "${clean_entries[@]}"; do
    ce_name="${ce%%|*}"
    ce_dir="${ce#*|}"
    if git -C "$ce_dir" show-ref --verify --quiet "refs/remotes/origin/$source_branch"; then
      republish_names+=("$ce_name")
    fi
  done
  if [ "${#republish_names[@]}" -gt 0 ]; then
    log ""
    log "Local history was rewritten by the rebase, so these branches now differ from their remote"
    log "(this is expected — not remote work from another machine). Run 'mcrepo push' to publish them;"
    log "mcrepo will safely force-with-lease the rebased branches:"
    local rpn
    for rpn in "${republish_names[@]}"; do
      log "  - $rpn"
    done
  fi
  return 0
}

cmd_rebase() {
  local include_read=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --include-read) include_read=1 ;;
      *) die "Unknown rebase option: $1" ;;
    esac
    shift
  done
  load_repos
  _require_no_stuck_repos "rebase"
  if [ -z "$GLOBAL_BRANCH" ]; then
    die "No feature branch active — start one with 'mcrepo branch <name>' first."
  fi
  _rebase_run "$GLOBAL_BRANCH" "$include_read"
}

# Runs once after 'mcrepo update' replaced the script ($1 = old version,
# $2 = new version). Migrates the manifest to the current schema by doing a
# load/save round-trip: normalize_mode and save_repos bring legacy fields and
# the schema stamp up to date. Safe to run in a non-workspace directory.
cmd_post_update_migrate() {
  [ "$#" -eq 2 ] || return 0
  [ -f "$REPOS_FILE" ] || return 0
  local schema_before
  schema_before="$(parse_schema_version || true)"
  load_repos
  save_repos
  if [ "${schema_before:-0}" != "$MCREPO_SCHEMA_VERSION" ]; then
    log "Migrated $REPOS_FILE to manifest schema $MCREPO_SCHEMA_VERSION."
  fi

  # 0.7.0: backfill the conflict-resolution skill into existing workspaces
  # (ensure_skills_files only seeds the pack when NO skills exist). Runs once:
  # if the user deletes the skill afterwards, this re-creates it only on the
  # next 'mcrepo update' — disable with 'mcrepo skill disable conflict-resolution'.
  if [ -d "$SUPPORT_SKILLS_DIR" ] && [ ! -d "$SUPPORT_SKILLS_DIR/conflict-resolution" ]; then
    create_conflict_resolution_skill
    if [ -f "$SKILLS_CONFIG_FILE" ] && grep -q '^enabled:' "$SKILLS_CONFIG_FILE" && \
       ! grep -q '^[[:space:]]*-[[:space:]]*conflict-resolution$' "$SKILLS_CONFIG_FILE"; then
      local _skb
      _skb="$(mktemp "$SKILLS_CONFIG_FILE.XXXXXX")"
      awk '{ print } /^enabled:$/ { print "  - conflict-resolution" }' "$SKILLS_CONFIG_FILE" >"$_skb" && \
        mv -f "$_skb" "$SKILLS_CONFIG_FILE" || rm -f "$_skb"
    fi
    sync_workspace_skills_to_opencode 2>/dev/null || true
    log "Added the 'conflict-resolution' skill to $SUPPORT_SKILLS_DIR/."
  fi
  return 0
}

cmd_update() {
  [ "$#" -eq 0 ] || die "Usage: ./mcrepo.sh update"

  local remote_tmp_file remote_version current_version
  local script_path

  current_version="$MCREPO_VERSION"
  remote_tmp_file="$(mktemp)"

  # Force a cache-bypass fetch so we always get the latest file, not a CDN-cached copy
  remote_version="$(MCREPO_FETCH_NO_CACHE=1 check_remote_version "$remote_tmp_file" || true)"
  if [ -z "$remote_version" ]; then
    rm -f "$remote_tmp_file"
    die "Could not check for updates from: $(update_source_url)"
  fi

  if ! version_greater_than "$remote_version" "$current_version"; then
    rm -f "$remote_tmp_file"
    log "Already up to date (version $current_version)."
    return 0
  fi

  script_path="$(resolve_script_path)"
  if [ ! -w "$script_path" ]; then
    rm -f "$remote_tmp_file"
    die "Cannot update '$script_path' (no write permission)."
  fi

  # Validate the download parses before installing it — a truncated or
  # corrupted file that still carries a version line must never be installed.
  if ! bash -n "$remote_tmp_file" 2>/dev/null; then
    rm -f "$remote_tmp_file"
    die "Downloaded update failed syntax validation (bash -n) — not installing. Try 'mcrepo update' again."
  fi

  # Stage next to the target and rename: mktemp lives in TMPDIR, and a
  # cross-filesystem 'mv' degrades to copy+truncate, rewriting the RUNNING
  # script's inode in place. Same-directory rename is atomic.
  local staged_file
  staged_file="$(mktemp "$script_path.update.XXXXXX")" || { rm -f "$remote_tmp_file"; die "Could not create staging file next to '$script_path'."; }
  cp "$remote_tmp_file" "$staged_file" || { rm -f "$remote_tmp_file" "$staged_file"; die "Could not stage update next to '$script_path'."; }
  rm -f "$remote_tmp_file"

  # Preserve the installed script's permissions (mktemp creates 0600).
  # stat -f is BSD/macOS, stat -c is GNU.
  local orig_mode
  orig_mode="$(stat -f '%Lp' "$script_path" 2>/dev/null || stat -c '%a' "$script_path" 2>/dev/null || printf '755')"
  chmod "$orig_mode" "$staged_file" 2>/dev/null || chmod 755 "$staged_file"
  chmod +x "$staged_file"

  mv -f "$staged_file" "$script_path"
  log "Updated mcrepo from version $current_version to $remote_version."

  if MCREPO_SUPPRESS_VERSION_BANNER=1 MCREPO_DISABLE_UPDATE_CHECK=1 "$script_path" --post-update-migrate "$current_version" "$remote_version"; then
    log "Update complete. Run mcrepo again to use the new version."
  else
    warn "Updated script, but post-update migration hook reported an issue."
    warn "Run mcrepo again and inspect your workspace state before continuing."
  fi

  # Also update the VS Code extension if the code CLI is available.
  # The script itself is already updated at this point — a failed extension
  # download must not make the whole update exit non-zero under set -e.
  install_vscode_extension 0 || warn "VS Code extension update skipped (download failed). Retry later with: mcrepo install-extension"
}

cmd_export_patch() {
  local topic=""
  local strategy="intent"
  local script_path remote_tmp_file patch_tmp_file base_tmp_file merged_tmp_file
  local remote_version issues_url timestamp patch_source
  local issue_title default_topic entered_topic
  local base_version
  local patch_strategy_note=""
  local merge_conflict_note=""
  local arg
  local prompt_for_title=0

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --strategy=*)
        strategy="${arg#*=}"
        ;;
      --strategy)
        shift || true
        [ "$#" -gt 0 ] || die "Missing value for --strategy (use: intent or legacy)."
        strategy="$1"
        ;;
      --)
        shift || true
        topic="${*:-}"
        break
        ;;
      -*)
        die "Unknown option for export-patch: $arg"
        ;;
      *)
        if [ -n "$topic" ]; then
          topic="$topic $arg"
        else
          topic="$arg"
        fi
        ;;
    esac
    shift || true
  done

  case "$strategy" in
    intent|legacy) ;;
    *) die "Unsupported patch strategy: $strategy (expected: intent or legacy)." ;;
  esac

  script_path="$(resolve_script_path)"
  [ -f "$script_path" ] || die "Local script not found: $script_path"

  remote_tmp_file="$(mktemp)"
  patch_tmp_file="$(mktemp)"
  base_tmp_file="$(mktemp)"
  merged_tmp_file="$(mktemp)"
  patch_source="$script_path"

  if ! fetch_remote_script_to_file "$remote_tmp_file"; then
    rm -f "$remote_tmp_file" "$patch_tmp_file" "$base_tmp_file" "$merged_tmp_file"
    die "Could not fetch upstream script from: $(update_source_url)"
  fi

  remote_version="$(extract_version_from_file "$remote_tmp_file" || true)"
  if ! is_valid_version "$remote_version"; then
    rm -f "$remote_tmp_file" "$patch_tmp_file" "$base_tmp_file" "$merged_tmp_file"
    die "Could not parse upstream MCREPO_VERSION from downloaded script."
  fi

  if [ "$strategy" = "intent" ]; then
    base_version="$MCREPO_VERSION"
    if ! command -v git >/dev/null 2>&1; then
      strategy="legacy"
      patch_strategy_note="Intent strategy requested but git is not available; fallback to legacy patch comparison."
    elif ! is_valid_version "$base_version"; then
      strategy="legacy"
      patch_strategy_note="Intent strategy requested but local MCREPO_VERSION is not valid; fallback to legacy patch comparison."
    else
      if ! fetch_remote_script_version_to_file "$base_version" "$base_tmp_file"; then
        strategy="legacy"
        patch_strategy_note="Intent strategy requested but could not fetch upstream base for version $base_version; fallback to legacy patch comparison."
      fi

      if [ "$strategy" = "intent" ] && [ "$base_version" = "$remote_version" ]; then
        cp "$remote_tmp_file" "$base_tmp_file"
      fi

      if [ "$strategy" = "intent" ]; then
        if git merge-file -p "$remote_tmp_file" "$base_tmp_file" "$script_path" >"$merged_tmp_file"; then
          patch_source="$merged_tmp_file"
        else
          strategy="legacy"
          patch_strategy_note="Intent strategy detected overlapping edits against upstream and could not auto-merge intent cleanly; fallback to legacy patch comparison."
          merge_conflict_note="Patch may include revert-looking hunks because automatic intent extraction conflicted."
        fi
      fi
    fi
  fi

  if diff -u --label a/mcrepo.sh --label b/mcrepo.sh "$remote_tmp_file" "$patch_source" >"$patch_tmp_file"; then
    rm -f "$remote_tmp_file" "$patch_tmp_file" "$base_tmp_file" "$merged_tmp_file"
    log "No local changes in mcrepo.sh compared to canonical upstream."
    return 0
  fi

  timestamp="$(date +%Y%m%d-%H%M%S)"

  if [ -z "$topic" ]; then
    default_topic="Feature update $timestamp"
    topic="$default_topic"
    if [ -t 0 ] && [ -t 1 ]; then
      prompt_for_title=1
      printf 'No patch title provided.\n' >&2
      printf 'Summarize the feature in 2-5 words (press Enter for `%s`): ' "$default_topic" >&2
      IFS= read -r entered_topic
      if [ -n "$entered_topic" ]; then
        topic="$entered_topic"
      fi
    fi
  fi

  issue_title="[PATCH SUBMISSION] $topic"
  issues_url="https://github.com/$MCREPO_UPDATE_REPO/issues/new"

  printf '# Patch Submission Instructions\n\n'
  printf '1. If you do not have a GitHub account, create one first: https://github.com/signup\n'
  printf '2. Open this URL: %s\n' "$issues_url"
  printf '3. Set issue title to: `%s`\n' "$issue_title"
  printf '4. Paste the issue body below and submit\n'
  printf '\n'

  if [ "$prompt_for_title" -eq 1 ]; then
    printf 'Press Enter to show issue content... ' >&2
    IFS= read -r _
    printf '\n%s\n\n' '----------------------------------------' >&2
  fi

  printf '# Issue Title\n\n'
  printf '%s\n\n' "$issue_title"
  printf '# Issue Body\n\n'
  printf '## Contributor Metadata\n\n'
  printf -- '- Local mcrepo version: `%s`\n' "$MCREPO_VERSION"
  printf -- '- Upstream mcrepo version: `%s`\n' "$remote_version"
  printf -- '- Upstream source URL: `%s`\n' "$(update_source_url)"
  printf -- '- Patch strategy: `%s`\n' "$strategy"
  printf -- '- Generated at: `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf -- '- Local generation id: `%s`\n\n' "$timestamp"
  if [ -n "$patch_strategy_note" ]; then
    printf -- '- Strategy note: %s\n\n' "$patch_strategy_note"
  fi
  if [ -n "$merge_conflict_note" ]; then
    printf -- '- Conflict note: %s\n\n' "$merge_conflict_note"
  fi
  printf '## Contributor Notes\n\n'
  printf -- '- Replace this line with a short problem statement and why this patch is needed.\n'
  printf -- '- Replace this line with expected behavior after applying the patch.\n\n'
  printf '## Instructions for Maintainer and Copilot\n\n'
  printf '1. Assign this issue to Copilot coding agent.\n'
  printf '2. Apply the patch from the `Patch` section below to `mcrepo.sh`, but keep current upstream behavior where unrelated hunks look like rollbacks.\n'
  printf '3. Validate syntax with `bash -n mcrepo.sh`.\n'
  printf '4. Run sandbox checks from `TESTING.md` as far as practical.\n'
  printf '5. Open a PR with:\n'
  printf '   - a concise summary of behavior changes,\n'
  printf '   - validation steps and outcomes,\n'
  printf '   - any caveats or follow-ups.\n\n'
  printf '## Copilot Guidance\n\n'
  printf -- '- Preserve upstream behavior unless a hunk is required for the new feature intent.\n'
  printf -- '- If a patch hunk appears to reintroduce removed logic, treat it as non-intent unless clearly required.\n'
  printf -- '- Prefer extracting minimal feature-specific changes over replaying historical state differences.\n\n'
  printf '## Patch\n\n'
  printf '```diff\n'
  cat "$patch_tmp_file"
  printf '```\n'

  rm -f "$remote_tmp_file" "$patch_tmp_file" "$base_tmp_file" "$merged_tmp_file"
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    export-patch|create-patch|version|--version|-V)
      MCREPO_SUPPRESS_VERSION_BANNER=1
      MCREPO_DISABLE_UPDATE_CHECK=1
      ;;
  esac

  print_version_banner
  notify_if_new_version_available "$cmd"

  case "$cmd" in
    init) cmd_init "$@" ;;
    add) cmd_add "$@" ;;
    upstream) cmd_upstream "$@" ;;
    fork) cmd_fork "$@" ;;
    doctor) cmd_doctor "$@" ;;
    new) cmd_new "$@" ;;
    publish) cmd_publish "$@" ;;
    publish-base) cmd_publish_base "$@" ;;
    remove) cmd_remove "$@" ;;
    write) set_mode_command write "$@" ;;
    read) set_mode_command read "$@" ;;
    sleep) set_mode_command sleep "$@" ;;
    list) cmd_list "$@" ;;
    branch) cmd_branch "$@" ;;
    rebase) cmd_rebase "$@" ;;
    sync) cmd_rebase "$@" ;;   # quiet alias (command renamed in 0.7.4)
    merge) cmd_merge "$@" ;;
    pr) cmd_pr "$@" ;;
    pull) cmd_pull "$@" ;;
    push) cmd_push "$@" ;;
    commit) cmd_commit "$@" ;;
    continue) cmd_continue "$@" ;;
    abort) cmd_abort "$@" ;;
    resolve) cmd_resolve "$@" ;;
    open) cmd_open "$@" ;;
    status) cmd_status "$@" ;;
    skill) cmd_skill "$@" ;;
    version|--version|-V) log "mcrepo version $MCREPO_VERSION" ;;
    update) cmd_update "$@" ;;
    install-extension) cmd_install_extension "$@" ;;
    create-patch) cmd_export_patch "$@" ;;
    export-patch)
      warn "Deprecation: 'mcrepo export-patch' is now 'mcrepo create-patch' (same behavior)."
      cmd_export_patch "$@"
      ;;
    --post-update-migrate) cmd_post_update_migrate "$@" ;;
    help|-h|--help) usage ;;
    *)
      usage
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"

# Explicit exit so bash never reads past this point. If the file on disk was
# replaced/extended while this process was running (self-update, editor save),
# bash could otherwise resume parsing at the old EOF offset and execute a
# garbage tail fragment of the new content.
exit $?
