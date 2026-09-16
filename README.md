# Churner preview stack (customer-side)

The opt-in module of the Churner access stack (design spec §7). It provisions,
**in your AWS account, under your identity**, everything a per-PR preview
environment needs: a delegated DNS zone, a wildcard certificate, a load
balancer, one small preview host, a disposable Postgres, an image registry and
build project, and a GitHub Actions deployer role.

The rendering lives in `shared/access/preview-stack.ts`; these files are what
the host itself runs.

```
preview-stack/
  host/bootstrap.sh      first-boot setup, fetched and verified by UserData
  host/reaper.sh         hourly TTL sweep
  host/reaper.service    oneshot unit
  host/reaper.timer      hourly timer
  proxy/Caddyfile.tmpl   reverse-proxy config, rendered by bootstrap.sh
```

## The boundary

**This module grants Churner nothing.** Churner assumes only the
`churner-<project>` role from the base stack, whose statements are conditioned
on the `environment` tag you configured. Every resource here carries that same
tag, so Churner can read exactly what your capability table already allows and
no more. The deployer role is a GitHub Actions identity: it cannot reach
Churner's account, and Churner cannot assume it.

The deployer's own permissions are **exactly what the reference workflow
calls**, and nothing beyond it:

| It may | It may not |
|---|---|
| start the module's CodeBuild project and read its status | push an image — the build does that, under the build project's own service role |
| run `AWS-RunShellScript` on an instance tagged `churner-preview-host=true` | run a command anywhere else, or run any other document |
| find that instance (`ssm:DescribeInstanceInformation`) and read its command's result by id | list the account's commands, or read any other principal's |
| — | **read any secret**, or ask RDS anything |

**The deployer reads no secrets.** The database master password and your
application's secrets are read *on the host*, inside the script SSM runs,
under the host's own instance profile. That matters because this role is
assumed by **any pull request against the repository** — including one whose
only change is a workflow step that prints what it can read.

ECR push, `rds:DescribeDBInstances` and the Secrets Manager read were each
granted in an earlier draft and each removed once the workflow was written and
turned out not to call them.

## Applying the stack

### 1. Delegate the subdomain *while the stack is creating*

The ordering trips people up, because the output you need is not readable
until the thing that needs it has already succeeded:

1. Apply the stack. It creates a Route 53 hosted zone for `preview.<domain>`
   and requests an ACM certificate for `*.preview.<domain>`, validated by a
   record **in that new zone**.
2. **While it is still creating**, open the Route 53 console, find the new
   zone, and copy its four name servers.
3. Create an `NS` record for `preview` on the parent domain (wherever it is
   hosted — it need not be this account, or Route 53 at all) pointing at those
   four.
4. Validation completes and the stack finishes. Without step 3 it sits until
   the certificate request times out.

The `PreviewHostedZoneNameServers` output gives the same four values for
future reference.

### 2. Subnets must be public

`PreviewSubnetIds` wants **at least two public subnets in different
availability zones**. The module provisions no NAT gateway, and the host has
to reach the SSM endpoints, ECR, GitHub and Churner: in a private subnet with
no egress path it bootstraps into nothing and never registers with SSM. The
host is protected by its security group (inbound only from the load balancer,
on port 80) rather than by the absence of a route, and the database by its own
group plus `PubliclyAccessible: false`.

### 3. If the account already has a GitHub OIDC provider

An AWS account may hold only one OIDC provider per issuer. Set
`CreateOidcProvider=false` (Terraform: `preview_create_oidc_provider = false`)
and pass the existing ARN as `ExistingOidcProviderArn` /
`preview_existing_oidc_provider_arn`. Both renderings refuse the combination
"don't create one, and here's an empty ARN" up front rather than producing a
role nothing can assume.

### 4. Private repositories need a CodeBuild source credential

The module's CodeBuild project builds from your GitHub repository. For a
**private** repository, CodeBuild needs a source credential in that account,
once, out of band — neither CloudFormation nor Terraform can create one,
because the stack holds no GitHub token:

