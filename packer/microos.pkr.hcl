// Build rogue-trader's openSUSE MicroOS ContainerHost snapshot. Hetzner offers
// no MicroOS stock image, so one build is unavoidable.
//
// Two stages, because the halves need different machine states: the disk image
// can only be written from rescue, and transactional-update only works on a
// running system. They must run in order -- `make image` does that.
//
// Runs against the emmas-edit project: Hetzner snapshots are project-scoped, so
// an image built anywhere else is invisible to the server that needs it.
// See packer/README.md.

// Pinned exactly, not by range: packer init writes no lock file, so a range
// re-resolves to the newest match on every cold init and runs whatever it gets
// -- and in the build's case that plugin process holds the Hetzner token, which
// can delete every server in the project. Renovate bumps these.
packer {
  required_plugins {
    ansible = {
      source = "github.com/hashicorp/ansible"
      # renovate: datasource=github-releases depName=hashicorp/packer-plugin-ansible
      version = "1.1.6"
    }
    hcloud = {
      source = "github.com/hetznercloud/hcloud"
      # renovate: datasource=github-releases depName=hetznercloud/packer-plugin-hcloud
      version = "1.7.2"
    }
  }
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}

// The build server's only job is to be a disk. Not cx23: Hetzner no longer
// offers the cx line for new servers in fsn1, nbg1 or hel1, so a build on it
// fails at server creation. Its 2 GB of RAM is the constraint to watch -- the
// rescue root runs in RAM and stage 1 downloads the qcow2 (~590 MB and growing
// with Tumbleweed) into it, so a much larger image would want cpx22.
variable "server_type" {
  type    = string
  default = "cpx12"
}

// Same location as rogue-trader, so the snapshot lands in the right place.
variable "location" {
  type    = string
  default = "hel1"
}

// Stage 1 boots straight into rescue and never runs this; a server just has to
// be created from something.
variable "rescue_base_image" {
  type    = string
  default = "ubuntu-24.04"
}

// The image ships no cloud-init, which is what performs Hetzner's ssh_keys
// injection, so packer's own ephemeral keypair never reaches the box. Stage 2
// authenticates with a key the build Ignition below names instead. No defaults,
// deliberately -- bin/packer.sh generates a throwaway pair per build, and must.
variable "ssh_private_key_file" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

// Build-time identity only -- deliberately NOT bootstrap/rogue-trader.bu, the
// production identity. Stage 2 strips it from the finished snapshot.
locals {
  build_ignition = jsonencode({
    ignition = { version = "3.5.0" }
    passwd = {
      users = [{
        name              = "root"
        sshAuthorizedKeys = [var.ssh_public_key]
      }]
    }
  })
}

// Stage 1 -- write the disk image, from rescue.
source "hcloud" "base" {
  token        = var.hcloud_token
  image        = var.rescue_base_image
  location     = var.location
  server_type  = var.server_type
  rescue       = "linux64"
  ssh_username = "root"

  snapshot_name   = "microos-base-${timestamp()}"
  snapshot_labels = { custom_image = "microos-base" }
}

// Stage 2 -- boot stage 1's output and provision it. Selected by label rather
// than id so this template carries no snapshot reference that rots.
source "hcloud" "containerhost" {
  token       = var.hcloud_token
  location    = var.location
  server_type = var.server_type

  image_filter {
    with_selector = ["custom_image=microos-base"]
    most_recent   = true
  }

  // Read only because stage 1 set ignition.platform.id=hetzner on the kernel
  // command line. Without that karg Ignition resolves to the qemu platform,
  // never reads this, and the box comes up with no root key and no way in.
  user_data = local.build_ignition

  ssh_username         = "root"
  ssh_private_key_file = var.ssh_private_key_file

  snapshot_name   = "microos-containerhost-${timestamp()}"
  snapshot_labels = { custom_image = "microos-containerhost" }
}

build {
  name    = "stage1-base"
  sources = ["source.hcloud.base"]

  provisioner "ansible" {
    playbook_file = "packer/stage1-write-image.yml"
    host_alias    = "packer-microos-rescue"
    use_proxy     = false
    extra_arguments = [
      "--extra-vars", jsonencode({
        // The rescue system is Debian and always carries one.
        ansible_python_interpreter : "/usr/bin/python3"
      })
    ]
  }
}

build {
  name    = "stage2-containerhost"
  sources = ["source.hcloud.containerhost"]

  provisioner "ansible" {
    playbook_file = "packer/stage2-provision.yml"
    host_alias    = "packer-microos"
    use_proxy     = false
    // No ansible_python_interpreter here on purpose: the image ships
    // python313-base rather than python3-base, so discovery must resolve the
    // versioned interpreter that a hardcoded /usr/bin/python3 would miss.
  }
}
