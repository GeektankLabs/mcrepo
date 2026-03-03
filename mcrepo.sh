#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="mcrepo.sh"
MCREPO_VERSION="0.2.1"
MCREPO_UPDATE_REPO="GeektankLabs/mcrepo"
MCREPO_UPDATE_BRANCH="main"
MCREPO_UPDATE_SCRIPT_PATH="mcrepo.sh"
REPOS_FILE="mcrepo.yaml"
DEFAULT_PATH_STYLE="emoji"
SUPPORT_SCRIPTS_DIR="🛠 scripts"
SUPPORT_SEPARATOR_DIR="🔹🔹🔹"
SUPPORT_CONTRACTS_DIR="🧩 contracts"
SUPPORT_DOCS_DIR="🧾 docs"
SUPPORT_TESTS_DIR="🧪 tests"
COMPLETION_BASH_FILE=".mcrepo-completion.bash"
COMPLETION_ZSH_FILE=".mcrepo-completion.zsh"

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
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
  ./mcrepo.sh init [organization] [--no-shell-install] [--no-emojis] # Initialize MC-Repo structure and optionally sync repos from a GitHub organization
  ./mcrepo.sh add <git-url> [name]                # Add a repository to mcrepo.yaml (default mode: read) and clone it if needed
  ./mcrepo.sh remove <name-or-url>                # Remove a repository from mcrepo management configuration
  ./mcrepo.sh write <repo-name>                   # Switch a repository to write mode and auto-align to global branch (if configured)
  ./mcrepo.sh read <repo-name>                    # Switch a repository to read mode (read-only context)
  ./mcrepo.sh sleep <repo-name> [--force]         # Switch a repository to sleep mode and clear its local folder contents
  ./mcrepo.sh sleep --wakeall                     # Wake all sleeping repositories and set them to read mode
  ./mcrepo.sh list                                # List configured repositories with mode, local clone state, and current branch
  ./mcrepo.sh branch <branch-name> [--include-read] # Set global branch in mcrepo.yaml and create/switch it across target repos
  ./mcrepo.sh open <repo-name>                    # Open a write-mode repository in VS Code
  ./mcrepo.sh status                              # Show list output plus clean/dirty working tree state
  ./mcrepo.sh update                              # Update mcrepo.sh from canonical upstream when newer version is available
  ./mcrepo.sh create-patch [--strategy intent|legacy] [topic] # Print a ready-to-submit GitHub issue body (with embedded patch) to stdout
  ./mcrepo.sh help                                # Print this help text
EOF
}

is_truthy() {
  case "$1" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

print_version_banner() {
  if is_truthy "${MCREPO_SUPPRESS_VERSION_BANNER:-0}"; then
    return 0
  fi
  log "mcrepo version $MCREPO_VERSION"
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

notify_if_new_version_available() {
  local cmd="$1"
  local remote_tmp_file remote_version

  if [ "$cmd" = "update" ] || [ "$cmd" = "--post-update-migrate" ]; then
    return 0
  fi
  if is_truthy "${MCREPO_DISABLE_UPDATE_CHECK:-0}"; then
    return 0
  fi

  remote_tmp_file="$(mktemp)"
  remote_version="$(MCREPO_UPDATE_CHECK_QUIET=1 check_remote_version "$remote_tmp_file" || true)"
  rm -f "$remote_tmp_file"

  if [ -z "$remote_version" ]; then
    return 0
  fi

  if version_greater_than "$remote_version" "$MCREPO_VERSION"; then
    log_yellow "New version available: $MCREPO_VERSION -> $remote_version"
    log_yellow "Run 'mcrepo update' to update this script."
  fi
}

resolve_script_path() {
  local source_path script_dir
  source_path="${BASH_SOURCE[0]}"
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
    write|read|sleep|off) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_mode() {
  case "$1" in
    off) printf 'sleep' ;;
    *) printf '%s' "$1" ;;
  esac
}

validate_path_style() {
  case "$1" in
    emoji|clean) return 0 ;;
    *) return 1 ;;
  esac
}

normalize_path_style() {
  case "$1" in
    plain) printf 'clean' ;;
    *) printf '%s' "$1" ;;
  esac
}

