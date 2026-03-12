#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="mcrepo.sh"
MCREPO_VERSION="0.2.15"
MCREPO_UPDATE_REPO="GeektankLabs/mcrepo"
MCREPO_UPDATE_BRANCH="main"
MCREPO_UPDATE_SCRIPT_PATH="mcrepo.sh"
REPOS_FILE="mcrepo.yaml"
LEGACY_SUPPORT_SCRIPTS_DIR="🛠 scripts"
SUPPORT_CONTRACTS_DIR="🧩 contracts"
SUPPORT_DOCS_DIR="🧾 docs"
SUPPORT_TESTS_DIR="🧪 tests"
SUPPORT_SKILLS_DIR="🧠 skills"
SKILLS_CONFIG_FILE="$SUPPORT_SKILLS_DIR/skills.yaml"
OPENCODE_PROJECT_SKILLS_DIR=".opencode/skills"
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
  ./mcrepo.sh init [organization] [--no-shell-install] # Initialize MC-Repo structure and optionally sync repos from a GitHub organization
  ./mcrepo.sh add <git-url> [name]                # Add a repository to mcrepo.yaml (default mode: read) and clone it if needed
  ./mcrepo.sh remove <name-or-url>                # Remove a repository from mcrepo management configuration
  ./mcrepo.sh write <repo-name>                   # Switch a repository to write mode and auto-align to global branch (if configured)
  ./mcrepo.sh read <repo-name>                    # Switch a repository to read mode (read-only context)
  ./mcrepo.sh sleep <repo-name> [--force]         # Switch a repository to sleep mode and clear its local folder contents
  ./mcrepo.sh sleep --wakeall                     # Wake all sleeping repositories and set them to read mode
  ./mcrepo.sh list                                # List configured repositories with mode, local clone state, and current branch
  ./mcrepo.sh branch <branch-name> [--include-read] # Set global branch and switch clean target repos plus meta-context repo
  ./mcrepo.sh open <repo-name>                    # Open a write-mode repository in VS Code
  ./mcrepo.sh status                              # Show list output plus clean/dirty working tree state
  ./mcrepo.sh skill [repo-name] <list|new|install|enable|disable|validate> [args] # Manage workspace or sub-repo skills (OpenCode-compatible)
                                              # Browse public skills: https://clawhub.ai/skills
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

mode_icon() {
  case "$1" in
    write) printf '✏️' ;;
    read) printf '👀' ;;
    sleep|off) printf '💤' ;;
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

REPO_URLS=()
REPO_NAMES=()
REPO_MODES=()
REPO_DESCRIPTIONS=()
ORGANIZATION=""
GLOBAL_BRANCH=""

load_repos() {
  ensure_repos_file_exists
  REPO_URLS=()
  REPO_NAMES=()
  REPO_MODES=()
  REPO_DESCRIPTIONS=()
  ORGANIZATION=""
  GLOBAL_BRANCH=""

  ORGANIZATION="$(parse_organization || true)"
  GLOBAL_BRANCH="$(parse_branch || true)"

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
  local line tmp

  line="/$repo_name/"
  if ! grep -Fqx "$line" .gitignore; then
    printf '%s\n' "$line" >>.gitignore
  fi

  tmp="$(mktemp)"
  grep -Fvx "/✏️ $repo_name/" .gitignore >"$tmp" || true
  mv "$tmp" .gitignore
  tmp="$(mktemp)"
  grep -Fvx "/👀 $repo_name/" .gitignore >"$tmp" || true
  mv "$tmp" .gitignore
  tmp="$(mktemp)"
  grep -Fvx "/💤 $repo_name/" .gitignore >"$tmp" || true
  mv "$tmp" .gitignore
  tmp="$(mktemp)"
  grep -Fvx "/write $repo_name/" .gitignore >"$tmp" || true
  mv "$tmp" .gitignore
  tmp="$(mktemp)"
  grep -Fvx "/read $repo_name/" .gitignore >"$tmp" || true
  mv "$tmp" .gitignore
  tmp="$(mktemp)"
  grep -Fvx "/sleep $repo_name/" .gitignore >"$tmp" || true
  mv "$tmp" .gitignore
}

remove_gitignore_repo_entry() {
  local repo_name="$1"
  [ -f .gitignore ] || return 0
  local line tmp

  line="/$repo_name/"
  tmp="$(mktemp)"
  grep -Fvx "$line" .gitignore >"$tmp" || true
  mv "$tmp" .gitignore
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
  git clone "$repo_url" "$repo_dir"
}

