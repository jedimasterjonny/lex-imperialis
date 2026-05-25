# jedimasterjonny\.lex Release Notes

**Topics**

- <a href="#v0-3-0">v0\.3\.0</a>
    - <a href="#release-summary">Release Summary</a>
    - <a href="#minor-changes">Minor Changes</a>
- <a href="#v0-2-0">v0\.2\.0</a>
    - <a href="#release-summary-1">Release Summary</a>
    - <a href="#minor-changes-1">Minor Changes</a>
- <a href="#v0-1-0">v0\.1\.0</a>
    - <a href="#release-summary-2">Release Summary</a>

<a id="v0-3-0"></a>
## v0\.3\.0

<a id="release-summary"></a>
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

<a id="release-summary-1"></a>
### Release Summary

First role release\: ships the motd role with a default Molecule
scenario backed by a Tier\-1 \(Incus\) test pipeline\.

<a id="minor-changes-1"></a>
### Minor Changes

* expand the collection README with a requirements line\, a roles table\, a Galaxy install snippet\, and a pointer to the project repository\.
* motd \- add minimal role that manages /etc/motd content\, intended as a baseline target for the Molecule test pipeline\.

<a id="v0-1-0"></a>
## v0\.1\.0

<a id="release-summary-2"></a>
### Release Summary

Initial scaffolding release of the <code>jedimasterjonny\.lex</code> collection\.
No roles or plugins ship in this version — subsequent releases will introduce
roles for the SUSE/Tumbleweed home lab\.
