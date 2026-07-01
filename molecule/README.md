# molecule

Shared, role-agnostic create/destroy playbooks for the three test tiers, driven
by `molecule_yml.platforms` so every role reuses them. A role's scenario wires
them in through `provisioner.playbooks`; converge and verify stay with the role.

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