refresh_generated_files() {
  rm -f "$LEGACY_SUPPORT_SCRIPTS_DIR/mcrepo-completion.bash" "$LEGACY_SUPPORT_SCRIPTS_DIR/mcrepo-completion.zsh"
  rm -f .mcrepo-completion.csh

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
  local commands="init add remove write read sleep off list branch open status skill update export-patch create-patch help"
  local skill_commands="list new install enable disable validate"
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
  local subcmd
  local -a commands repos skill_commands

  commands=(init add remove write read sleep off list branch open status skill update export-patch create-patch help)
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
        compadd -- --include-read
      fi
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
It provides workspace governance across repos, shared documentation, tests, and reusable agent skills.

## Quickstart

1. Put `mcrepo.sh` in the repository root.
2. Make it executable: `chmod +x ./mcrepo.sh`
3. Initialize: `./mcrepo.sh init`
4. Open a new shell once, then run commands as `mcrepo`
5. Add a repository: `mcrepo add <git-url>`
6. Set repo mode: `mcrepo write <repo>` or `mcrepo read <repo>` or `mcrepo sleep <repo>`
7. Coordinate branch across clean target repos and meta-context repo: `mcrepo branch <branch-name>`
8. Check state: `mcrepo status`
9. Manage workspace skills: `mcrepo skill list`
10. Install skills from URL: `mcrepo skill install <github-url|clawhub-url>`

## Core Concepts

- `mcrepo.yaml` is the source of truth for managed repositories.
- `mcrepo.yaml` can define a top-level `branch` that acts as the global working branch for write repos.
- Modes control intent:
  - `write`: editable and active
  - `read`: local context only
  - `sleep`: currently inactive
- Repository folders always use clean repo names (no mode-prefix or emoji-prefix renaming)
- `mcrepo.sh` orchestrates repositories.
- `mcrepo branch <name>` updates the global branch, aligns clean write repos (optionally read repos), then switches the meta-context repo.
- Branch switching is remote-first: if `origin/<name>` exists and local `<name>` does not, mcrepo creates a tracking local branch from origin.
- Global branch switch aborts if uncommitted changes are present in target repos or the meta-context repo.
- Switching a repo to `write` auto-aligns it to the global branch when configured.
- `🧠 skills/` stores project and company specific agent skills.
- Skills can include colocated helper scripts (for example `run.sh` or `check.sh`) next to `skill.md`.
- ClawHub URL installs are scanned by default; `CRITICAL` blocks install and `HIGH` warns.

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

**STRICT MODE ENFORCEMENT (MANDATORY)**

1. Before any work, read `mcrepo.yaml` and verify repo access by **both** fields:
   - `mode` value
   - clean repo folder in `localpath` (no mode/emoji prefix)
2. Edit **only** repositories marked `mode: write`.
3. Treat repositories marked `mode: read` as strictly read-only (never modify files there).
4. Treat repositories marked `mode: sleep` as strictly inactive: do not implement, do not research inside them, do not include them in active scope.
5. For cross-repo changes, check `🧩 contracts/` and `🧾 docs/` first.
6. Coordinate changes across all `write` repositories.
7. Do not execute git commits.
8. Always wrap paths in quotes to handle spaces correctly.

## Ordering and Shared Folders

- Keep managed repositories and shared folders as separate top-level entries.
- Do not create or rely on a visual separator directory.

## Skills Loading

1. Enforce `mcrepo.yaml` mode gates first.
2. Load active skills from `🧠 skills/`:
   - If `🧠 skills/skills.yaml` exists, use its enable/disable lists.
   - If no config exists, treat each `🧠 skills/<id>/skill.md` as active by default.
3. `🧠 skills/` is the workspace source of truth and is mirrored to `.opencode/skills/` for OpenCode auto-discovery.
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
2. Check `🧩 contracts/` and `🧾 docs/` for existing agreements.
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
2. Run fast syntax/lint checks where available.
3. Capture failures with actionable next steps.
4. Report what was run and what could not be run.
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
  "scm.repositories.selectionMode": "multi",
  "git.autoRepositoryDetection": "subFolders",
  "git.repositoryScanMaxDepth": 2
}
EOF

  log "Created VS Code workspace settings: $vscode_settings_file"
}

maybe_reload_vscode_window() {
  if command -v code >/dev/null 2>&1; then
    if code --reuse-window --command workbench.action.reloadWindow >/dev/null 2>&1; then
      log "Triggered VS Code window reload via CLI command."
      return 0
    fi
  fi

  log "If VS Code does not reflect SCM settings yet, reload the window (Cmd/Ctrl+Shift+P -> Reload Window) or restart VS Code."
}

