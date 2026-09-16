# This repository is published, not authored

Every file here is copied verbatim from the churner monorepo, which is where
it is edited, reviewed and tested:

| here | monorepo |
| --- | --- |
| `host/bootstrap.sh` | `infrastructure/customer/preview-stack/host/bootstrap.sh` |
| `host/reaper.sh` | `infrastructure/customer/preview-stack/host/reaper.sh` |
| `host/reaper.service` | `infrastructure/customer/preview-stack/host/reaper.service` |
| `host/reaper.timer` | `infrastructure/customer/preview-stack/host/reaper.timer` |
| `proxy/Caddyfile.tmpl` | `infrastructure/customer/preview-stack/proxy/Caddyfile.tmpl` |
| `README.md` | `infrastructure/customer/preview-stack/README.md` |
| `host/deploy-preview.sh` | `github-actions/preview-workflow/host/deploy-preview.sh` |
| `host/destroy-preview.sh` | `github-actions/preview-workflow/host/destroy-preview.sh` |

Do not patch them here: the next release overwrites the file, and the change
would never have run against the tests that execute these scripts against
shimmed `docker` / `aws` / `psql`.

This repository is PUBLIC on purpose. A preview host fetches `bootstrap.sh`
at boot, and the preview workflow fetches the two host scripts per run, with
a plain unauthenticated `curl` — no GitHub credential of any kind. Every one
of those fetches is verified against a SHA-256 the customer can read in their
own stack parameters and workflow, so the repository being public is not what
makes the bytes trustworthy; the digests are.

Released from churner monorepo commit `0b87c5c`.