mode_icon() {
  case "$1" in
    write) printf '✍️' ;;
    read) printf '👀' ;;
    sleep|off) printf '💤' ;;
    *) printf '•' ;;
  esac
}

mode_prefix_for_style() {
  local mode="$1"
  local style="$2"

  if [ "$style" = "clean" ]; then
    return 0
  fi

  mode_icon "$mode"
}

repo_dir_for_mode_with_style() {
  local repo_name="$1"
  local mode="$2"
  local style="$3"
  if [ "$style" = "clean" ]; then
    printf '%s' "$repo_name"
    return 0
  fi
  printf '%s %s' "$(mode_prefix_for_style "$mode" "$style")" "$repo_name"
}

repo_dir_for_mode() {
  local repo_name="$1"
  local mode="$2"
  printf '%s' "$(repo_dir_for_mode_with_style "$repo_name" "$mode" "$PATH_STYLE")"
}

repo_local_path_for_mode() {
  local repo_name="$1"
  local mode="$2"
  printf './%s' "$(repo_dir_for_mode "$repo_name" "$mode")"
}

repo_dir_candidates() {
  local repo_name="$1"
  printf '%s\n' \
    "$(repo_dir_for_mode_with_style "$repo_name" write emoji)" \
    "$(repo_dir_for_mode_with_style "$repo_name" read emoji)" \
    "$(repo_dir_for_mode_with_style "$repo_name" sleep emoji)" \
    "write $repo_name" \
    "read $repo_name" \
    "sleep $repo_name" \
    "$(repo_dir_for_mode_with_style "$repo_name" write clean)" \
    "$repo_name"
}

