# molecule

Shared, role-agnostic create/destroy playbooks for the three test tiers, driven
by `molecule_yml.platforms` so every role reuses them; converge and verify stay
with the role.

Each tier also owns a `base.yml`: the provisioner config its scenarios would
otherwise all repeat — the create/destroy paths above, `roles_path`, and
whatever else the tier decides (the incus connection, hetzner's vault password
file and SSH transfer method). Molecule deep-merges it under a scenario's
`molecule.yml`, which is therefore just that scenario's `platforms` plus any
override it layers on top.

A tier's config reaches molecule only through `-c`, so scenarios run through the
Makefile, which derives the tier from `SCENARIO` (`default` and `leap` are both
incus): `make converge|verify|destroy|test ROLE=<role> [SCENARIO=<scenario>]`,
and `make test-leap|test-vm|test-hetzner ROLE=<role>`.

Bare molecule in a role directory gets no tier config, so `create` and
`converge` would fail obscurely on an unreachable host and `destroy` would skip,
exit 0 and reset the state file having destroyed nothing — on the hetzner tier,
leaving a VM billing. `.config/molecule/config.yml` closes that off: molecule
auto-loads it as the default base config, and `-c` replaces it, so the make
targets never see it and a bare run gets `bare-run.yml`, which fails naming the
target to use. It is a tripwire, not config — it supplies nothing to a real run.
Molecule finds it by walking to the git root, so it does not load in a linked
worktree, where `.git` is a file; the make targets still pass `-c` there.

Prepare stays a scenario file, like converge and verify: a scenario that needs
one ships a `prepare.yml` in its directory — its own (`arr`, `incus`, `sshd`) or
a symlink to the tier's (`common`, `dev`). No `base.yml` names
`playbooks.prepare`: a base config sets a floor, so it would mask the scenario's
own.

## incus

Container tier — the free default (`make test`, and `make test-leap` on the
Leap image). `create.yml` launches each platform with `incus launch`, applying a
platform's optional `config` map as `-c key=value`, waits for
`network-online.target`, then primes the zypper metadata cache
(retried) to ride out the flaky Tumbleweed mirror. `prepare.yml` removes the
image's cloud user (`opensuse`/`sles`) so `common` can claim uid 1000 for the
owner.

## libvirt

Full-boot VM tier (`make test-vm`), for roles a container can't exercise. Runs
under the system Python (the libvirt binding isn't in the venv), boots a UEFI VM
from the warm qcow2 the `libvirt` role's refresh timer keeps in the image store,
downloading on a miss. It waits for a DHCP lease, writes the instance config
molecule reads, then waits for SSH. Each platform sets `image`, `name`, and an
`image_checksum`. `destroy.yml` also clears the UEFI nvram and the disk.

## hetzner

The libvirt tier's CI form on a real VM (`make test-hetzner`), since Hetzner
can't nest KVM — it bills, so reserve it. A platform pins the first attempt with
its `server_type` and `location`; `create.yml` then walks every region ×
server-type pair (pinned first, then fallbacks) until one has capacity — the
default type sells out fleet-wide — and fails only when all are exhausted. After
launch it waits for SSH and for `cloud-init` to finish, which holds the zypper
lock a converge would otherwise race. Both create and destroy read the hcloud
token from the vault, so teardown needs `.vault_pass` too; given that,
`--destroy=always` plus CI's cancellation teardown keep a billed VM from
leaking.
