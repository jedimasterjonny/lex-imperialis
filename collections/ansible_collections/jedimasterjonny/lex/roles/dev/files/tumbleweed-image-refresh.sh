#!/usr/bin/env bash
set -euo pipefail

url="https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2"
dest="/var/lib/libvirt/images/tumbleweed-base.qcow2"

expected=$(curl -fsSL "${url}.sha256" | awk '{print $1}')

if [[ -f "$dest" ]]; then
  actual=$(sha256sum "$dest" | awk '{print $1}')
  if [[ "$actual" == "$expected" ]]; then
    echo "Image already up to date (sha256: $actual)"
    exit 0
  fi
fi

tmp=$(mktemp "${dest}.XXXXXX")
trap 'rm -f "$tmp"' EXIT
curl -fsSL "$url" -o "$tmp"
actual=$(sha256sum "$tmp" | awk '{print $1}')
if [[ "$actual" != "$expected" ]]; then
  echo "Checksum mismatch: expected $expected, got $actual" >&2
  exit 1
fi
chmod 0644 "$tmp"
# Don't chown explicitly: /var/lib/libvirt/images is `2775 root:libvirt`
# (setgid), so files created here inherit group `libvirt` — which qemu needs
# to read the image. A literal `chown root:root` would defeat that, and any
# future hardening of the parent dir (e.g. dropping world-read to mode 2770)
# would silently lock qemu out of just this file.
mv "$tmp" "$dest"
echo "Image refreshed (sha256: $actual)"
