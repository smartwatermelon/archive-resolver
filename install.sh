#!/usr/bin/env bash
# archive-resolver: Configure macOS DNS overrides for archive.today and its mirrors.
#
# archive.today (and mirrors) deny access to users on certain DNS providers (notably
# Cloudflare 1.1.1.1). This script adds per-domain resolver entries under
# /etc/resolver so macOS routes only those domains through a trusted nameserver.
#
# Usage:  ./install.sh --update-mirrors    # Update mirrors.txt from Wikipedia (no root)
#         sudo ./install.sh                # Install / update resolver files
#
# The script is idempotent: re-running it adds missing entries, updates changed
# entries, and removes entries for domains no longer in the mirrors list.
#
# Requires: macOS, curl (for network operations), python3 (bundled on macOS)
# Root is required only for install/uninstall, not for --update-mirrors.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SCRIPT_NAME="archive-resolver"
readonly SCRIPT_VERSION="1.0.0"
readonly RESOLVER_DIR="/etc/resolver"
readonly MANIFEST_FILE="${RESOLVER_DIR}/.${SCRIPT_NAME}"
readonly MANAGED_MARKER="managed-by: ${SCRIPT_NAME}"
readonly WIKIPEDIA_API="https://en.wikipedia.org/w/api.php?action=parse&page=Archive.today&prop=text&format=json"
readonly REPO_URL="https://github.com/smartwatermelon/archive-resolver"

# Remote source for the mirrors list (used as install-time fallback).
readonly MIRRORS_URL="${REPO_URL}/raw/main/mirrors.txt"

# Path to mirrors.txt alongside this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOCAL_MIRRORS_FILE="${SCRIPT_DIR}/mirrors.txt"

# ---------------------------------------------------------------------------
# Defaults (overridable via flags)
# ---------------------------------------------------------------------------
NAMESERVER="8.8.8.8"
FETCH_MIRRORS=true
DRY_RUN=false
UNINSTALL=false
UPDATE_MIRRORS=false
YES=false

# ---------------------------------------------------------------------------
# Colours (suppressed when stdout is not a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  CYAN=''
  BOLD=''
  RESET=''
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info() { echo -e "${CYAN}[info]${RESET}  $*" >&2; }
success() { echo -e "${GREEN}[ok]${RESET}    $*" >&2; }
warn() { echo -e "${YELLOW}[warn]${RESET}  $*" >&2; }
error() { echo -e "${RED}[error]${RESET} $*" >&2; }
fatal() {
  error "$*"
  exit 1
}

header() {
  echo -e "\n${BOLD}${SCRIPT_NAME} v${SCRIPT_VERSION}${RESET}" >&2
  echo "─────────────────────────────────────────" >&2
}

usage() {
  cat <<EOF
Usage:
  ./install.sh --update-mirrors        Update mirrors.txt from Wikipedia (no root needed)
  sudo ./install.sh                    Install / update resolver files
  sudo ./install.sh --uninstall        Remove all managed resolver files

Options:
  -m, --update-mirrors   Fetch current mirror list from Wikipedia and update mirrors.txt
  -y, --yes              Non-interactive: skip confirmation prompts (use with --update-mirrors)
  -n, --nameserver IP    Nameserver for archive domains (default: 8.8.8.8)
  -f, --no-fetch         Use local mirrors.txt; skip fetching from GitHub
  -d, --dry-run          Show planned changes without applying them
  -u, --uninstall        Remove all resolver files managed by ${SCRIPT_NAME}
  -h, --help             Show this message

Examples:
  ./install.sh --update-mirrors        # Refresh mirrors.txt from Wikipedia
  ./install.sh --update-mirrors --dry-run   # Preview mirror list changes only
  sudo ./install.sh                    # Install (fetches mirrors.txt from GitHub)
  sudo ./install.sh --no-fetch         # Install using bundled mirrors.txt (offline)
  sudo ./install.sh --nameserver 8.8.4.4   # Use alternate Google DNS
  sudo ./install.sh --uninstall        # Remove everything
  sudo ./install.sh --dry-run          # Preview resolver changes

Workflow for updating the mirror list and re-installing in one shot:
  ./install.sh --update-mirrors && sudo ./install.sh --no-fetch
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m | --update-mirrors)
        UPDATE_MIRRORS=true
        shift
        ;;
      -y | --yes)
        YES=true
        shift
        ;;
      -n | --nameserver)
        [[ -z "${2:-}" ]] && fatal "--nameserver requires an IP address argument"
        NAMESERVER="$2"
        shift 2
        ;;
      -f | --no-fetch)
        FETCH_MIRRORS=false
        shift
        ;;
      -d | --dry-run)
        DRY_RUN=true
        shift
        ;;
      -u | --uninstall)
        UNINSTALL=true
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *) fatal "Unknown option: $1 (run with --help for usage)" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_os() {
  [[ "$(uname -s)" == "Darwin" ]] || fatal "This script only supports macOS."
}

