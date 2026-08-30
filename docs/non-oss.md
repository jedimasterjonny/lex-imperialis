# Non-OSS software

The estate runs open source by default: where a maintained OSS option exists it
is taken — OpenTofu rather than Terraform's BUSL, Valkey's BSD rather than
Redis's AGPL — and the non-OSS package repositories are held disabled
(below). This page is the complete register of the exceptions, each deliberate.
Anything non-OSS and not listed here is a finding, not an accepted cost.

Derived from the fleet-wide licence audit of 2026-08-03 — every RPM, container
image and hand-installed binary, inspected live — and refreshed against the
fleet on 2026-08-30. The audit archive lives outside the repo.

## Exceptions

| What | Where | Licence | Why it stays |
| --- | --- | --- | --- |
| Plex Media Server | `solar`, `arr` role container | proprietary EULA, inside a GPL-3.0 LSIO wrapper | The media server of choice. |
| Claude Code | `scholam`, `dev` role | Anthropic proprietary | The authoring tool this repo is built around. |
| Headless Chrome | `scholam`, fetched by puppeteer into `~/.cache/puppeteer`; the `dev` role installs only its shared libraries | Google freeware (Chrome for Testing, not Chromium) | Rides with Claude Code, whose browser automation fetches and prefers its own pinned build; no supported override exists, so a system Chromium cannot be swapped in. |
| HashiCorp Packer | `scholam`, hand-installed — see `packer/README.md` | BUSL-1.1 | Decided 2026-08-04: no viable OSS fork exists (nothing like OpenTofu), both plugins the build uses are MPL-2.0, and the Additional Use Grant covers this use. `bin/packer.sh` asserts the binary against the renovate pin. |
| google-cloud-cli | `scholam`, `dev` role | Apache-2.0 code, Google Cloud ToS in practice | Authenticates local `tofu` runs against the GCS state backend. |
| Firmware blobs | `kernel-firmware-*` and `ucode-intel` on the Beelinks (`SUSE-Firmware`); seven `non-free-firmware` packages on `auspex`, `raspi-firmware` among them | redistributable binary, no source | Unavoidable on bare metal; a Pi 5 does not boot without `raspi-firmware`. |

Transitive and trivial: `man-pages-posix` (`SUSE-IEEE`) rides in as
documentation.

Two vendor appliances sit beside the fleet, outside Ansible: the Synology NAS
runs DSM, proprietary throughout, and the network gear runs Ubiquiti's UniFi
OS. Both are the hardware's to keep.

## Held disabled

- The three openSUSE hosts keep the NON-OSS and openh264 repositories disabled —
  `common_disabled_repos` in `roles/common`, declare-and-disable, with zero
  packages ever found installed from either. The role README covers why
  `zypper_repository` cannot do the job.
- `auspex` keeps Raspberry Pi OS's stock apt components, `non-free-firmware`
  included: the boot firmware comes from there, and the firmware packages above
  are all it draws from them.