directory_is_empty() {
  local dir="$1"
  local entries=()
  shopt -s nullglob dotglob
  entries=("$dir"/*)
  shopt -u nullglob dotglob
  [ "${#entries[@]}" -eq 0 ]
}

remove_legacy_separator_dirs() {
  local separator_dir
  local separator_dirs=(
    "🔹🔹🔹"
    "🔹 separator"
    "▪️ separator"
    "〰️ separator"
    "– separator"
    "separator"
  )

  for separator_dir in "${separator_dirs[@]}"; do
    [ -d "$separator_dir" ] || continue
    if directory_is_empty "$separator_dir"; then
      rmdir "$separator_dir"
      log "Removed legacy separator directory: $separator_dir"
    else
      warn "Keeping non-empty legacy separator directory: $separator_dir"
    fi
  done
}

ensure_base_structure() {
  remove_legacy_separator_dirs

  if [ -d "🧠skills" ] && [ ! -e "$SUPPORT_SKILLS_DIR" ]; then
    mv "🧠skills" "$SUPPORT_SKILLS_DIR"
  fi
  if [ -d "🧩contracts" ] && [ ! -e "$SUPPORT_CONTRACTS_DIR" ]; then
    mv "🧩contracts" "$SUPPORT_CONTRACTS_DIR"
  fi
  if [ -d "🧾docs" ] && [ ! -e "$SUPPORT_DOCS_DIR" ]; then
    mv "🧾docs" "$SUPPORT_DOCS_DIR"
  fi

  if [ -d "skills" ] && [ ! -e "$SUPPORT_SKILLS_DIR" ]; then
    mv "skills" "$SUPPORT_SKILLS_DIR"
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

  if [ "$no_shell_install" -eq 1 ]; then
    log "Skipped shell command installation (--no-shell-install or MCREPO_NO_SHELL_INSTALL=1)."
  else
    install_shell_command
  fi

  maybe_reload_vscode_window

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
    write_sleep_placeholder_files "$repo_dir"
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
  SKILL_SCOPE_NAME="workspace"
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
  SKILL_SCOPE_NAME="$repo_name"
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

  local id
  local -a enabled_ids=()
  local -a disabled_ids=()
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    enabled_ids+=("$id")
  done < <(parse_skill_config_list "enabled")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    disabled_ids+=("$id")
  done < <(parse_skill_config_list "disabled")

  mapfile -t enabled_ids < <(array_remove_item "$skill_id" "${enabled_ids[@]}")
  mapfile -t disabled_ids < <(array_remove_item "$skill_id" "${disabled_ids[@]}")
  enabled_ids+=("$skill_id")
  write_skills_config "${enabled_ids[@]}" "__MCREPO_DISABLED_SPLIT__" "${disabled_ids[@]}"
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

  if array_contains "$skill_id" "${disabled_ids[@]}"; then
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

      while IFS= read -r id; do
        [ -n "$id" ] || continue
        enabled_ids+=("$id")
      done < <(parse_skill_config_list "enabled")

      while IFS= read -r id; do
        [ -n "$id" ] || continue
        disabled_ids+=("$id")
      done < <(parse_skill_config_list "disabled")

      if [ "${#enabled_ids[@]}" -gt 0 ]; then
        explicit_mode=1
      fi

      if [ ! -f "$SKILLS_CONFIG_FILE" ]; then
        while IFS= read -r id; do
          [ -n "$id" ] || continue
          enabled_ids+=("$id")
        done < <(list_skill_ids "$SUPPORT_SKILLS_DIR")
        explicit_mode=1
      fi

      mapfile -t enabled_ids < <(array_remove_item "$target_id" "${enabled_ids[@]}")
      mapfile -t disabled_ids < <(array_remove_item "$target_id" "${disabled_ids[@]}")

      if [ "$subcmd" = "enable" ]; then
        if [ "$explicit_mode" -eq 1 ]; then
          enabled_ids+=("$target_id")
        fi
      else
        disabled_ids+=("$target_id")
      fi

      write_skills_config "${enabled_ids[@]}" "__MCREPO_DISABLED_SPLIT__" "${disabled_ids[@]}"
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

cmd_branch() {
  [ "$#" -ge 1 ] || die "Usage: ./mcrepo.sh branch <branch-name> [--include-read]"
  local branch_name="$1"
  shift
  local include_read=0
  local dirty_found=0
  local -a dirty_repos=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --include-read) include_read=1 ;;
      *) die "Unknown branch option: $1" ;;
    esac
    shift
  done

  load_repos

  local i mode repo_dir
  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    if [ "$mode" = "write" ] || { [ "$include_read" -eq 1 ] && [ "$mode" = "read" ]; }; then
      repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "$mode")"
      if [ -d "$repo_dir/.git" ] && [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
        dirty_found=1
        dirty_repos+=("${REPO_NAMES[$i]} ($repo_dir)")
      fi
    fi
  done

  if git -C . rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$(git -C . status --porcelain 2>/dev/null)" ]; then
      dirty_found=1
      dirty_repos+=("meta-context repo (.)")
    fi
  fi

  if [ "$dirty_found" -eq 1 ]; then
    die "Uncommitted changes found in: ${dirty_repos[*]}. Commit, stash, or discard them and run branch again."
  fi

  GLOBAL_BRANCH="$branch_name"
  save_repos

  for i in "${!REPO_NAMES[@]}"; do
    mode="${REPO_MODES[$i]}"
    if [ "$mode" = "write" ] || { [ "$include_read" -eq 1 ] && [ "$mode" = "read" ]; }; then
      repo_dir="$(get_repo_dir "${REPO_NAMES[$i]}" "$mode")"
      switch_repo_branch "$repo_dir" "$branch_name"
    fi
  done

  switch_repo_branch "." "$branch_name"

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
    skill) cmd_skill "$@" ;;
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
