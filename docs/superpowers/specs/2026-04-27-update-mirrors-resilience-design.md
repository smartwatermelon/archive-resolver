# Update-mirrors Workflow Resilience

**Date**: 2026-04-27
**Status**: Approved, awaiting implementation
**Scope**: `.github/workflows/update-mirrors.yml` only

## Problem

The monthly `update-mirrors.yml` workflow extracts mirror domains from the
Wikipedia article *Archive.today* using the regex `<li>archive\.[a-z]{2,6}</li>`.
That regex targets the article's infobox sidebar list of mirror TLDs. Edit wars
on the article have removed the bare-domain list — the TLDs now appear only in
prose (e.g. `.TODAY .FO .LI .VN .MD .PH`), so the regex returns zero matches.

The current behaviour on zero matches is `exit 1`, which fails CI. The April
2026 scheduled run was the first to hit this; prior runs were green.

A subtler risk: if the regex were ever to start producing *partial* matches
(e.g. only some mirrors in `<li>` form after a future article rewrite), the
existing `[[ ! -s /tmp/new_domains.txt ]]` check would let a degraded list
through and the workflow would propose a PR that drops legitimate entries from
`mirrors.txt`.

## Goal

Operating principle (per stakeholder): **update if confident, never degrade.**

- The workflow must not fail CI when the Wikipedia source is missing or
  anomalous.
- `mirrors.txt` must never be overwritten with an extraction that fails sanity
  checks.
- The operator must receive a visible signal (a GitHub issue) when the source
  goes wrong, so this isn't a silent skip.
- Idempotent across monthly runs: repeated anomalies must not spawn duplicate
  issues.
- Best-effort, low-maintenance: this is an open-source side project, not a
  product.

Out of scope: `install.sh --update-mirrors` (separate concern; user-invoked,
already prints a clear error).

## Design

### Sanity checks

After extracting domains from the Wikipedia API response, validate the result
against three rules. **All three must pass** for the PR step to proceed.

| # | Rule                                                               | Rationale                                                                   |
|---|--------------------------------------------------------------------|-----------------------------------------------------------------------------|
| 1 | Result is non-empty                                                | Catches today's failure mode: parses fine but yields zero matches.          |
| 2 | Result contains `archive.today`                                    | The primary domain is structural. If it's missing, our extraction is wrong. |
| 3 | At most one domain currently in `mirrors.txt` is absent from the result | Mirrors have historically never been removed; any drop ≥ 2 is suspect.      |

If any check fails, the workflow takes the **anomaly path** (below) instead of
proposing a PR.

### Anomaly path

When sanity checks fail:

1. Print to the workflow log: which check tripped, the raw extracted set, and
   the count.
2. Look up open issues with the label `mirror-source-anomaly`:
   - **None open**: create one. Title `Mirror update workflow: source anomaly
     detected`. Body lists the failing check, the extracted domains, a link to
     the failing run, and a brief operator checklist (review the Wikipedia
     article, consider manual `mirrors.txt` update, consider alternative
     sources).
   - **One open**: post a dated comment summarising this run's result. Don't
     create a duplicate.
3. Skip the PR-creation step entirely; `mirrors.txt` is never touched.
4. Exit 0 — the GH Actions UI shows green; the *issue* is the signal.

The `mirror-source-anomaly` label is created lazily by the workflow if
missing (`gh label create --force`).

### Recovery path

On *every* healthy run (sanity checks pass):

1. Look up open issues with label `mirror-source-anomaly`.
2. For any found, post a comment ("source recovered on run #N"), then close.
3. Continue with the existing diff/PR logic.

When no anomaly issue is open this is a cheap no-op, so it's safe to run
unconditionally on the healthy path. This keeps the issue list self-clearing.

### Healthy path (unchanged)

When sanity checks pass and the sorted set differs from current `mirrors.txt`,
the existing PR-creation step runs as today. Title, body template, branch
naming, and labelling are not modified.

### Permissions

Add `issues: write` to the workflow's `permissions:` block. Existing
`contents: write` and `pull-requests: write` stay.

## What's NOT changing

- `install.sh --update-mirrors` — separate user-invoked path, fine as-is.
- `mirrors.txt` format and contents.
- The Python extraction regex — it's correct; the article is what changed.
  Loosening the regex risks false positives from article prose and runs counter
  to "never degrade."
- Cron schedule, `workflow_dispatch` inputs, dry-run behaviour, PR
  title/body when the healthy path runs.

## Testing

- **Local**: Pipe canned API JSON through the workflow's Python step (empty
  result, missing primary, missing 2+ existing mirrors, healthy result).
  Confirm each path produces the expected log output.
- **Smoke (`workflow_dispatch` with `dry_run: true`)**: Trigger against the
  current (broken) Wikipedia article. Should detect anomaly, print clearly,
  and *not* mutate state (dry-run protects issue creation as well).
