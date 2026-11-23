#!/usr/bin/env bash
# Copy docs/site/governance into Investhub-org/docs and open a pull request.
# Expects a checkout of that repository at ./site, with credentials that can push.
# Does not print the token. Does not push to main.
set -euo pipefail

if [[ -z "${DOCS_SYNC_TOKEN:-}" ]]; then
  echo "::error::Repository secret DOCS_SYNC_TOKEN is unset. See docs/publishing.md."
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="${ROOT}/docs/site/governance"
SITE="${ROOT}/site"
DEST="${SITE}/governance"

if [[ ! -d "${SOURCE}" ]]; then
  echo "::error::Missing ${SOURCE}"
  exit 1
fi
if [[ ! -d "${SITE}/.git" ]]; then
  echo "::error::Expected a git checkout of Investhub-org/docs at ${SITE}"
  exit 1
fi

cd "${SITE}"
git fetch origin main
if git ls-remote --exit-code --heads origin sync/governance-docs >/dev/null 2>&1; then
  git fetch origin sync/governance-docs
fi
git checkout -B sync/governance-docs origin/main

mkdir -p "${DEST}"
find "${SOURCE}" -maxdepth 1 -type f -name '*.md' -exec cp {} "${DEST}/" \;

python3 - "${SITE}/.vitepress/config.ts" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
if "/governance/factory" in text:
    sys.exit(0)
needle = "{ text: 'Governance on-chain', link: '/governance/', collapsed: false },"
replacement = """{
        text: 'Governance on-chain',
        link: '/governance/',
        collapsed: false,
        items: [
          { text: 'Factory', link: '/governance/factory' },
          { text: 'Modules', link: '/governance/modules' },
          { text: 'Meetings', link: '/governance/meetings' },
          { text: 'Claims', link: '/governance/claims' },
        ],
      },"""
if needle not in text:
    print("sidebar marker not found; leaving .vitepress/config.ts unchanged", file=sys.stderr)
    sys.exit(0)
path.write_text(text.replace(needle, replacement, 1))
PY

git add governance .vitepress/config.ts
if git diff --cached --quiet; then
  echo "No documentation changes to sync."
  exit 0
fi

git config user.name "governance-docs-sync"
git config user.email "governance-docs-sync@users.noreply.github.com"
git commit -m "docs: sync governance pages from Investhub-org/Governance"

if git rev-parse --verify --quiet origin/sync/governance-docs >/dev/null; then
  git push --force-with-lease=refs/heads/sync/governance-docs:refs/remotes/origin/sync/governance-docs \
    origin HEAD:sync/governance-docs
else
  git push -u origin HEAD:sync/governance-docs
fi

existing="$(gh pr list --repo Investhub-org/docs --head sync/governance-docs --base main --json number --jq '.[0].number')"
if [[ -n "${existing}" && "${existing}" != "null" ]]; then
  echo "Updated existing pull request #${existing} on Investhub-org/docs"
  exit 0
fi

gh pr create \
  --repo Investhub-org/docs \
  --base main \
  --head sync/governance-docs \
  --title "docs: sync governance kit pages" \
  --body "Mirror of the governance kit pages from Investhub-org/Governance (factory, modules, meetings, claims). Cloudflare Pages project investhub-docs builds main. This pull request does not deploy by itself."
