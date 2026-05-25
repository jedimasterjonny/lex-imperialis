# jedimasterjonny\.lex Release Notes

**Topics**

- <a href="#v0-3-1">v0\.3\.1</a>
    - <a href="#release-summary">Release Summary</a>
    - <a href="#bugfixes">Bugfixes</a>
- <a href="#v0-3-0">v0\.3\.0</a>
    - <a href="#release-summary-1">Release Summary</a>
    - <a href="#minor-changes">Minor Changes</a>
- <a href="#v0-2-0">v0\.2\.0</a>
    - <a href="#release-summary-2">Release Summary</a>
    - <a href="#minor-changes-1">Minor Changes</a>
- <a href="#v0-1-0">v0\.1\.0</a>
    - <a href="#release-summary-3">Release Summary</a>

<a id="v0-3-1"></a>
## v0\.3\.1

<a id="release-summary"></a>
### Release Summary

Patch release driven by code\-review findings against 0\.3\.0\. Fixes the
stow workflow \(use <code>\-\-adopt</code> \+ <code>git restore</code> so <code>/etc/skel</code>\-seeded
files are absorbed\; <code>\-v</code> so changes register\; resolve user home
directories via <code>getent</code> so <code>root</code> and other non\-<code>/home/\<user\></code>
operators work\)\, declares the missing <code>community\.general</code> galaxy
dependency\, narrows the firewalld and OBS\-repo installs to the gates
that actually consume them\, hardens the Incus image pre\-warm against
transient daemon errors\, and asserts that configured operators exist
before granting privileged groups\.

<a id="bugfixes"></a>
### Bugfixes

* common\, dev \- add <code>\-v</code> to <code>stow</code> invocations so the <code>changed\_when</code> substring match on stderr actually fires\. Without verbose output stow emits nothing on a successful link\, so the stow tasks were always reporting <code>changed\=0</code> even when they created symlinks\.
* common\, dev \- replace <code>stow \-\-override\=\'\.\*\'</code> with <code>stow \-\-adopt</code> followed by <code>git restore</code> in the package directory\. <code>\-\-override</code> only re\-takes already\-stow\-managed symlinks\; a real file at the target \(e\.g\. an <code>/etc/skel</code>\-seeded <code>\~/\.bashrc</code>\) made stow exit non\-zero and aborted the first apply\. <code>\-\-adopt</code> absorbs the existing file and the restore reverts the package back to upstream HEAD\, leaving the target as a symlink to upstream content\.
* common\, dev \- resolve stow user home directories via <code>getent</code> so users with non\-<code>/home/\<user\></code> home paths \(most notably <code>root</code>\) are configured correctly\.
* dev \- assert <code>dev\_incus\_admin\_users</code> and <code>dev\_libvirt\_users</code> already exist before granting group membership\. <code>ansible\.builtin\.user</code> defaults to <code>state\: present</code> and silently creates missing accounts\, contradicting the documented contract that the role does not create users — a typo in either list would otherwise produce a phantom account with privileged\-group membership\.
* dev \- assert <code>dev\_stow\_users</code> is a subset of <code>common\_stow\_users</code>\. The common role owns the <code>\~/dots</code> clone for each user in <code>common\_stow\_users</code>\; dev\'s stow loop <code>chdir\`\`s into \`\`\~/dots</code>\, so explicit overrides that named extra users \(without adding them to <code>common\_stow\_users</code>\) failed with a confusing <code>No such file or directory</code>\. The assertion now spells out the contract\.
* dev \- gate the distribution\-specific zypper repository task behind <code>dev\_configure\_incus\_host</code>\. The two OBS projects in <code>dev\_extra\_repos</code> on Leap \(<code>Virtualization\:containers</code> and <code>network\:utilities</code>\) exist only to source incus and its <code>lego</code> dependency\; a Leap workstation that adopts the role for general dev tooling and leaves the Incus gate off no longer picks them up\.
* dev \- move <code>firewalld</code> and <code>python3\-firewall</code> out of <code>dev\_incus\_packages</code> into a new <code>dev\_incus\_firewalld\_packages</code> list installed only when <code>dev\_incus\_firewalld\_trusted\_interfaces</code> is non\-empty\. nftables hosts that opt out of firewalld via the empty list no longer get firewalld installed as a dormant artefact\.
* dev \- move <code>python3\-libvirt\-python</code> and <code>python3\-lxml</code> from <code>dev\_ansible\_dev\_packages</code> into <code>dev\_libvirt\_packages</code>\. The bindings are imported by <code>community\.libvirt\.virt\_net</code> \(which this role uses\)\, so they belong on the same gate as libvirt itself\. Setting <code>dev\_install\_ansible\_dev\: false</code> together with <code>dev\_configure\_libvirt\_host\: true</code> previously failed with <code>ModuleNotFoundError\: No module named \'libvirt\'</code>\; the same default combination also dragged <code>libvirt\-libs</code> onto every plain dev workstation\. <code>dev\_ansible\_dev\_packages</code> now defaults to <code>\[\]</code> and exists for consumers to add their own controller\-side packages\.
* dev \- narrow the pre\-warm trigger for <code>dev\_incus\_images</code> to the <code>not found</code> error shape\. The upstream <code>incus image show</code> check had <code>failed\_when\: false</code>\, so a bare <code>rc \!\= 0</code> previously matched transient daemon errors \(e\.g\. <code>EOF</code> from a briefly\-unreachable socket\) and would re\-copy a cached image\.
* galaxy\.yml \- declare <code>community\.general</code> as a collection dependency\. Both shipped roles use <code>community\.general\.zypper</code> and <code>community\.general\.zypper\_repository</code>\; galaxy\-installed consumers without <code>community\.general</code> already present would otherwise fail at the first role task\.