- **Real**: After merge, the next scheduled run should open exactly one
  `mirror-source-anomaly` issue, then subsequent runs should comment on it
  rather than duplicate.

## Research appendix — alternative mirror-list sources

Documented for future reference, not implemented. Each candidate evaluated on:
freshness (how quickly it reflects reality), authority (signal quality),
false-positive risk, automation cost, infrastructure dependency.

### 1. Certificate Transparency logs (crt.sh)

Query crt.sh for certificates whose Subject Alternative Names include
`archive.<TLD>`, parse SANs, deduplicate.

- **Authority**: High when archive.today owns the cert directly. Reduced when
  Cloudflare-fronted (shared cert farms include unrelated SANs).
- **Freshness**: New certs appear within hours of issuance.
- **False positives**: Significant — Cloudflare's shared cert farms historically
  return long SAN lists. Requires filtering by issuer and SAN pattern.
- **Automation cost**: Moderate — JSON API exists; SAN parsing and deduping
  needed. Rate limits.
- **Infra dependency**: External free service; occasionally slow.
- **Verdict**: Best candidate for an authoritative cross-check, but the
  filtering logic is non-trivial and Cloudflare adds noise.

### 2. DNS probing of a bounded TLD space

For each candidate TLD in a fixed list (`{today, fo, is, li, md, ph, vn, …}`)
plus an enumeration of all 2–6 letter TLDs, resolve `archive.<TLD>` and
fingerprint the response (HTTP 200 + expected page hash, or DNS pointing to
archive.today's IP set).

- **Authority**: High for "does this exist" questions; lower for "is this
  endorsed by the project."
- **Freshness**: Real-time.
- **False positives**: Low if fingerprint is strict; high if you only check
  that the name resolves (squatters exist).
- **Automation cost**: Moderate. Bounded TLD enumeration is ~thousands of
  lookups; doable but slow on each run.
- **Infra dependency**: Public DNS, the archive itself.
- **Verdict**: Useful as a *validator* (prune dead mirrors from the existing
  list) but not a discoverer of unknowns unless paired with a TLD list.

### 3. archive.today's own site

Scrape archive.today's footer or about page for mirror references.

- **Authority**: Highest.
- **Freshness**: Whatever the site reflects.
- **Automation cost**: Low to moderate.
- **Infra dependency**: archive.today + Cloudflare. CI runners are likely
  challenged by Cloudflare's bot mitigation, *and* the entire reason this
  project exists is that archive.today is unreliable from default DNS.
- **Verdict**: Authoritative but operationally fragile from a CI runner.

### 4. Third-party filter lists / DNS allowlists

Browser-extension blocklists (uBlock Origin), public DNS resolvers (NextDNS,
Pi-hole community lists), and similar third-party catalogues sometimes
enumerate archive.today mirrors.

- **Authority**: Variable; depends on maintainer.
- **Freshness**: Variable.
- **False positives**: Possible; lists may include defunct or hostile mirrors.
- **Automation cost**: Low — most are plain-text URLs.
- **Infra dependency**: Each list's host.
- **Verdict**: Useful as a low-effort cross-reference, not as a primary source.

### 5. GitHub code search

Search GitHub for repositories that maintain similar mirror lists (resolver
scripts, browser extensions, archive helpers); aggregate their lists and look
for mirror domains that appear in ≥ N independent projects.

- **Authority**: Crowd-sourced.
- **Freshness**: Variable.
- **False positives**: Moderate.
- **Automation cost**: Moderate. Requires query design and de-duplication.
- **Infra dependency**: GitHub Search API rate limits.
- **Verdict**: Interesting for cross-validation; brittle as a primary feed.

### 6. Wayback Machine snapshots of Wikipedia

Fetch a pre-edit-war snapshot of the Archive.today Wikipedia article from the
Wayback Machine; run today's regex against it.

- **Authority**: As good as Wikipedia was on the snapshot date.
- **Freshness**: Frozen — only useful for backfill, not ongoing tracking.
- **Verdict**: One-time recovery tool, not a long-term source.

### 7. Manual curation (baseline)

Maintain `mirrors.txt` by hand; treat the workflow purely as a watchdog that
notifies on anomalies (which is essentially what this design produces when
Wikipedia stays broken).

- **Authority**: As good as the maintainer's diligence.
- **Cost**: Lowest; no infrastructure.
- **Verdict**: Likely the de-facto state for the foreseeable future. The
  list has 7 entries and changes rarely.

### Recommendation

Keep Wikipedia as the primary source. The proposed resilience hardening is
sufficient for now. If the `mirror-source-anomaly` issue persists across
multiple monthly runs without recovery, revisit crt.sh as a secondary
cross-check — it's the only candidate with both authoritative provenance and
machine-friendly access. Until then, manual curation is fine: the cost of a
yearly hand-edit is lower than the cost of maintaining multi-source consensus
logic.