```
aws codebuild import-source-credentials \
  --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN --token <pat>
```

Skip it for a public repository. Without it, builds fail with an
authentication error rather than a missing-prerequisite one.

### 5. Store your Churner preview token

Create the secret named by the `PreviewTokenSecretName` output —
`<secretsPrefix>/churner-preview-token` — and put your project's preview token
in it (plain string, or JSON with a `token` key). The host's reaper reads it to
post `destroyed` events. The module does **not** create this secret: Churner
mints the token, and a stack that created it empty would look configured while
posting nothing.

## Script integrity

The host fetches `bootstrap.sh` at boot and runs it as root. That fetch is
pinned and verified:

- `PreviewScriptsBaseUrl` defaults to a **tag** (`refs/tags/v2`) on the public
  [`churner-ai/preview-stack`](https://github.com/churner-ai/preview-stack)
  repository, never a branch. Tags there are IMMUTABLE once published — `v1`
  goes on serving exactly the bytes every stack applied before this repo's
  fix round 1 (batch F) pins, forever; a script change cuts a NEW tag rather
  than re-pointing an old one, so a customer's `PreviewScriptsSha256` and the
  tag it names can never disagree. The host fetches with a plain
  unauthenticated `curl`, holding no GitHub credential of any kind, so the
  repository it reads from has to be public — the digests below, not the
  repository's visibility, are what make the bytes trustworthy.
- `PreviewScriptsSha256` is the SHA-256 of `bootstrap.sh`. UserData verifies
  the download against it **before** executing anything.
- `bootstrap.sh` carries pinned digests for everything it goes on to fetch:
  `reaper.sh`, both units, `Caddyfile.tmpl`, and the Caddy release tarball
  (SHA-512, as published by the Caddy project).

So the chain has one root of trust — a digest you can read in your own stack
parameters — and no unverified hop. Regenerate the digests with
`scripts/preview-stack-digests.sh`; a test asserts them against the files.

`CADDY_VERSION` is a single literal in `bootstrap.sh` with no environment
override, and it moves together with the two `SHA512_CADDY_*` digests. It must
stay at **2.11.0 or later**: reload-on-SIGUSR1, which is how a route change
reaches the running proxy, does not exist before that.

If you vendor these scripts, point `PreviewScriptsBaseUrl` at your copy and
re-pin `PreviewScriptsSha256` to match.

### Maintaining the tag

These files are AUTHORED in the private churner monorepo and PUBLISHED to
`churner-ai/preview-stack` by `scripts/release-preview-stack.sh`, which lays
them out so the one base URL above serves every fetch:

```
infrastructure/customer/preview-stack/host/bootstrap.sh    -> host/bootstrap.sh
infrastructure/customer/preview-stack/host/reaper.sh       -> host/reaper.sh
infrastructure/customer/preview-stack/host/reaper.service  -> host/reaper.service
infrastructure/customer/preview-stack/host/reaper.timer    -> host/reaper.timer
infrastructure/customer/preview-stack/proxy/Caddyfile.tmpl -> proxy/Caddyfile.tmpl
infrastructure/customer/preview-stack/README.md            -> README.md
github-actions/preview-workflow/host/deploy-preview.sh     -> host/deploy-preview.sh
github-actions/preview-workflow/host/destroy-preview.sh    -> host/destroy-preview.sh
```

**The tag currently in effect, `refs/tags/v2` on `churner-ai/preview-stack`,
must be cut from a release whose `bootstrap.sh` hashes to the
`PREVIEW_BOOTSTRAP_SHA256` the renderer ships.** As of fix round 1 (batch F,
M7) tags on this repository are IMMUTABLE — never re-cut, never moved —
so a script change cuts the NEXT tag (`v3`, then `v4`, ...) instead. The
release script checks all three pin sets against the bytes it is about to
tag and refuses both a mismatch AND an already-existing tag name, but
nothing can enforce the other half: no test can see what a git tag on a
remote points at. Skip the release entirely and the failure is silent in the
worst way — a host fetches the tag its stack parameter names, its digest
does not match, and every new preview host refuses to bootstrap until
someone cuts a release.

The digests inside `bootstrap.sh` have the same property in reverse: they are
checked against the working tree by CI, so an edit to `reaper.sh` without
`scripts/preview-stack-digests.sh --write` fails the build rather than the
host.

**Release order.** Three public repositories are published from this monorepo,
and one of them is a prerequisite of another:

1. `churner-ai/preview-stack@<tag>` — `scripts/release-preview-stack.sh`.
   FIRST, because it serves the bytes (3) pins. The digests baked into the
   monorepo (`PREVIEW_BOOTSTRAP_SHA256`, the table inside `bootstrap.sh`, and
   the workflow's two host-script pins) must already match, which the script
   checks before it cuts the tag — and the tag itself must not already exist,
   since tags here are immutable.
2. `churner-ai/report-preview@v1` — `scripts/release-report-preview.sh`.
   Independent of the other two; order among them does not matter. Still on
   `v1` — this batch published no change to what it serves, so there was
   nothing to cut a new tag for.
3. `churner-ai/preview-workflow@<tag>` — `scripts/release-preview-workflow.sh`,
   under the SAME tag name as (1). AFTER (1): its `env:` block pins the two
   host scripts by SHA-256, and a workflow whose pins name bytes no tag
   serves yet fails every run at `sha256sum -c`.

The monorepo itself needs **no** public tag: nothing fetches from it any more.

## The workflow contract

Your pull-request workflow assumes the deployer role via OIDC. Three things
have to be true or the assume fails:

```yaml
permissions:
  id-token: write          # required to mint the OIDC token
  contents: read
```

- **No `environment:` on the job.** An environment adds
  `:environment:<name>` to the token's `sub` claim, which no longer matches the
  `repo:<owner>/<repo>:pull_request` the role trusts.
- **Fork pull requests cannot assume the role**, by design. GitHub does not
  issue an id-token with write permissions to a workflow triggered by a fork's
  `pull_request`, and the trust policy would not accept one anyway. Previews
  for forks need a different, deliberately-reviewed mechanism; this module
  does not provide one.

### Container labels

The reaper's only durable record of a preview is the container itself. Run it
with all five labels:

```
docker run -d \
  --label churner.preview=true \
  --label churner.preview.pr=<pr number> \
  --label churner.preview.sha=<head sha> \
  --label churner.preview.expires_at=<ISO-8601 UTC, e.g. 2026-09-07T12:00:00Z> \
  --label churner.preview.db=preview_<pr> \
  ...
```

`expires_at` must be exactly `YYYY-MM-DDTHH:MM:SSZ`; anything else is skipped
with a warning rather than guessed at, and the preview is never reaped. `pr`
must be digits and `db` must be `[A-Za-z0-9_]+` — both reach a filesystem path
and a `DROP DATABASE`.

### Routes

Register a preview by writing one file into `/etc/caddy/preview-routes` and
reloading:

```
# /etc/caddy/preview-routes/pr-123.caddy
http://123.preview.example.com {
	reverse_proxy 127.0.0.1:31234
}
```

then `systemctl reload caddy`. The unit's `ExecReload` sends **SIGUSR1** —
`caddy reload` would POST to the admin API, which the Caddyfile turns off, and
would silently do nothing. The reaper removes `pr-<n>.caddy` and reloads the
same way.

## Tearing it down

The stack is disposable on purpose: the database has no deletion protection,
no backups, and `skip_final_snapshot`. Two things do not disappear cleanly:

- **The database secret.** Terraform sets `recovery_window_in_days = 0`, so it
  is deleted immediately. **CloudFormation does not** — the secret enters a
  30-day recovery window still holding its name, and a re-apply within that
  window fails with "a secret with this name is scheduled for deletion". Force
  it first:

  ```
  aws secretsmanager delete-secret \
    --secret-id <secretsPrefix>/preview-db --force-delete-without-recovery
  ```

- **The ECR repository** refuses to delete while it holds images. Empty it, or
  delete it with `--force`.