<a id="v0-3-0"></a>
## v0\.3\.0

<a id="release-summary-1"></a>
### Release Summary

Initial release of two roles\: <code>common</code> provides the baseline package set plus sshd\; <code>dev</code> adds developer and Ansible\-author tooling with gated Incus and libvirt/KVM host configuration \(<code>dev\_configure\_incus\_host</code>\, <code>dev\_configure\_libvirt\_host</code>\) and GNU stow dotfile management for configured users\.

<a id="minor-changes"></a>
### Minor Changes

* common \- add <code>common\_stow\_users</code> \(default <code>\[\]</code>\)\. When non\-empty\, clones <code>common\_dots\_repo</code> \(default <code>https\://github\.com/jedimasterjonny/dots</code>\) to <code>\~/dots</code> for each user and stows <code>common\_stow\_packages</code> \(default <code>\[bash\-suse\]</code>\) via <code>stow \-\-override\=\'\.\*\'</code> \(overwriting any pre\-existing target files\)\.
* common \- new role that installs the baseline package set \(htop\, openssh\, python3\-rpm\, stow\, sudo\, vim\) and ensures sshd is enabled and started\.
* dev \- add <code>dev\_configure\_incus\_host</code> flag \(default <code>false</code>\) gating incus package install and <code>incus\.socket</code> enablement\. Moves <code>incus</code>/<code>incus\-tools</code> out of <code>dev\_ansible\_dev\_packages</code> into the new <code>dev\_incus\_packages</code> list\.
* dev \- add <code>dev\_configure\_libvirt\_host</code> flag \(default <code>false</code>\) gating libvirt package install and modular <code>virt\*d</code> socket enablement\. Moves <code>guestfs\-tools</code>\, <code>libguestfs</code>\, <code>libvirt</code>\, and <code>virt\-install</code> out of <code>dev\_ansible\_dev\_packages</code> into the new <code>dev\_libvirt\_packages</code> list and adds <code>mkisofs</code> \(used for cloud\-init ISOs\)\.
* dev \- add <code>dev\_incus\_admin\_users</code> \(default <code>\[\]</code>\)\. When <code>dev\_configure\_incus\_host</code> is true\, appends each existing user to the <code>incus\-admin</code> group\.
* dev \- add <code>dev\_incus\_firewalld\_trusted\_interfaces</code> \(default <code>\[incusbr0\]</code>\)\. When <code>dev\_configure\_incus\_host</code> is true\, installs <code>firewalld</code> \+ <code>python3\-firewall</code>\, ensures the daemon is enabled and started\, and adds each interface to firewalld\'s <code>trusted</code> zone so containers can route through the host\. Pulls in <code>ansible\.posix</code> as a collection dependency\.
* dev \- add <code>dev\_incus\_images</code> \(default <code>\[\]</code>\)\. When <code>dev\_configure\_incus\_host</code> is true\, pre\-warms each configured <code>\{alias\, source\}</code> image into the host\'s local Incus image cache if missing\.
* dev \- add <code>dev\_incus\_preseed</code> \(default\: lab\-ready map with an <code>incusbr0</code> bridge\, btrfs storage pool\, and Molecule\-friendly default profile\)\. When <code>dev\_configure\_incus\_host</code> is true and the default storage pool does not exist\, applies the preseed via <code>incus admin init \-\-preseed</code>\.
* dev \- add <code>dev\_libvirt\_manage\_default\_network</code> flag \(default <code>true</code>\)\. When <code>dev\_configure\_libvirt\_host</code> is true and the new flag is on\, ensures libvirt\'s <code>default</code> network is active and autostarts on boot\. Set the flag to false on hosts where the default subnet \(<code>192\.168\.122\.0/24</code>\) conflicts with the host\'s primary interface\. Pulls in <code>community\.libvirt</code> as a collection dependency\.
* dev \- add <code>dev\_libvirt\_users</code> \(default <code>\[\]</code>\)\. When <code>dev\_configure\_libvirt\_host</code> is true\, appends each existing user to the <code>libvirt</code> group\.
* dev \- add <code>dev\_stow\_packages</code> \(default <code>\[git\, nvim\]</code>\) and <code>dev\_stow\_users</code> \(defaults to <code>common\_stow\_users</code>\)\. When non\-empty\, stows each package from <code>\~/\<user\>/dots</code> \(cloned by common\) via <code>stow \-\-override\=\'\.\*\'</code>\.
* dev \- new role installing developer and Ansible\-author tooling\. <code>dev\_install\_ansible\_dev</code> \(default <code>true</code>\) toggles the Ansible\-author half\. Depends on the <code>common</code> role\. On openSUSE Leap\, sources <code>incus</code> and <code>lego</code> from OBS <code>Virtualization\:containers</code> and <code>network\:utilities</code>\.
* dev \- when <code>dev\_configure\_libvirt\_host</code> is true\, installs the <code>tumbleweed\-image\-refresh</code> shell helper at <code>/usr/local/sbin/tumbleweed\-image\-refresh</code>\. Fetches the openSUSE Tumbleweed Minimal\-VM qcow2 with sha256 verification and atomic replace\. Schedule \(when to invoke\, recurring timer\) remains caller policy\.
* dev \- when <code>dev\_configure\_libvirt\_host</code> is true\, make <code>/var/lib/libvirt/images</code> setgid \+ group\-writable \(2775\) by the <code>libvirt</code> group so files created there inherit the group qemu reads as\.

<a id="v0-2-0"></a>
## v0\.2\.0

<a id="release-summary-2"></a>
### Release Summary

First role release\: ships the motd role with a default Molecule
scenario backed by a Tier\-1 \(Incus\) test pipeline\.

<a id="minor-changes-1"></a>
### Minor Changes

* expand the collection README with a requirements line\, a roles table\, a Galaxy install snippet\, and a pointer to the project repository\.
* motd \- add minimal role that manages /etc/motd content\, intended as a baseline target for the Molecule test pipeline\.

<a id="v0-1-0"></a>
## v0\.1\.0

<a id="release-summary-3"></a>
### Release Summary

Initial scaffolding release of the <code>jedimasterjonny\.lex</code> collection\.
No roles or plugins ship in this version — subsequent releases will introduce
roles for the SUSE/Tumbleweed home lab\.
