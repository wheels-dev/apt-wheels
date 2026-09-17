#!/usr/bin/env python3
"""Replace a package stanza in an apt Packages index, keeping the file valid.

Why this exists
---------------
The publish path is incremental: it downloads the channel's current Packages
index, appends the stanza for the .deb it just downloaded, and re-signs. That
append-only behaviour is wrong for a *re-cut*, where a version is republished
with a different artifact. The channel ends up with TWO stanzas for the same
name-version:

    Package: wheels
    Version: 4.1.0
    Filename: pool/stable/w/wheels/wheels_4.1.0_all.deb
    Size: 114764828
    SHA256: 6bc9d8f8...

    Package: wheels
    Version: 4.1.0
    Filename: pool/stable/w/wheels/wheels_4.1.0_all.deb
    Size: 114770228
    SHA256: 6ddb239e...

Both point at the same pool path, but the pool object was overwritten by the
re-cut build, so only the second stanza describes the file actually served.
apt binds to the stale one and refuses the download:

    E: Failed to fetch .../wheels_4.1.0_all.deb
       File has unexpected size (114770228 != 114764828). Mirror sync in progress?

This rewrites the index so exactly one stanza exists per name-version: any prior
stanza for that pair is dropped and the new one is appended. Stanzas for other
versions are preserved byte-for-byte, including field order.

Usage:
    replace-package-stanza.py <Packages-file> <new-stanza-file>

The new stanza is read from <new-stanza-file> (the output of
`apt-ftparchive --arch <arch> packages <deb>`); its Package/Version fields
determine which existing stanzas are replaced.
"""
import sys


def parse_stanzas(text):
    """Split a Packages file into stanzas, preserving field order and text."""
    stanzas = []
    current = []
    for line in text.splitlines():
        if line.strip() == "":
            if current:
                stanzas.append(current)
                current = []
        else:
            current.append(line)
    if current:
        stanzas.append(current)
    return stanzas


def field_of(stanza, name):
    prefix = name + ":"
    for line in stanza:
        if line.startswith(prefix):
            return line[len(prefix):].strip()
    return None


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: replace-package-stanza.py <Packages-file> <new-stanza-file>")

    packages_path, stanza_path = sys.argv[1], sys.argv[2]
    new_stanza = [ln for ln in open(stanza_path, encoding="utf-8").read().splitlines() if ln.strip()]
    if not new_stanza:
        sys.exit("ERROR: new stanza is empty")

    name = field_of(new_stanza, "Package")
    version = field_of(new_stanza, "Version")
    if not name or not version:
        sys.exit("ERROR: new stanza is missing Package or Version")

    try:
        existing = open(packages_path, encoding="utf-8").read()
    except FileNotFoundError:
        existing = ""

    kept, removed = [], 0
    for stanza in parse_stanzas(existing):
        if field_of(stanza, "Package") == name and field_of(stanza, "Version") == version:
            removed += 1
            continue
        kept.append(stanza)

    # Rebuild with a single blank line between stanzas and a trailing newline.
    blocks = ["\n".join(s) for s in kept] + ["\n".join(new_stanza)]
    with open(packages_path, "w", encoding="utf-8") as handle:
        handle.write("\n\n".join(blocks) + "\n")

    print(f"  {name} {version}: replaced {removed} existing stanza(s), kept {len(kept)} other(s)")


if __name__ == "__main__":
    main()
