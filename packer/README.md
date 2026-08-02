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
| `stage2-containerhost` | stage 1's snapshot, booted normally | Installs what the fleet roles need, reboots, deletes the superseded btrfs snapshots, strips machine identity. Snapshot labelled `custom_image=microos-containerhost`. |

`bootstrap/rogue-trader.yml` selects the result by its
`custom_image=microos-containerhost` label, never by id, so nothing carries a
snapshot reference that rots when the image is rebuilt.

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

- `ansible_facts['distribution']` is `openSUSE MicroOS`, which is what selects
  `autoupdate`'s transactional arm.
- `community.general.zypper` does wrap `transactional-update` — shown by the
  snapshot chain it leaves, which a direct zypper on a read-only root could not
  produce.
- A 40 GB snapshot restores onto an 80 GB server and grows to fill it, on both
  the create and the `hcloud server rebuild` path.

Stage 2 reads the package lists from the roles' own `defaults/`, so a role that
adds to one needs no edit here — but the built snapshot is still fixed as at
build time, and nothing detects that it has fallen behind. The cost is a
transactional install and a forced reboot part-way through a converge on the live
box, so rebuild the image when the roles on rogue-trader change what they
install.

Two blind spots, both silent. `vars_files` is a hand-maintained list of seven
roles, so a package installed by any other role `playbooks/rogue-trader.yml`
reaches — or by a role added to that play later — never lands in the image. And
it reads role `defaults/`, so a package list a play overrides in its `vars:` is
missed too. Neither bites today: every package that play installs comes from one
of the seven, and no play overrides a package list.

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
- **Ignition can only write where the initrd has mounted.** The initrd mounts
  the fstab entries carrying `x-initrd.mount` — `/etc`, `/root`, `/var` — and
  the snapshot around them is read-only, so a first-boot write under `/home`
  fails and fails the whole config: the user is created (that is `/etc`) and its
  `authorized_keys` is not, leaving a box with no sshd and no way in. Stage 2
  adds the option to `/home` for that reason. A config that only touches `/etc`
  or root's home — packer's own build identity — never sees it.
- **The identity lives in every btrfs snapshot, not just the booted one.**
  Ignition writes it at stage 1's first boot and each `transactional-update`
  branches a new snapshot off that, so stage 2 prunes back to the booted
  snapshot before it strips. Audit a built image from **rescue**, mounting the
  btrfs top level (`mount -o subvolid=5 /dev/sda3 /mnt`) — a normal boot runs
  firstboot, regenerates the machine id and the host keys, and masks the answer.
- **The build's journal lives outside the snapshots**, on `/var`, so neither the
  prune nor the identity readback reaches it — it shipped in the image until
  stage 2 was taught to remove it. On a booted host, any directory under
  `/var/log/journal` not named after that host's own machine id is a build's.
  Note the machine id is the DMI product UUID with the dashes dropped, so it is
  the server's and survives a rebuild; only the host keys are regenerated.
- **Neither playbook is idempotent**, by design: stage 1 overwrites a block
  device, stage 2 deletes the machine's identity. `ansible.cfg` points at
  `inventory/`, so both assert they are running against packer's build server
  before touching anything.
