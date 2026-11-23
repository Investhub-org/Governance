# Publishing these docs to docs.investhub.org

The pages under `docs/site/governance/` are the mirror that [docs.investhub.org](https://docs.investhub.org) should serve. They are written for the public VitePress site in `Investhub-org/docs`. Cloudflare Pages project `investhub-docs` builds that repository's `main` branch (`npm run docs:build`, output `.vitepress/dist`). This file is an operator note. The sync script does not copy it.

## What the workflow does

`.github/workflows/sync-docs.yml` runs on a push to `main` that changes `docs/**` or the sync script, and on a manual run from `main`. It checks this repository out without stored credentials, checks `Investhub-org/docs` out with the token below, copies `docs/site/governance/*.md` onto `governance/` in that repository, and adds the Factory, Modules, Meetings, and Claims sidebar links if they are not there yet. If the tree differs, it pushes branch `sync/governance-docs` and opens a pull request. It does not push to `main` of either repository, and it does not merge.

The commit identity on that pull request is `governance-docs-sync`, with the GitHub noreply address `governance-docs-sync@users.noreply.github.com`. That address is a placeholder for the bot. It is not a person's mailbox.

## Secret Marcel adds

On **Investhub-org/Governance**, add a repository secret (Settings → Secrets and variables → Actions → Repository secrets). It is not an environment secret.

| Name | Value |
| --- | --- |
| `DOCS_SYNC_TOKEN` | A fine-grained personal access token, or a GitHub App installation token, whose only repository is `Investhub-org/docs`. |

Permissions on that token:

- Contents: Read and write
- Pull requests: Read and write

No other repository, and no administration permission. Do not commit the token, do not put it in `.env`, and do not paste it into a workflow file. The workflow reads `${{ secrets.DOCS_SYNC_TOKEN }}` and fails with a clear error when the secret is missing.

After the secret exists, a push to `main` that touches `docs/`, or a manual run of the workflow on `main`, opens the pull request. Merging that pull request is what Cloudflare Pages picks up. This repository's workflow does not deploy the site.
