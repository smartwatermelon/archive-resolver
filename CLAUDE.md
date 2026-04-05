# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Idempotent macOS script that creates `/etc/resolver/` overrides for archive.today and its mirror domains, routing them through a trusted DNS nameserver (Google DNS 8.8.8.8) to bypass Cloudflare 1.1.1.1 blocks. Single-file Bash project — `install.sh` is the entire codebase.

## Commands

```sh
# Lint (matches CI)
shellcheck --severity=warning install.sh

# Syntax check
bash -n install.sh

# Dry-run (requires macOS; no root needed)
sudo ./install.sh --dry-run --no-fetch

# Update mirrors from Wikipedia (no root)
./install.sh --update-mirrors --dry-run

# Install resolver files
sudo ./install.sh

# Uninstall
sudo ./install.sh --uninstall
```

## Architecture

**Single script (`install.sh`)** with two modes:

- `--update-mirrors`: Fetches Wikipedia API, extracts `<li>archive.TLD</li>` from the infobox, rewrites `mirrors.txt`. No root needed.
- Default (install): Reads `mirrors.txt` (fetched from GitHub, or local with `--no-fetch`), writes `/etc/resolver/archive.today` with the nameserver, symlinks all other mirrors to that file, removes stale entries via manifest at `/etc/resolver/.archive-resolver`.

**Key design**: Mirror symlinks point to the filename `archive.today` (relative, not absolute path) so changing the nameserver only requires updating one file.

**`mirrors.txt`** is auto-updated by CI, not a static canonical list. The `update-mirrors.yml` workflow runs monthly, compares sorted sets (order-insensitive), and opens a PR if domains changed.

## Release process

1. Bump `SCRIPT_VERSION` in `install.sh`
2. Push on a release branch, merge to main
3. Tag `vMAJOR.MINOR.PATCH` on main — must match `SCRIPT_VERSION`
4. `release.yml` creates GitHub release with tarball + individual assets

## CI workflows

- **ci.yml**: ShellCheck, bash syntax, mirrors.txt format validation, Linux dry-run (stubs out Darwin check)
- **release.yml**: Validates tag matches `SCRIPT_VERSION`, lints, publishes release
- **update-mirrors.yml**: Monthly Wikipedia scrape, opens PR if mirror set changed

## Conventions

- All log functions (`info`/`success`/`warn`/`error`) write to stderr so `$()` captures work correctly
- `MANAGED_MARKER` comment in resolver files marks them as script-owned
- Comparison of mirror lists is set-based (sorted), not order-based
- Quad9 (9.9.9.9) is blocked by archive.today — do not use as example nameserver
- Script requires GNU Bash features (`mapfile`, `set -euo pipefail`)

## Headroom Learned Patterns

### Pre-commit Hooks

- A global pre-commit config exists at `/Users/andrewrich/.config/pre-commit/config.yaml` and runs on every `git commit`, including shellcheck for shell scripts.
- Run `shellcheck --severity=warning <file>` before committing any `.sh` file to catch issues pre-emptively.

### PR Merge Workflow

- Merging PRs requires a local authorization step: `~/.claude/hooks/merge-lock.sh authorize <PR#> "<title>"` before running `gh pr merge`.

### Git Workflow

- Branch naming: `claude/feature-<description>-<YYYYMMDD>` and `claude/release-<version>-<YYYYMMDD>`.
- Releases: separate release branch, bump version in `install.sh`, push, let user merge, then tag on main.

### Wikipedia API

- Direct `WebFetch` to `en.wikipedia.org` returns 403. Use the MediaWiki API: `curl 'https://en.wikipedia.org/w/api.php?action=parse&page=<PageName>&prop=text&format=json'`.

### macOS DNS Resolver

- DNS resolver overrides go under `/etc/resolver/` as per-domain files.
- Flush DNS: `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`.
