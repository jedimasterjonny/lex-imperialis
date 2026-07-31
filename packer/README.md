# packer

Builds rogue-trader's openSUSE MicroOS ContainerHost snapshot. Hetzner ships no
MicroOS image, so this produces one.

The build is not wired into CI, deliberately: it bills real servers, needs a
token that can create and delete them, and runs perhaps twice a year. Only
`packer fmt` and `packer validate` run as gates. `packer/` is also kept out of
`discover`'s shared-path allowlist in `.github/workflows/molecule.yml`: inside
it, every PR here would book a hetzner `motd` VM for a run that tests nothing.
A PR touching `bin/*.sh` or `bootstrap/` still books one through those entries.

## Two stages, in order

The halves need different machine states, so there is no single pass: the disk
can only be written from rescue, and `transactional-update` only works on a
running system.

| Stage | Runs on | Does |
| --- | --- | --- |
| `stage1-base` | Hetzner rescue | Writes the MicroOS qcow2 to the disk, points `ignition.platform.id` at Hetzner. Snapshot labelled `custom_image=microos-base`. |
| `stage2-containerhost` | stage 1's snapshot, booted normally | Installs what the fleet roles need, reboots, strips machine identity. Snapshot labelled `custom_image=microos-containerhost`. |

Terraform will select the result by its `custom_image=microos-containerhost`
label, never by id, so a rebuild needs no lookup and nothing here carries a
snapshot reference that rots. Nothing consumes it yet.

## Running it

```sh
make image
```

Both stages against the emmas-edit project — Hetzner snapshots are
project-scoped, so an image built elsewhere is invisible to rogue-trader.
`bin/packer.sh` generates the throwaway build keypair, reads the API token from
the vault (so `.vault_pass` must be present) and runs the stages in order; `fmt`
and `validate` are the same script's other verbs, behind the same binary guard.
A first run on a machine fetches ~62 MB of packer plugins.

Nothing garbage-collects the snapshots, and `most_recent = true` hides the
build-up. `microos-base` has no consumer once stage 2 succeeds, so prune both
after a good build:

```sh
hcloud image list --type snapshot --selector custom_image
hcloud image delete <id>
```

## Measured on the built image

Established on a running box, not inferred:

- `ansible_facts['distribution']` is `openSUSE MicroOS`, so `roles/podman`
  resolves `podman_runtime` to `runc`, which the image ships.
- `community.general.zypper` does wrap `transactional-update` — shown by the
  snapshot chain it leaves, which a direct zypper on a read-only root could not
  produce.
- A 40 GB snapshot restores onto an 80 GB server and grows to fill it, on both
  the create and the `hcloud server rebuild` path.

The package lists are fixed as at build time. A role that later gains a package
leaves the snapshot stale, and nothing detects it — the cost is a transactional
install and a forced reboot part-way through a converge on the live box, so
rebuild the image when the roles on rogue-trader change what they install.

## Gotchas

- **`packer` on this workstation is not HashiCorp Packer** — openSUSE's cracklib
  owns `/usr/sbin/packer`. Install the real one earlier on `PATH` or set
  `PACKER`; `bin/packer.sh` guards it and says why.
- **Why the build needs a keypair at all:** the image has no cloud-init, which is
  what performs Hetzner's `ssh_keys` injection, so the key reaches the box only
  through the Ignition config packer passes as `user_data`. `bin/packer.sh`
  generates a throwaway pair per run; it cannot reuse one of yours.
- **Stage 2's pre-Python reboot must not be detached**, and identity clearing
  must stay last. Test any change to either on a **cold-start** box — one that
  already has Python, or already has an identity, cannot fail them.
- **Neither playbook is idempotent**, by design: stage 1 overwrites a block
  device, stage 2 deletes the machine's identity. `ansible.cfg` points at
  `inventory/`, so both assert they are running against packer's build server
  before touching anything.
