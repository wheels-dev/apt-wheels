# apt-wheels

Source repository backing **<https://apt.wheels.dev>**, the native Debian/Ubuntu
package repository for the [Wheels](https://wheels.dev) CFML framework CLI.

This repo holds the static apt metadata tree plus the pooled `.deb` artifacts,
and is auto-deployed to Cloudflare Pages on every push to `main`. End users do:

```bash
# Stable channel
curl -fsSL https://apt.wheels.dev/wheels.gpg \
  | sudo tee /usr/share/keyrings/wheels.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/wheels.gpg] https://apt.wheels.dev stable main" \
  | sudo tee /etc/apt/sources.list.d/wheels.list
sudo apt update && sudo apt install wheels

# Bleeding-edge — distinct package name (`wheels-be`) so it coexists with stable
echo "deb [signed-by=/usr/share/keyrings/wheels.gpg] https://apt.wheels.dev bleeding-edge main" \
  | sudo tee /etc/apt/sources.list.d/wheels-be.list
sudo apt update && sudo apt install wheels-be
```

## How updates flow into this repo

Releases land in `wheels-dev/wheels` (or `wheels-dev/wheels-snapshots` for
bleeding-edge). The release workflow fires `repository_dispatch` here with
event type `wheels-released` and a `{version, channel}` payload. The receiver
at [`.github/workflows/wheels-released.yml`](.github/workflows/wheels-released.yml)
downloads the new `.deb` from the upstream GitHub Release, slots it into
`pool/<channel>/w/<pkg>/`, regenerates `Packages.gz` / `Release` / `InRelease`
via `apt-ftparchive`, signs with GPG, and commits the whole tree back.
Cloudflare Pages picks up the push and republishes within ~30s.

The receiver also supports `workflow_dispatch` for backfill / disaster-recovery
(re-add a missing version without waiting for a new release):

```bash
gh workflow run wheels-released.yml \
  --repo wheels-dev/apt-wheels \
  -f version=4.0.0 -f channel=stable
```

## Contents

| Path | Purpose |
|------|---------|
| `.github/workflows/wheels-released.yml` | Receiver workflow — fires on `repository_dispatch` from `wheels-dev/wheels`. |
| `scripts/regenerate-apt-metadata.sh` | Pure-bash wrapper around `apt-ftparchive` + `gpg`. Idempotent — re-reads the entire `pool/`, rewrites `dists/` from scratch. Safe to invoke by hand to repair a torn release. |
| `templates/aptftparchive.conf` | `apt-ftparchive` config (Origin, Label, Components, Architectures, compression). The wrapper script overrides Codename + Suite per-distribution at invocation time. |
| `index.html` | Plain-HTML landing page served at the apex. Shows the sources.list snippet so browsers hitting `apt.wheels.dev` see install instructions. |
| `wheels.gpg.placeholder` | Reminder file — **must be replaced with the real ASCII-armored public key** committed as `wheels.gpg` at the repo root before the first release publish. See "Operational setup" below. |
| `pool/` | Populated at first publish: `pool/<channel>/w/<pkg>/<pkg>_<v>_amd64.deb`. |
| `dists/` | Populated at first publish: `dists/<channel>/Release` + signatures + `main/binary-amd64/Packages.gz`. |

## Distribution layout (post-first-publish)

```
apt.wheels.dev/
├── wheels.gpg                       # ASCII-armored public key
├── dists/
│   ├── stable/
│   │   ├── Release
│   │   ├── Release.gpg
│   │   ├── InRelease                # inline-signed Release (preferred)
│   │   └── main/binary-amd64/
│   │       ├── Packages
│   │       └── Packages.gz
│   └── bleeding-edge/
│       └── ... (mirror of the stable tree)
└── pool/
    ├── stable/
    │   └── w/wheels/wheels_<v>_amd64.deb
    └── bleeding-edge/
        └── w/wheels-be/wheels-be_<v>_amd64.deb
```

## Package name & channel convention

| Channel | Package name | Pool path | `apt install` |
|---------|--------------|-----------|---------------|
| Stable | `wheels` | `pool/stable/w/wheels/` | `apt install wheels` |
| Bleeding-edge | `wheels-be` | `pool/bleeding-edge/w/wheels-be/` | `apt install wheels-be` |

Distinct package names mean stable and bleeding-edge can be installed
side-by-side on the same host — useful for users who want a working stable CLI
alongside a BE one for testing.

## Filename: `~`-form vs `.`-form

GitHub Releases silently rewrites `~` to `.` in uploaded asset filenames, so:

- On disk locally (nfpm output): `wheels-be_4.0.1~snapshot.1787_amd64.deb`
- GitHub Release URL: `wheels-be_4.0.1.snapshot.1787_amd64.deb`
- Pool path (this repo): `pool/bleeding-edge/w/wheels-be/wheels-be_4.0.1~snapshot.1787_amd64.deb`

The receiver workflow downloads using the `.`-form (the only form the GitHub
Release URL exposes), then renames to the canonical `~`-form before publishing
into the pool. The version field *inside* the `.deb` metadata always carries
`~`, so `dpkg --compare-versions` orders snapshot releases below the next GA
release correctly regardless of which form sits in `pool/`.

## Operational setup

Before this repo will publish a usable repository:

1. **GPG signing key** — generate a 4096-bit RSA key (or Ed25519) for
   `Wheels Distribution <hello@wheels.dev>`. Private key + passphrase go into
   1Password under `op://Wheels/wheels-linux-repo-signing/` (Wheels project
   vault on `my.1password.com` — **not** the PAI `op://Infrastructure/` vault).
   Public key (ASCII-armored) replaces `wheels.gpg.placeholder` with a
   committed `wheels.gpg` at the repo root. The same key is used by the
   parallel [`yum-wheels`](https://github.com/wheels-dev/yum-wheels) bucket.

2. **Cloudflare Pages** — create a Pages project pointing at this repo, bind
   the apex domain `apt.wheels.dev`. Build command is empty (the repo *is* the
   static site); output dir is `./`.

3. **CI secrets** at
   <https://github.com/wheels-dev/apt-wheels/settings/secrets/actions>:
   - `WHEELS_REPO_GPG_PRIVATE_KEY` — ASCII-armored private key
   - `WHEELS_REPO_GPG_PASSPHRASE` — passphrase

4. **Upstream dispatch token** — on `wheels-dev/wheels`, add
   `LINUX_REPO_DISPATCH_TOKEN` (fine-grained PAT with `actions: write` on this
   repo and on `wheels-dev/yum-wheels`). The release workflow's dispatch step
   skips silently when this secret is unset, so the wiring is safe to land
   before the secret exists.

5. **Smoke-test** — once the GPG key is in place and the secrets are set, run
   the receiver manually to backfill the current GA release:

   ```bash
   gh workflow run wheels-released.yml \
     --repo wheels-dev/apt-wheels \
     -f version=4.0.1 -f channel=stable
   ```

   Then verify on a fresh Debian/Ubuntu host:

   ```bash
   curl -fsSL https://apt.wheels.dev/wheels.gpg \
     | sudo tee /usr/share/keyrings/wheels.gpg >/dev/null
   echo "deb [signed-by=/usr/share/keyrings/wheels.gpg] https://apt.wheels.dev stable main" \
     | sudo tee /etc/apt/sources.list.d/wheels.list
   sudo apt update
   sudo apt-cache policy wheels    # should show the apt.wheels.dev origin
   sudo apt install wheels
   wheels --version
   ```

   `apt update` reports `Get:N https://apt.wheels.dev stable InRelease` on
   success. A `NO_PUBKEY` error means the public key at
   `/usr/share/keyrings/wheels.gpg` doesn't match the key the bucket signed
   with — verify with
   `gpg --no-default-keyring --keyring /usr/share/keyrings/wheels.gpg --list-keys`.

## Upstream source-of-truth

This repo was seeded from the templates at
[`wheels-dev/wheels` → `tools/distribution-drafts/apt-repo/`](https://github.com/wheels-dev/wheels/tree/develop/tools/distribution-drafts/apt-repo).
Material changes to the workflow / scripts / config should generally land in
the upstream template too, so the next-time-we-rebuild-this story stays clean.
See [issue #2605](https://github.com/wheels-dev/wheels/issues/2605) for the
Phase 2 rollout plan.

## License

MIT — see [LICENSE](LICENSE).