check_root() {
  if [[ $DRY_RUN == false && $EUID -ne 0 ]]; then
    fatal "Root privileges required. Re-run with: sudo $0 ${*:-}"
  fi
}

check_resolver_dir() {
  if [[ ! -d "$RESOLVER_DIR" ]]; then
    if [[ $DRY_RUN == true ]]; then
      warn "[dry-run] Would create directory: ${RESOLVER_DIR}"
    else
      info "Creating ${RESOLVER_DIR}"
      mkdir -p "$RESOLVER_DIR"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Fetch mirror list from Wikipedia
# ---------------------------------------------------------------------------
# Queries the Wikipedia API for the Archive.today article and extracts the
# mirror domains from the infobox, where they appear as bare <li> elements:
#   <li>archive.today</li>
#   <li>archive.fo</li>  ... etc.
#
# This is intentionally precise to avoid false positives (e.g. archive.org,
# web.archive.org) that also appear in the article body as references.
# Returns domains one per line, archive.today first.
fetch_mirrors_from_wikipedia() {
  local url="$WIKIPEDIA_API"
  local json domains

  info "Fetching Wikipedia article: Archive.today"
  if ! json="$(curl --silent --fail --max-time 20 --location "$url" 2>/dev/null)"; then
    warn "Could not reach Wikipedia API"
    return 1
  fi

  # python3 is bundled on macOS and required for JSON parsing.
  if ! command -v python3 &>/dev/null; then
    warn "python3 not found — required to parse Wikipedia API response"
    return 1
  fi

  # Extract domains from <li>archive.*</li> elements in the infobox.
  # These are the only place in the article where the mirrors appear as
  # bare domain names without surrounding text.
  domains="$(printf '%s' "$json" | python3 -c "
import sys, json, re
try:
    html = json.load(sys.stdin)['parse']['text']['*']
except Exception:
    sys.exit(1)
# Match <li>archive.TLD</li> where TLD is 2-6 lowercase letters.
# This targets the infobox domain list and nothing else.
found = re.findall(r'<li>(archive\.[a-z]{2,6})</li>', html)
# Deduplicate while preserving order.
seen = set()
for d in found:
    if d not in seen:
        seen.add(d)
        print(d)
")" || {
    warn "Failed to extract domains from Wikipedia article"
    return 1
  }

  if [[ -z "$domains" ]]; then
    warn "No mirror domains found in Wikipedia article infobox"
    return 1
  fi

  # Ensure archive.today is first (it is always the primary domain).
  # If it was not already first, move it there.
  local rest
  rest="$(printf '%s\n' "$domains" | grep -v '^archive\.today$')"
  printf 'archive.today\n'
  [[ -n "$rest" ]] && printf '%s\n' "$rest"
}

# ---------------------------------------------------------------------------
# Update mirrors.txt from Wikipedia
# ---------------------------------------------------------------------------
do_update_mirrors() {
  local raw
  local -a new_domains current_domains

  if ! raw="$(fetch_mirrors_from_wikipedia)"; then
    fatal "Could not fetch mirror list from Wikipedia."
  fi

  mapfile -t new_domains < <(printf '%s\n' "$raw")

  if [[ ${#new_domains[@]} -eq 0 || -z "${new_domains[0]:-}" ]]; then
    fatal "Wikipedia returned an empty domain list."
  fi

  # Read current list for comparison
  if [[ -f "$LOCAL_MIRRORS_FILE" ]]; then
    mapfile -t current_domains < <(parse_mirrors_file "$LOCAL_MIRRORS_FILE")
  else
    current_domains=()
  fi

  # Compare as sorted sets: ordering differences do not constitute an update.
  # The primary domain (archive.today) must always be first, but the rest
  # can appear in any order without requiring a rewrite.
  local new_sorted current_sorted
  new_sorted="$(printf '%s\n' "${new_domains[@]}" | sort)"
  current_sorted="$(printf '%s\n' "${current_domains[@]:-}" | sort)"

  if [[ "$new_sorted" == "$current_sorted" ]]; then
    success "mirrors.txt is already up to date (${#new_domains[@]} domains)."
    return 0
  fi

  # Show set-level additions and removals only
  info "Changes detected:"
  diff <(printf '%s\n' "${current_domains[@]:-}" | sort) \
    <(printf '%s\n' "${new_domains[@]}" | sort) \
    | grep '^[<>]' \
    | sed 's|^< |  removed: |; s|^> |  added:   |' >&2 || true
  echo >&2

  if [[ $DRY_RUN == true ]]; then
    info "[dry-run] Would update: ${LOCAL_MIRRORS_FILE}"
    return 0
  fi

  # Confirm unless --yes or non-interactive
  if [[ $YES == false && -t 0 ]]; then
    local response
    read -r -p "Update mirrors.txt? [y/N] " response
    [[ "$response" =~ ^[Yy] ]] || {
      info "Aborted."
      return 0
    }
  fi

  {
    echo "# archive-resolver mirror list"
    echo "# Format: one domain per line. Lines starting with # are comments."
    echo "# The first non-comment line is the primary domain (others become symlinks)."
    echo "#"
    echo "# Source: https://en.wikipedia.org/wiki/Archive.today"
    echo "# Updated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "${new_domains[@]}"
  } >"$LOCAL_MIRRORS_FILE"

  success "Updated mirrors.txt (${#new_domains[@]} domains)."
  echo >&2
  info "To apply the updated list, run: sudo ./install.sh --no-fetch"
}

# ---------------------------------------------------------------------------
# Mirror list: fetch from repo → local file → exit with error
# ---------------------------------------------------------------------------
fetch_mirrors_from_url() {
  local tmp
  tmp="$(mktemp)"
  if curl --silent --fail --max-time 10 --location "$MIRRORS_URL" -o "$tmp" 2>/dev/null; then
    if grep -qE '^[^#[:space:]]' "$tmp"; then
      cat "$tmp"
      rm -f "$tmp"
      return 0
    fi
  fi
  rm -f "$tmp"
  return 1
}

parse_mirrors_file() {
  local file="$1"
  grep -E '^[^#[:space:]]' "$file" | sed 's/[[:space:]].*//' || true
}

get_desired_mirrors() {
  if [[ $FETCH_MIRRORS == true ]]; then
    info "Fetching mirror list from ${MIRRORS_URL}"
    local raw
    if raw="$(fetch_mirrors_from_url)"; then
      success "Fetched mirror list"
      printf '%s\n' "$raw" | grep -E '^[^#[:space:]]' | sed 's/[[:space:]].*//'
      return
    else
      warn "Fetch failed — falling back to local mirrors.txt"
    fi
  fi

  if [[ -f "$LOCAL_MIRRORS_FILE" ]]; then
    info "Using local mirror list: ${LOCAL_MIRRORS_FILE}"
    parse_mirrors_file "$LOCAL_MIRRORS_FILE"
    return
  fi

  fatal "No mirror list available. Run --update-mirrors first, or use --no-fetch with a local mirrors.txt."
}

# ---------------------------------------------------------------------------
# Manifest: tracks which domains this script manages
# ---------------------------------------------------------------------------
read_manifest() {
  if [[ -f "$MANIFEST_FILE" ]]; then
    grep -E '^[^#[:space:]]' "$MANIFEST_FILE" || true
  fi
}

write_manifest() {
  local -a domains=("$@")
  if [[ $DRY_RUN == true ]]; then
    info "[dry-run] Would write manifest: ${MANIFEST_FILE}"
    return
  fi
  {
    echo "# ${MANAGED_MARKER}"
    echo "# Updated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "${domains[@]}"
  } >"$MANIFEST_FILE"
}

# ---------------------------------------------------------------------------
# Resolver file helpers
# ---------------------------------------------------------------------------
resolver_content() {
  printf '# %s\n# nameserver: %s\nnameserver %s\n' \
    "$MANAGED_MARKER" "$1" "$1"
}

is_managed() {
  local file="$1"
  [[ -f "$file" ]] && grep -q "$MANAGED_MARKER" "$file"
}

is_correct_symlink() {
  local link="$1" target="$2"
  [[ -L "$link" ]] && [[ "$(readlink "$link")" == "$target" ]]
}

primary_is_current() {
  local file="$1" nameserver="$2"
  [[ -f "$file" ]] && grep -q "^nameserver ${nameserver}$" "$file"
}

# ---------------------------------------------------------------------------
# Apply resolver changes
# ---------------------------------------------------------------------------
apply_install() {
  local -a desired=("$@")
  local primary="${desired[0]}"
  local primary_file="${RESOLVER_DIR}/${primary}"
  local changes=0

  # Primary domain: full resolver file
  if primary_is_current "$primary_file" "$NAMESERVER" && is_managed "$primary_file"; then
    success "Primary resolver up to date: ${primary}"
  else
    if [[ $DRY_RUN == true ]]; then
      info "[dry-run] Would write resolver: ${primary_file} → nameserver ${NAMESERVER}"
    else
      info "Writing resolver: ${primary_file}"
      resolver_content "$NAMESERVER" >"$primary_file"
      success "Wrote ${primary_file}"
    fi
    changes=$((changes + 1))
  fi

  # Mirror domains: symlinks → primary filename
  local i
  for ((i = 1; i < ${#desired[@]}; i++)); do
    local domain="${desired[$i]}"
    local link="${RESOLVER_DIR}/${domain}"

    if is_correct_symlink "$link" "$primary"; then
      success "Symlink up to date: ${domain} → ${primary}"
    else
      if [[ $DRY_RUN == true ]]; then
        local action="create"
        [[ -e "$link" || -L "$link" ]] && action="replace"
        info "[dry-run] Would ${action} symlink: ${link} → ${primary}"
      else
        [[ -e "$link" || -L "$link" ]] && rm -f "$link"
        ln -s "$primary" "$link"
        success "Linked ${domain} → ${primary}"
      fi
      changes=$((changes + 1))
    fi
  done

  echo "$changes"
}

apply_removals() {
  local -a manifest=("$@")
  local changes=0

  local domain
  for domain in "${manifest[@]}"; do
    local keep=false
    local d
    for d in "${DESIRED_DOMAINS[@]}"; do
      [[ "$d" == "$domain" ]] && keep=true && break
    done

    if [[ $keep == false ]]; then
      local file="${RESOLVER_DIR}/${domain}"
      if [[ $DRY_RUN == true ]]; then
        info "[dry-run] Would remove stale entry: ${file}"
      else
        info "Removing stale entry: ${file}"
        rm -f "$file"
        success "Removed ${file}"
      fi
      changes=$((changes + 1))
    fi
  done

  echo "$changes"
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  info "Uninstalling ${SCRIPT_NAME}..."
  local -a managed
  mapfile -t managed < <(read_manifest)

  if [[ ${#managed[@]} -eq 0 ]]; then
    warn "No managed resolver files found (manifest missing or empty)."
    return
  fi

  local count=0
  local domain
  for domain in "${managed[@]}"; do
    local file="${RESOLVER_DIR}/${domain}"
    if [[ $DRY_RUN == true ]]; then
      info "[dry-run] Would remove: ${file}"
    elif [[ -e "$file" || -L "$file" ]]; then
      rm -f "$file"
      success "Removed ${file}"
      count=$((count + 1))
    fi
  done

  if [[ $DRY_RUN == true ]]; then
    info "[dry-run] Would remove manifest: ${MANIFEST_FILE}"
  else
    rm -f "$MANIFEST_FILE"
    success "Removed manifest"
  fi

  flush_dns
  echo >&2
  success "Uninstalled ${count} resolver entries."
}

# ---------------------------------------------------------------------------
# DNS cache flush
# ---------------------------------------------------------------------------
flush_dns() {
  if [[ $DRY_RUN == true ]]; then
    info "[dry-run] Would flush DNS cache"
    return
  fi
  info "Flushing DNS cache..."
  dscacheutil -flushcache
  killall -HUP mDNSResponder 2>/dev/null || true
  success "DNS cache flushed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  header
  check_os

  # --update-mirrors does not require root; handle it before the root check.
  if [[ $UPDATE_MIRRORS == true ]]; then
    do_update_mirrors
    exit 0
  fi

  check_root "$@"

  if [[ $UNINSTALL == true ]]; then
    check_resolver_dir
    do_uninstall
    exit 0
  fi

  check_resolver_dir

  mapfile -t DESIRED_DOMAINS < <(get_desired_mirrors)
  export DESIRED_DOMAINS

  if [[ ${#DESIRED_DOMAINS[@]} -eq 0 ]]; then
    fatal "Mirror list is empty. Cannot continue."
  fi

  local primary="${DESIRED_DOMAINS[0]}"
  info "Primary domain : ${primary}"
  info "Nameserver     : ${NAMESERVER}"
  info "Mirrors total  : ${#DESIRED_DOMAINS[@]}"
  echo >&2

  mapfile -t MANIFEST_DOMAINS < <(read_manifest)

  local install_changes removal_changes total_changes
  install_changes="$(apply_install "${DESIRED_DOMAINS[@]}")"
  removal_changes="$(apply_removals "${MANIFEST_DOMAINS[@]:-}")"
  total_changes=$((install_changes + removal_changes))

  if [[ $DRY_RUN == false ]]; then
    write_manifest "${DESIRED_DOMAINS[@]}"
  fi

  if [[ $total_changes -gt 0 ]]; then
    echo >&2
    flush_dns
  fi

  echo >&2
  if [[ $DRY_RUN == true ]]; then
    info "Dry run complete. ${total_changes} change(s) would be applied."
  elif [[ $total_changes -gt 0 ]]; then
    success "Done. ${total_changes} change(s) applied."
  else
    success "Already up to date. No changes needed."
  fi
}

main "$@"
