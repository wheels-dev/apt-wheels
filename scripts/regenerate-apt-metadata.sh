#!/bin/bash
# Incrementally regenerates apt metadata for one dispatched distribution under
# dists/, then signs Release with GPG (detached → Release.gpg, inline →
# InRelease). Both signed forms are required: older apt clients read Release +
# Release.gpg, newer clients prefer InRelease.
#
# This is the incremental replacement for the old full-pool scan. The old flow
# ran `apt-ftparchive packages pool/<dist>` over EVERY historical .deb, which
# forced the workflow to re-download the whole pool (~18 GB, hundreds of files,
# ~15 min and growing) on every publish. Instead:
#
#   * the workflow slots the single new .deb into pool/<dist>/… and downloads
#     the channel's current Packages index into dists/<dist>/main/binary-*/,
#   * this script appends the new package's stanza (apt-ftparchive over just
#     that one .deb) to each architecture index, gzips, and regenerates Release
#     via `apt-ftparchive release` — which only needs the index files, not the
#     pool.
#
# A package of Architecture `all` is appended to BOTH binary-amd64 and
# binary-arm64 (apt-ftparchive includes `all` in every arch index, verified
# against the live repo); an arch-specific package lands only in its own index.
#
# Inputs (env vars):
#   GPG_PASSPHRASE  — passphrase for the imported signing key
#   GPG_KEY_ID      — long-form key ID (set by the workflow after `gpg --import`)
#   CHANNELS        — space-separated distributions (workflow passes the single
#                     dispatched channel; default "stable bleeding-edge")

set -euo pipefail

if [ -z "${GPG_KEY_ID:-}" ]; then
  echo "::error::GPG_KEY_ID is unset — sign step would default to an arbitrary secret key."
  exit 1
fi

ARCHITECTURES="amd64 arm64"
COMPONENTS="main"
DISTRIBUTIONS="${CHANNELS:-stable bleeding-edge}"

APT_CONF_TEMPLATE="templates/aptftparchive.conf"
if [ ! -f "$APT_CONF_TEMPLATE" ]; then
  echo "::error::Missing $APT_CONF_TEMPLATE — template is expected to ship in the bucket repo."
  exit 1
fi

# Scratch file for the stanza apt-ftparchive emits for the .deb being published.
TMP_STANZA=$(mktemp)
trap 'rm -f "$TMP_STANZA"' EXIT

for DIST in $DISTRIBUTIONS; do
  echo "── Incrementally updating dists/${DIST}/ ──"
  DIST_DIR="dists/${DIST}"
  mkdir -p "$DIST_DIR"
  mkdir -p "pool/${DIST}"

  # Only the just-slotted .deb is present locally (the pool is not synced).
  NEW_DEB=$(find "pool/${DIST}" -type f -name '*.deb' | head -1 || true)
  if [ -z "$NEW_DEB" ]; then
    echo "::warning::No .deb under pool/${DIST} — nothing to append; skipping."
    continue
  fi
  echo "  new package: ${NEW_DEB}"

  # The name/version this .deb declares. Taken from the package's own control
  # file rather than the filename so it matches what apt-ftparchive emits (and
  # keeps matching if nfpm ever changes its filename convention).
  NEW_PKG=$(dpkg-deb -f "$NEW_DEB" Package)
  NEW_VER=$(dpkg-deb -f "$NEW_DEB" Version)
  if [ -z "$NEW_PKG" ] || [ -z "$NEW_VER" ]; then
    echo "::error::Could not read Package/Version from ${NEW_DEB}"
    exit 1
  fi
  echo "  declared as: ${NEW_PKG} ${NEW_VER}"

  for COMPONENT in $COMPONENTS; do
    for ARCH in $ARCHITECTURES; do
      BIN_DIR="${DIST_DIR}/${COMPONENT}/binary-${ARCH}"
      mkdir -p "$BIN_DIR"

      # Existing index was downloaded by the workflow; first publish starts empty.
      [ -f "${BIN_DIR}/Packages" ] || : > "${BIN_DIR}/Packages"

      # Emit the new package's stanza. `--arch` matches the old full scan: an
      # `all` package is emitted for both arches, `amd64` only for binary-amd64
      # (arm64 yields an empty stanza, which is a no-op).
      apt-ftparchive --arch "$ARCH" packages "$NEW_DEB" > "${TMP_STANZA}"

      if [ -s "${TMP_STANZA}" ]; then
        # Replace rather than append. Appending is what produced two stanzas for
        # the same name-version when a version is re-cut with a different build;
        # both referenced the same pool path, but the stale one described the
        # previous artifact, so apt rejected the download with "File has
        # unexpected size". A no-op append for the arch that emits nothing keeps
        # the index unchanged.
        python3 "$(dirname "$0")/replace-package-stanza.py" \
          "${BIN_DIR}/Packages" "${TMP_STANZA}"
      fi

      gzip -9 --keep --force "${BIN_DIR}/Packages"
    done
  done

  # apt-ftparchive release emits the Release metadata from the index files in
  # dists/<dist>/ — it does not read pool/, so it works without the pool present.
  apt-ftparchive \
    -c "$APT_CONF_TEMPLATE" \
    -o "APT::FTPArchive::Release::Codename=${DIST}" \
    -o "APT::FTPArchive::Release::Suite=${DIST}" \
    release "$DIST_DIR" \
    > "${DIST_DIR}/Release"

  # Detached signature → Release.gpg (legacy clients).
  rm -f "${DIST_DIR}/Release.gpg" "${DIST_DIR}/InRelease"
  gpg --batch --yes \
    --pinentry-mode loopback \
    --passphrase "${GPG_PASSPHRASE:-}" \
    --default-key "$GPG_KEY_ID" \
    --armor --detach-sign \
    --output "${DIST_DIR}/Release.gpg" \
    "${DIST_DIR}/Release"

  # Inline-signed Release → InRelease (modern clients).
  gpg --batch --yes \
    --pinentry-mode loopback \
    --passphrase "${GPG_PASSPHRASE:-}" \
    --default-key "$GPG_KEY_ID" \
    --clearsign \
    --output "${DIST_DIR}/InRelease" \
    "${DIST_DIR}/Release"

  echo "  ✓ appended ${NEW_DEB}, Release + Release.gpg + InRelease written for ${DIST}"
done

echo "Done."
