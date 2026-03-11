# archive-resolver

Fixes DNS-based access blocks to [archive.today](https://archive.today) and its mirrors on macOS.

## The problem

archive.today intentionally denies requests from users whose DNS resolves through certain providers — most notably **Cloudflare 1.1.1.1**. The dispute is over [EDNS Client Subnet](https://en.wikipedia.org/wiki/EDNS_Client_Subnet): archive.today's operator uses it for load balancing; Cloudflare refuses to send it on privacy grounds. The result is that anyone using Cloudflare DNS gets connection errors on every archive.today domain.

## The fix

macOS supports per-domain DNS resolver overrides via files in `/etc/resolver/`. This script creates one file per mirror domain, routing those domains through a public nameserver (Google DNS 8.8.8.8 by default) while leaving all other DNS traffic alone.

## Mirror domains

The mirror list is in [`mirrors.txt`](./mirrors.txt), updated monthly by a GitHub Actions workflow that reads the [Archive.today Wikipedia article](https://en.wikipedia.org/wiki/Archive.today). Current mirrors:

| Domain | Role |
|---|---|
| archive.today | Primary |
| archive.fo | Mirror |
| archive.is | Mirror (deprecated for new links, still active) |
| archive.li | Mirror |
| archive.md | Mirror |
| archive.ph | Mirror |
| archive.vn | Mirror |

## Requirements

- macOS 10.6+ (any version with `/etc/resolver` support)
- `sudo` / root access (for install/uninstall only)
- `curl` and `python3` (both ship with macOS)

## Quick install

```sh
git clone https://github.com/smartwatermelon/archive-resolver.git
cd archive-resolver
sudo ./install.sh
```

## Usage

```
./install.sh --update-mirrors        Update mirrors.txt from Wikipedia (no root needed)
sudo ./install.sh                    Install / update resolver files
sudo ./install.sh --uninstall        Remove all managed resolver files

Options:
  -m, --update-mirrors   Fetch current mirror list from Wikipedia and update mirrors.txt
  -y, --yes              Non-interactive: skip confirmation prompts
  -n, --nameserver IP    Nameserver for archive domains (default: 8.8.8.8)
  -f, --no-fetch         Use local mirrors.txt; skip fetching from GitHub
  -d, --dry-run          Show planned changes without applying them
  -u, --uninstall        Remove all resolver files managed by archive-resolver
  -h, --help             Show this message
```

### Examples

```sh
# Standard install / update (fetches latest mirrors.txt from GitHub)
sudo ./install.sh

# Preview what would change
sudo ./install.sh --dry-run

# Update mirrors.txt from Wikipedia, then install
./install.sh --update-mirrors && sudo ./install.sh --no-fetch

# Preview mirror list changes without writing anything
./install.sh --update-mirrors --dry-run

# Use alternate Google DNS server
sudo ./install.sh --nameserver 8.8.4.4

# Offline install (uses bundled mirrors.txt)
sudo ./install.sh --no-fetch

# Remove everything this script created
sudo ./install.sh --uninstall
```

## How it works

1. Reads `mirrors.txt` from this repository (or the local copy with `--no-fetch`).
2. Writes `/etc/resolver/archive.today` with `nameserver 8.8.8.8`.
3. Creates symlinks for every other mirror domain pointing at that file. Changing the nameserver only requires updating one place.
4. Removes any `/etc/resolver` entries from a previous run that are no longer in the mirror list, using a manifest at `/etc/resolver/.archive-resolver`.
5. Runs `dscacheutil -flushcache` and reloads `mDNSResponder`.

Re-running produces the same result. New mirrors are added, removed mirrors are cleaned up.

## Keeping the mirror list current

A workflow runs on the first Monday of every month. If the Wikipedia article's mirror list has changed, it opens a pull request with the updated `mirrors.txt`.

To pull an update locally without waiting for CI:

```sh
./install.sh --update-mirrors
```

This fetches the Wikipedia article and rewrites `mirrors.txt` if the mirror set has changed. Then run `sudo ./install.sh --no-fetch` to apply it.

## Updating

```sh
sudo ./install.sh
```

Fetches the latest `mirrors.txt` from this repository and updates `/etc/resolver` to match. No script update needed.

## Uninstalling

```sh
sudo ./install.sh --uninstall
```

Removes all resolver files this script created and flushes the DNS cache. System-wide DNS settings are not affected.

## Verifying it works

```sh
# List managed resolver files
ls -la /etc/resolver/archive.*

# Check that archive.today resolves
dscacheutil -q host -a name archive.today
```

## License

MIT — see [LICENSE.md](./LICENSE.md).