find_existing_repo_dir() {
  local repo_name="$1"
  local candidate

  while IFS= read -r candidate; do
    if [ -d "$candidate/.git" ] || [ -d "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done < <(repo_dir_candidates "$repo_name")

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

ensure_repos_file_exists() {
  if [ ! -f "$REPOS_FILE" ]; then
    printf 'repos: []\n' >"$REPOS_FILE"
  fi
}

parse_repos_tsv() {
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
      }
    }
    function emit() {
      if (in_item) {
        print url "\t" name "\t" mode "\t" description
      }
    }
    BEGIN {
      in_item = 0
      url = ""
      name = ""
      mode = ""
      description = ""
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

parse_path_style() {
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
      if (line ~ /^[ \t]*path_style:[ \t]*/) {
        sub(/^[ \t]*path_style:[ \t]*/, "", line)
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
ORGANIZATION=""
GLOBAL_BRANCH=""
PATH_STYLE="$DEFAULT_PATH_STYLE"

load_repos() {
  ensure_repos_file_exists
  REPO_URLS=()
  REPO_NAMES=()
  REPO_MODES=()
  REPO_DESCRIPTIONS=()
  ORGANIZATION=""
  GLOBAL_BRANCH=""
  PATH_STYLE="$DEFAULT_PATH_STYLE"

  ORGANIZATION="$(parse_organization || true)"
  GLOBAL_BRANCH="$(parse_branch || true)"
  PATH_STYLE="$(parse_path_style || true)"
  PATH_STYLE="$(normalize_path_style "$PATH_STYLE")"
  if ! validate_path_style "${PATH_STYLE:-}"; then
    PATH_STYLE="$DEFAULT_PATH_STYLE"
  fi

  local parsed_url parsed_name parsed_mode parsed_description
  while IFS=$'\t' read -r parsed_url parsed_name parsed_mode parsed_description; do
    [ -n "$parsed_url" ] || continue
    if [ -z "$parsed_name" ]; then
      parsed_name="$(derive_name_from_url "$parsed_url")"
    fi
    if ! validate_mode "${parsed_mode:-}"; then
      parsed_mode="read"
    fi
    parsed_mode="$(normalize_mode "$parsed_mode")"
    parsed_description="${parsed_description:-}"
    REPO_URLS+=("$parsed_url")
    REPO_NAMES+=("$parsed_name")
    REPO_MODES+=("$parsed_mode")
    REPO_DESCRIPTIONS+=("$parsed_description")
  done < <(parse_repos_tsv)
}

save_repos() {
  : >"$REPOS_FILE"
  if [ -n "$ORGANIZATION" ]; then
    printf 'organization: %s\n' "$ORGANIZATION" >"$REPOS_FILE"
  fi
  if [ -n "$GLOBAL_BRANCH" ]; then
    printf 'branch: %s\n' "$GLOBAL_BRANCH" >>"$REPOS_FILE"
  fi
  printf 'path_style: %s\n' "$PATH_STYLE" >>"$REPOS_FILE"

  if [ "${#REPO_URLS[@]}" -eq 0 ]; then
    printf 'repos: []\n' >>"$REPOS_FILE"
    return
  fi

  printf 'repos:\n' >>"$REPOS_FILE"
  local i
  for i in "${!REPO_URLS[@]}"; do
    printf '  - url: %s\n' "${REPO_URLS[$i]}" >>"$REPOS_FILE"
    printf '    name: %s\n' "${REPO_NAMES[$i]}" >>"$REPOS_FILE"
    printf '    mode: %s\n' "${REPO_MODES[$i]}" >>"$REPOS_FILE"
    printf '    description: "%s"\n' "$(yaml_escape_double_quoted "${REPO_DESCRIPTIONS[$i]}")" >>"$REPOS_FILE"
    printf '    localpath: %s\n' "$(repo_local_path_for_mode "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")" >>"$REPOS_FILE"
  done
}

sync_organization_repos() {
  local org_name="$1"
  local imported=0 skipped=0

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
    ensure_gitignore_repo_entry "$repo_name"
    imported=$((imported + 1))
  done <<<"$repo_rows"

  log "Organization '$org_name' sync: added=$imported skipped=$skipped"
}

find_repo_index() {
  local needle="$1"
  local i
  for i in "${!REPO_NAMES[@]}"; do
    if [ "${REPO_NAMES[$i]}" = "$needle" ] || [ "${REPO_URLS[$i]}" = "$needle" ]; then
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
}

ensure_gitignore_repo_entry() {
  local repo_name="$1"
  ensure_gitignore_base
  local candidate line
  while IFS= read -r candidate; do
    line="/${candidate}/"
    if ! grep -Fqx "$line" .gitignore; then
      printf '%s\n' "$line" >>.gitignore
    fi
  done < <(repo_dir_candidates "$repo_name")
}

remove_gitignore_repo_entry() {
  local repo_name="$1"
  [ -f .gitignore ] || return 0
  local candidate line tmp
  while IFS= read -r candidate; do
    line="/${candidate}/"
    tmp="$(mktemp)"
    grep -Fvx "$line" .gitignore >"$tmp" || true
    mv "$tmp" .gitignore
  done < <(repo_dir_candidates "$repo_name")
}

clone_repo_if_needed() {
  local repo_dir="$1"
  local repo_url="$2"
  local mode="$3"

  if [ "$mode" = "sleep" ] || [ "$mode" = "off" ]; then
    return 0
  fi
  if [ -d "$repo_dir/.git" ]; then
    return 0
  fi
  if [ -e "$repo_dir" ] && [ ! -d "$repo_dir" ]; then
    warn "Path '$repo_dir' exists and is not a directory, skipping clone"
    return 1
  fi

  if [ -d "$repo_dir" ]; then
    shopt -s nullglob dotglob
    local entries=("$repo_dir"/*)
    shopt -u nullglob dotglob
    if [ "${#entries[@]}" -gt 0 ]; then
      warn "Path '$repo_dir' exists but is not a git repository and not empty, skipping clone"
      return 1
    fi
  fi

  log "Cloning $repo_dir..."
  git clone "$repo_url" "$repo_dir"
}

refresh_generated_files() {
  mkdir -p "$SUPPORT_SCRIPTS_DIR"

  COMPLETION_BASH_FILE="$SUPPORT_SCRIPTS_DIR/mcrepo-completion.bash"
  COMPLETION_ZSH_FILE="$SUPPORT_SCRIPTS_DIR/mcrepo-completion.zsh"

  rm -f .mcrepo-completion.bash .mcrepo-completion.zsh .mcrepo-completion.csh

  generate_bash_completion
  generate_zsh_completion
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
  local commands="init add remove write read sleep off list branch open status update export-patch create-patch help"
  local repo_commands="remove write read sleep off open"

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
      COMPREPLY=( $(compgen -W "--include-read" -- "$cur") )
      ;;
    remove|write|read|sleep|off|open)
      if [ "$COMP_CWORD" -eq 2 ]; then
        if [ "${COMP_WORDS[1]}" = "sleep" -o "${COMP_WORDS[1]}" = "off" ]; then
          COMPREPLY=( $(compgen -W "$(_mcrepo_repo_names) --wakeall" -- "$cur") )
        else
          COMPREPLY=( $(compgen -W "$(_mcrepo_repo_names)" -- "$cur") )
        fi
      elif [ "$COMP_CWORD" -eq 3 ] && [ "${COMP_WORDS[1]}" = "sleep" -o "${COMP_WORDS[1]}" = "off" ]; then
        COMPREPLY=( $(compgen -W "--force -force" -- "$cur") )
      fi
      ;;
    *)
      ;;
  esac
}

complete -F _mcrepo_complete mcrepo
complete -F _mcrepo_complete ./mcrepo.sh
EOF
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
  local -a commands repos

  commands=(init add remove write read sleep off list branch open status update export-patch create-patch help)
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
        compadd -- --include-read
      fi
      ;;
    remove|write|read|sleep|off|open)
      if (( CURRENT == 3 )); then
        if [[ "$cmd" == "sleep" || "$cmd" == "off" ]]; then
          compadd -- "${repos[@]}" --wakeall
        else
          compadd -- "${repos[@]}"
        fi
      elif (( CURRENT == 4 )) && [[ "$cmd" == "sleep" || "$cmd" == "off" ]]; then
        compadd -- --force -force
      fi
      ;;
    *) ;;
  esac
}

compdef _mcrepo_complete mcrepo
compdef _mcrepo_complete ./mcrepo.sh
EOF
}

create_readme_template() {
  cat >README.md <<'EOF'
# Multi-Context Repo

This repository is a lightweight meta-repo for coordinating multiple standalone repositories with explicit access modes.

## Quickstart

1. Put `mcrepo.sh` in the repository root.
2. Make it executable: `chmod +x ./mcrepo.sh`
3. Initialize: `./mcrepo.sh init`
4. Open a new shell once, then run commands as `mcrepo`
5. Add a repository: `mcrepo add <git-url>`
6. Set repo mode: `mcrepo write <repo>` or `mcrepo read <repo>` or `mcrepo sleep <repo>`
7. Create/switch branch in write repos: `mcrepo branch <branch-name>`
8. Check state: `mcrepo status`

## Core Concepts

- `mcrepo.yaml` is the source of truth for managed repositories.
- `mcrepo.yaml` can define a top-level `branch` that acts as the global working branch for write repos.
- Modes control intent:
  - `write`: editable and active
  - `read`: local context only
  - `sleep`: currently inactive
- Default path style uses emoji folder prefixes: `✍️`, `👀`, `💤`
- You can disable emoji folders during init: `./mcrepo.sh init --no-emojis` (uses clean paths without mode prefixes)
- `mcrepo.sh` orchestrates repositories.
- `mcrepo branch <name>` updates the global branch and applies it across write repos.
- Switching a repo to `write` auto-aligns it to the global branch when configured.
- `🛠 scripts/` is for project-specific helper scripts.

## Human Workflow

- Commits, pull requests, and merges are done per repository.
- Cross-repo changes should start by checking `🧩 contracts/` and `🧾 docs/`.
EOF
}

create_agents_template() {
  cat >AGENTS.md <<'EOF'
## MC-Repo Context

This repository is a Multi-Context-Repo (MC-Repo) that groups multiple independent repositories for coordinated work.
Always read the mcrepo.yaml first under "repos" you find the list of all repositories their "localpath", "mode" and "description". 

# Agent Rules for this Multi-Context Repo

**STRICT MODE + PATH STYLE ENFORCEMENT (MANDATORY)**

1. Before any work, read `mcrepo.yaml` and verify repo access by **both** fields:
   - `mode` value
   - prefix in `localpath` according to `path_style`
2. Mode/prefix mapping is strict and must be treated as a hard safety gate:
   - For `path_style: emoji`:
     - `mode: write` <-> `✍️`
     - `mode: read` <-> `👀`
     - `mode: sleep` <-> `💤`
   - For `path_style: clean`:
     - local paths are plain repo names without mode prefixes
     - mode restrictions still apply from `mode` field
3. Edit **only** repositories marked `mode: write` with matching prefix.
4. Treat repositories marked `mode: read` with matching prefix as strictly read-only (never modify files there).
5. Treat repositories marked `mode: sleep` with matching prefix as strictly inactive: do not implement, do not research inside them, do not include them in active scope.
6. If mode and path prefix ever disagree, treat the repository as restricted (read-only at minimum) and do not perform write operations until clarified.
7. For cross-repo changes, check `🧩 contracts/` and `🧾 docs/` first.
8. Coordinate changes across all `write` repositories.
9. Do not execute git commits.
10. Always wrap paths in quotes to handle spaces correctly.

## Local Project Instructions

When working inside a project repository, also read and follow local instruction files if present:
- `AGENTS.md`
- `CLAUDE.md`
EOF
}

create_gitignore_template() {
  : >.gitignore
}

create_repos_template() {
  printf 'repos: []\n' >"$REPOS_FILE"
}

ensure_base_structure() {
  if [ -d "🔹 separator" ] && [ ! -e "$SUPPORT_SEPARATOR_DIR" ]; then
    mv "🔹 separator" "$SUPPORT_SEPARATOR_DIR"
  fi
  if [ -d "▪️ separator" ] && [ ! -e "$SUPPORT_SEPARATOR_DIR" ]; then
    mv "▪️ separator" "$SUPPORT_SEPARATOR_DIR"
  fi
  if [ -d "〰️ separator" ] && [ ! -e "$SUPPORT_SEPARATOR_DIR" ]; then
    mv "〰️ separator" "$SUPPORT_SEPARATOR_DIR"
  fi
  if [ -d "– separator" ] && [ ! -e "$SUPPORT_SEPARATOR_DIR" ]; then
    mv "– separator" "$SUPPORT_SEPARATOR_DIR"
  fi
  if [ -d "separator" ] && [ ! -e "$SUPPORT_SEPARATOR_DIR" ]; then
    mv "separator" "$SUPPORT_SEPARATOR_DIR"
  fi

  if [ -d "🛠scripts" ] && [ ! -e "$SUPPORT_SCRIPTS_DIR" ]; then
    mv "🛠scripts" "$SUPPORT_SCRIPTS_DIR"
  fi
  if [ -d "🧩contracts" ] && [ ! -e "$SUPPORT_CONTRACTS_DIR" ]; then
    mv "🧩contracts" "$SUPPORT_CONTRACTS_DIR"
  fi
  if [ -d "🧾docs" ] && [ ! -e "$SUPPORT_DOCS_DIR" ]; then
    mv "🧾docs" "$SUPPORT_DOCS_DIR"
  fi

  if [ -d "scripts" ] && [ ! -e "$SUPPORT_SCRIPTS_DIR" ]; then
    mv "scripts" "$SUPPORT_SCRIPTS_DIR"
  fi
  if [ -d "contracts" ] && [ ! -e "$SUPPORT_CONTRACTS_DIR" ]; then
    mv "contracts" "$SUPPORT_CONTRACTS_DIR"
  fi
  if [ -d "docs" ] && [ ! -e "$SUPPORT_DOCS_DIR" ]; then
    mv "docs" "$SUPPORT_DOCS_DIR"
  fi
  if [ -d "tests" ] && [ ! -e "$SUPPORT_TESTS_DIR" ]; then
    mv "tests" "$SUPPORT_TESTS_DIR"
  fi

  mkdir -p "$SUPPORT_SCRIPTS_DIR" "$SUPPORT_SEPARATOR_DIR" "$SUPPORT_CONTRACTS_DIR" "$SUPPORT_DOCS_DIR" "$SUPPORT_TESTS_DIR"
}

ensure_base_files() {
  [ -f .gitignore ] || create_gitignore_template
  [ -f README.md ] || create_readme_template
  [ -f AGENTS.md ] || create_agents_template
  [ -f "$REPOS_FILE" ] || create_repos_template
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
    elif [ "${REPO_MODES[$i]}" = "sleep" ] || [ "${REPO_MODES[$i]}" = "off" ]; then
      mkdir -p "$repo_dir"
    fi
  done
}

cmd_init() {
  local org_arg=""
  local no_shell_install=0
  local no_emojis=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --no-shell-install)
        no_shell_install=1
        ;;
      --no-emojis)
        no_emojis=1
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
          die "Usage: ./mcrepo.sh init [organization] [--no-shell-install] [--no-emojis]"
        fi
        org_arg="$1"
        ;;
    esac
    shift
  done

  [ "$#" -eq 0 ] || die "Usage: ./mcrepo.sh init [organization] [--no-shell-install] [--no-emojis]"

  case "${MCREPO_NO_SHELL_INSTALL:-0}" in
    1|true|TRUE|yes|YES)
      no_shell_install=1
      ;;
  esac

  ensure_base_structure
  ensure_base_files
  load_repos

  if [ -n "$org_arg" ]; then
    ORGANIZATION="$org_arg"
  fi

  if [ -n "$ORGANIZATION" ]; then
    sync_organization_repos "$ORGANIZATION"
  fi

  if [ "$no_emojis" -eq 1 ]; then
    PATH_STYLE="clean"
  fi

  save_repos
  materialize_from_repos_file
  refresh_generated_files

  if [ "$no_shell_install" -eq 1 ]; then
    log "Skipped shell command installation (--no-shell-install or MCREPO_NO_SHELL_INSTALL=1)."
  else
    install_shell_command
  fi

  log "Multi-Context repo initialized."
  if [ "${#REPO_NAMES[@]}" -eq 0 ]; then
    log "No repos configured yet."
    log "Next steps - add all relevant repostories:"
    log "  ./mcrepo.sh add <git-url>"
  fi
}

cmd_add() {
  [ "$#" -ge 1 ] || die "Usage: ./mcrepo.sh add <git-url> [name]"
  local url="$1"
  local name="${2:-}"
  local mode="read"

  load_repos
  [ -n "$name" ] || name="$(derive_name_from_url "$url")"
  [ -n "$name" ] || die "Could not derive repository name"

  if find_repo_index "$url" >/dev/null 2>&1; then
    die "Repository URL already exists in $REPOS_FILE"
  fi
  if find_repo_index "$name" >/dev/null 2>&1; then
    die "Repository name already exists in $REPOS_FILE"
  fi

  REPO_URLS+=("$url")
  REPO_NAMES+=("$name")
  REPO_MODES+=("$mode")
  REPO_DESCRIPTIONS+=("")
  save_repos

  ensure_gitignore_repo_entry "$name"
  local repo_dir
  repo_dir="$(ensure_repo_dir_mode "$name" "$mode")"
  if ! clone_repo_if_needed "$repo_dir" "$url" "$mode"; then
    warn "Repo added, but clone failed for '$name'"
  fi
  refresh_generated_files

  log "Added repo '$name' in mode '$mode'."
  print_description_update_prompt
}

cmd_remove() {
  [ "$#" -eq 1 ] || die "Usage: ./mcrepo.sh remove <name-or-url>"
  local target="$1"

  load_repos
  local idx
  idx="$(find_repo_index "$target")" || die "Repo not found: $target"

  local removed_name="${REPO_NAMES[$idx]}"

  local old_urls=("${REPO_URLS[@]}")
  local old_names=("${REPO_NAMES[@]}")
  local old_modes=("${REPO_MODES[@]}")
  local old_descriptions=("${REPO_DESCRIPTIONS[@]}")

  REPO_URLS=()
  REPO_NAMES=()
  REPO_MODES=()
  REPO_DESCRIPTIONS=()

  local i
  for i in "${!old_urls[@]}"; do
    if [ "$i" -ne "$idx" ]; then
      REPO_URLS+=("${old_urls[$i]}")
      REPO_NAMES+=("${old_names[$i]}")
      REPO_MODES+=("${old_modes[$i]}")
      REPO_DESCRIPTIONS+=("${old_descriptions[$i]}")
    fi
  done
  save_repos

  remove_gitignore_repo_entry "$removed_name"

  refresh_generated_files
  log "Removed repo '$removed_name' from management."
}

set_mode_command() {
  local target_mode="$1"
  shift

  if [ "$target_mode" = "sleep" ] || [ "$target_mode" = "off" ]; then
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
        if [ "$target_mode" != "sleep" ] && [ "$target_mode" != "off" ]; then
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

  if [ "$previous_mode" = "write" ] && [ "$target_mode" != "write" ]; then
    local previous_repo_dir
    previous_repo_dir="$(get_repo_dir "${REPO_NAMES[$idx]}" "$previous_mode")"
    if [ -d "$previous_repo_dir/.git" ] && [ -n "$(git -C "$previous_repo_dir" status --porcelain 2>/dev/null)" ]; then
      if [ "$target_mode" = "sleep" ] && [ "$force_sleep" -eq 1 ]; then
        :
      elif [ "$target_mode" = "sleep" ] || [ "$target_mode" = "off" ]; then
        die "Repository '${REPO_NAMES[$idx]}' has uncommitted changes in '$previous_repo_dir'. Commit/stash them first, or run './mcrepo.sh sleep ${REPO_NAMES[$idx]} --force' to discard local changes and clear contents."
      else
        die "Repository '${REPO_NAMES[$idx]}' has uncommitted changes in '$previous_repo_dir'. Commit/stash them first before changing mode to '$target_mode'."
      fi
    fi
  fi

  REPO_MODES[$idx]="$target_mode"
  save_repos

  local repo_dir
  repo_dir="$(ensure_repo_dir_mode "${REPO_NAMES[$idx]}" "$target_mode")"

  ensure_gitignore_repo_entry "${REPO_NAMES[$idx]}"
  if [ "$target_mode" = "write" ] || [ "$target_mode" = "read" ]; then
    if ! clone_repo_if_needed "$repo_dir" "${REPO_URLS[$idx]}" "$target_mode"; then
      warn "Mode changed, but clone failed for '${REPO_NAMES[$idx]}'"
    fi
  fi
  if [ "$target_mode" = "write" ]; then
    apply_global_branch_to_repo_if_configured "${REPO_NAMES[$idx]}" "$repo_dir"
  fi
  if [ "$target_mode" = "sleep" ] || [ "$target_mode" = "off" ]; then
    mkdir -p "$repo_dir"
    clear_directory_contents "$repo_dir"
    if [ "$force_sleep" -eq 1 ]; then
      log "Put repo into sleep mode and force-cleared local contents: $repo_dir"
    else
      log "Put repo into sleep mode and cleared local contents: $repo_dir"
    fi
  fi

  refresh_generated_files
  log "Set '${REPO_NAMES[$idx]}' to mode '$target_mode'."
}

wake_all_sleeping_repos_to_read() {
  load_repos

  local i woke_count=0
  local -a woke_indexes=()
  for i in "${!REPO_NAMES[@]}"; do
    if [ "${REPO_MODES[$i]}" = "sleep" ] || [ "${REPO_MODES[$i]}" = "off" ]; then
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
    repo_dir="$(ensure_repo_dir_mode "${REPO_NAMES[$i]}" "read")"
    ensure_gitignore_repo_entry "${REPO_NAMES[$i]}"
    if ! clone_repo_if_needed "$repo_dir" "${REPO_URLS[$i]}" "read"; then
      warn "Mode changed, but clone failed for '${REPO_NAMES[$i]}'"
    fi
  done

  refresh_generated_files
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

cmd_list() {
  load_repos
  local i local_state branch repo_dir
  for i in "${!REPO_NAMES[@]}"; do
    repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    if [ -d "$repo_dir/.git" ]; then
      local_state="yes"
    else
      local_state="no"
    fi
    branch="$(repo_branch "$repo_dir")"
    printf '%-20s mode=%-5s local=%-3s branch=%s\n' "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}" "$local_state" "$branch"
  done
}

cmd_status() {
  load_repos
  local i local_state branch dirty repo_dir
  for i in "${!REPO_NAMES[@]}"; do
    repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}")"
    if [ -d "$repo_dir/.git" ]; then
      local_state="yes"
    else
      local_state="no"
    fi
    branch="$(repo_branch "$repo_dir")"
    dirty="$(repo_dirty_state "$repo_dir")"
    printf '%-20s mode=%-5s local=%-3s branch=%-20s state=%s\n' "${REPO_NAMES[$i]}" "${REPO_MODES[$i]}" "$local_state" "$branch" "$dirty"
  done
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

switch_repo_branch() {
  local repo_dir="$1"
  local target_branch="$2"
  if ! git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    warn "Skipping '$repo_dir' (not a local git repo)"
    return 0
  fi

  if ! git -C "$repo_dir" fetch --all --prune; then
    warn "Fetch failed in '$repo_dir' before switching to '$target_branch'"
  fi

  if ! git -C "$repo_dir" pull --ff-only; then
    warn "Pull failed in '$repo_dir' before switching to '$target_branch'"
  fi

  if ! git -C "$repo_dir" fetch origin --prune; then
    warn "Fetch origin failed in '$repo_dir' before switching to '$target_branch'"
  fi

  if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$target_branch"; then
    git -C "$repo_dir" checkout "$target_branch"
  else
    git -C "$repo_dir" checkout -b "$target_branch"
  fi
}

cmd_branch() {
  [ "$#" -ge 1 ] || die "Usage: ./mcrepo.sh branch <branch-name> [--include-read]"
  local branch_name="$1"
  shift
  local include_read=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --include-read) include_read=1 ;;
      *) die "Unknown branch option: $1" ;;
    esac
    shift
  done

  load_repos
  GLOBAL_BRANCH="$branch_name"
  save_repos

  local i mode repo_dir
  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    if [ "$mode" = "write" ] || { [ "$include_read" -eq 1 ] && [ "$mode" = "read" ]; }; then
      repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "$mode")"
      switch_repo_branch "$repo_dir" "$branch_name"
    fi
  done

  log "Branch operation complete. Global branch set to '$GLOBAL_BRANCH'."
}

cmd_post_update_migrate() {
  [ "$#" -eq 2 ] || return 0
  return 0
}

cmd_update() {
  [ "$#" -eq 0 ] || die "Usage: ./mcrepo.sh update"

  local remote_tmp_file remote_version current_version
  local script_path

  current_version="$MCREPO_VERSION"
  remote_tmp_file="$(mktemp)"

  remote_version="$(check_remote_version "$remote_tmp_file" || true)"
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

  chmod +x "$remote_tmp_file"

  mv "$remote_tmp_file" "$script_path"
  log "Updated mcrepo from version $current_version to $remote_version."

  if MCREPO_SUPPRESS_VERSION_BANNER=1 MCREPO_DISABLE_UPDATE_CHECK=1 "$script_path" --post-update-migrate "$current_version" "$remote_version"; then
    log "Update complete. Run mcrepo again to use the new version."
  else
    warn "Updated script, but post-update migration hook reported an issue."
    warn "Run mcrepo again and inspect your workspace state before continuing."
  fi
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
  printf '5. Ask maintainer to add label `patch submission` and assign the issue to Copilot coding agent\n\n'

  if [ "$prompt_for_title" -eq 1 ]; then
    printf 'Press Enter to show issue content... ' >&2
    IFS= read -r _
    printf '\n' >&2
  fi

  printf '# Issue Title\n\n'
  printf '%s\n\n' "$issue_title"
  printf '# Issue Body\n\n'
  printf 'Maintainer: please add label `patch submission` and assign this issue to Copilot coding agent.\n\n'
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

  if [ "$cmd" = "export-patch" ] || [ "$cmd" = "create-patch" ]; then
    MCREPO_SUPPRESS_VERSION_BANNER=1
    MCREPO_DISABLE_UPDATE_CHECK=1
  fi

  print_version_banner
  notify_if_new_version_available "$cmd"

  case "$cmd" in
    init) cmd_init "$@" ;;
    add) cmd_add "$@" ;;
    remove) cmd_remove "$@" ;;
    write) set_mode_command write "$@" ;;
    read) set_mode_command read "$@" ;;
    sleep) set_mode_command sleep "$@" ;;
    off) set_mode_command sleep "$@" ;;
    list) cmd_list "$@" ;;
    branch) cmd_branch "$@" ;;
    open) cmd_open "$@" ;;
    status) cmd_status "$@" ;;
    update) cmd_update "$@" ;;
    export-patch|create-patch) cmd_export_patch "$@" ;;
    --post-update-migrate) cmd_post_update_migrate "$@" ;;
    help|-h|--help) usage ;;
    *)
      usage
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
