# jedimasterjonny\.lex Release Notes

**Topics**

- <a href="#v0-7-0">v0\.7\.0</a>
    - <a href="#release-summary">Release Summary</a>
    - <a href="#minor-changes">Minor Changes</a>
- <a href="#v0-6-0">v0\.6\.0</a>
    - <a href="#release-summary-1">Release Summary</a>
    - <a href="#minor-changes-1">Minor Changes</a>
- <a href="#v0-5-1">v0\.5\.1</a>
    - <a href="#release-summary-2">Release Summary</a>
    - <a href="#bugfixes">Bugfixes</a>
- <a href="#v0-5-0">v0\.5\.0</a>
    - <a href="#release-summary-3">Release Summary</a>
    - <a href="#minor-changes-2">Minor Changes</a>
    - <a href="#breaking-changes--porting-guide">Breaking Changes / Porting Guide</a>
    - <a href="#bugfixes-1">Bugfixes</a>
- <a href="#v0-4-0">v0\.4\.0</a>
    - <a href="#release-summary-4">Release Summary</a>
    - <a href="#minor-changes-3">Minor Changes</a>
    - <a href="#bugfixes-2">Bugfixes</a>
- <a href="#v0-3-1">v0\.3\.1</a>
    - <a href="#release-summary-5">Release Summary</a>
    - <a href="#bugfixes-3">Bugfixes</a>
- <a href="#v0-3-0">v0\.3\.0</a>
    - <a href="#release-summary-6">Release Summary</a>
    - <a href="#minor-changes-4">Minor Changes</a>
- <a href="#v0-2-0">v0\.2\.0</a>
    - <a href="#release-summary-7">Release Summary</a>
    - <a href="#minor-changes-5">Minor Changes</a>
- <a href="#v0-1-0">v0\.1\.0</a>
    - <a href="#release-summary-8">Release Summary</a>

<a id="v0-7-0"></a>
## v0\.7\.0

<a id="release-summary"></a>
### Release Summary

Adds sshd hardening to the common role\: a managed drop\-in that restricts
SSH to modern post\-quantum\-hybrid / AEAD / ETM algorithms and Ed25519 \+
RSA\-SHA2 keys\, enforces key\-only authentication with key\-based root login\,
generates any missing host keys\, and verifies the result with <code>sshd \-T</code>\.
Gated by common\_sshd\_harden \(default true\)\.

<a id="minor-changes"></a>
### Minor Changes

* common \- harden sshd via a managed drop\-in at /etc/ssh/sshd\_config\.d/00\-lex\-hardening\.conf \(named 00\-\* so it sorts first in sshd\_config\.d/ and stays authoritative under sshd\'s first\-match\-wins rule\)\, gated by common\_sshd\_harden \(default true\)\. Restricts KexAlgorithms\, Ciphers\, MACs\, and the HostKey/Pubkey/CA signature algorithms to modern AEAD / ETM / post\-quantum\-hybrid / Ed25519 \+ RSA\-SHA2 choices\; enforces key\-only authentication \(PasswordAuthentication no\, KbdInteractiveAuthentication no\, AuthenticationMethods publickey\) with key\- or certificate\-based root login \(PermitRootLogin prohibit\-password\)\; and sets LogLevel VERBOSE\. The effective KexAlgorithms list is computed at task time by intersecting a preference allowlist with <code>ssh \-Q kex</code>\, so older OpenSSH builds silently drop algorithms they do not recognise\. Generates any missing default host keys first so the restricted HostKeyAlgorithms always has an Ed25519 key to offer\, ensures the drop\-in\'s Include leads sshd\_config\, and asserts the result against <code>sshd \-T</code>\.

<a id="v0-6-0"></a>
## v0\.6\.0

<a id="release-summary-1"></a>
### Release Summary

Adds the <code>common\_users</code> variable to the <code>common</code> role\: a list of
<code>\{name\, uid\?\, group\?\, shell\?\}</code> dicts\, applied as the role\'s first
task to ensure the configured operator accounts exist on the host\.
Empty by default — consumers that provision accounts out of band keep
their current behaviour\.

<a id="minor-changes-1"></a>
### Minor Changes

* common \- add the <code>common\_users</code> variable so the role ensures the configured operator accounts exist on the host\. Each entry takes <code>name</code> \(required\) and optional <code>uid</code>\, <code>group</code>\, and <code>shell</code>\. Empty by default — consumers that provision accounts out of band keep their current behaviour\.

<a id="v0-5-1"></a>
## v0\.5\.1

<a id="release-summary-2"></a>
### Release Summary

Patch release fixing the dev role\'s molecule verify on openSUSE Leap\.
verify\.yml now gathers facts and loads the distribution\-specific vars
file the same way tasks/main\.yml does\, so the libvirt package
presence check resolves the Leap\-versioned python\{XY\}\-libvirt\-python
/ python\{XY\}\-lxml names rather than the Tumbleweed virtual\-provide
names from defaults \(which Leap does not expose\, so verify failed on
the ci scenario\)\.

<a id="bugfixes"></a>
### Bugfixes

* dev \- molecule verify now gathers facts and loads the same distribution\-specific vars file as the role itself\, so the libvirt package presence check resolves the Leap\-versioned <em class="title-reference">python\{XY\}\-libvirt\-python</em> / <em class="title-reference">python\{XY\}\-lxml</em> names on Leap rather than the Tumbleweed virtual\-provide names <em class="title-reference">python3\-libvirt\-python</em> / <em class="title-reference">python3\-lxml</em> \(which Leap does not expose and which previously failed verify on the ci scenario\)\.

<a id="v0-5-0"></a>
## v0\.5\.0

<a id="release-summary-3"></a>
### Release Summary

Review\-driven hardening pass\. Drops the maintainer\-personal default
for common\_dots\_repo \(consumers stowing dotfiles must now set it
explicitly\)\, fixes the openSUSE Leap libvirt python binding names\,
derives Incus firewalld trust from the preseed\, and tightens the
molecule verify path \(preseed shape assert\, boundary\-anchored
profile checks\, profile name read from preseed\)\. Also adds
galaxy\_info\.platforms so Galaxy consumers can filter by distro\.

<a id="minor-changes-2"></a>
### Minor Changes

* common\, dev \- declare the openSUSE platform in galaxy\_info\.platforms so consumers browsing Galaxy can filter by distro\. The roles call community\.general\.zypper unconditionally\, so non\-SUSE users can\'t consume them\; the metadata now reflects that\.
* dev \- assert dev\_incus\_preseed has the keys the role indexes \(networks\[0\]\, storage\_pools\[0\]\, profiles\[0\]\, and at least one nic and one disk under profiles\[0\]\.devices\) at the top of the Incus block\. An under\-specified preseed now fails loudly before any host mutation rather than with a Jinja KeyError mid\-play\.

<a id="breaking-changes--porting-guide"></a>
### Breaking Changes / Porting Guide

* common \- common\_dots\_repo no longer defaults to the maintainer\'s personal dotfiles repository\. Set it explicitly when common\_stow\_users is non\-empty\; the role asserts the variable is set at task time\.

<a id="bugfixes-1"></a>
### Bugfixes

* common\, dev \- gate the post\-stow <em class="title-reference">git restore \.</em> task on <em class="title-reference">\*\_stow\_packages \| length \> 0</em>\. With an empty packages list the stow loop absorbs nothing\, so the restore would only discard any uncommitted edits an operator made to \~/dots by hand\.
* dev \- dev\_incus\_firewalld\_trusted\_interfaces now defaults to null and resolves at task time from dev\_incus\_preseed\.networks\, so overriding the preseed bridge propagates to firewalld trust without a matching override here\. Set the variable to an explicit list \(or \[\]\) to opt out of the derivation\.
* dev \- dev\_stow\_users defaults to null and resolves at task time from common\_stow\_users \(rather than via a lazy\-Jinja default in defaults/main\.yml that could lose to vars\_files reads in downstream plays\)\. Set the variable to an explicit list to opt out of the derivation\.
* dev \- molecule verify anchors the <em class="title-reference">parent\: \<bridge\></em> / <em class="title-reference">pool\: \<pool\></em> assertions on full\-line matches via a multiline regex \(with the expected names regex\-escaped\)\, so a profile pointing at a prefix name \(e\.g\. <em class="title-reference">incusbr0\-stale</em>\) no longer passes by virtue of the substring <em class="title-reference">incusbr0</em> appearing as a prefix\.
* dev \- molecule verify reads the Incus profile name to inspect from dev\_incus\_preseed\.profiles\[0\]\.name rather than hardcoding <em class="title-reference">default</em>\, so preseed overrides that rename the profile no longer make verify target the wrong \(or non\-existent\) profile\.
* dev \- on openSUSE Leap\, derive dev\_libvirt\_packages\' python binding names from the target python interpreter \(python\{X\}\{Y\}\-libvirt\-python\, python\{X\}\{Y\}\-lxml\)\. Leap doesn\'t expose the unversioned python3\-\* virtual provides Tumbleweed does\, so the previous defaults raised \'no provider for python3\-libvirt\-python\' at zypper install\.

<a id="v0-4-0"></a>
## v0\.4\.0

<a id="release-summary-4"></a>
### Release Summary

Robustness pass on the common and dev roles\, addressing follow\-up review
findings on the host\-config and stow paths\. The Incus init probe now
derives its pool name from the preseed and gates on locale\-pinned
\"not found\" stderr\, sidestepping a daemon\-startup race against
<code>incus\.socket</code> and overrides that rename the storage pool\. The
molecule verify plays gain a real symlink\-contract check on the stow
targets\, iterate Incus devices by type rather than by hardcoded keys\,
and reliably exercise the dotfile path by pinning stow\-user overrides
at extra\-vars precedence\. Plus bugfixes for Leap OBS repo URL refresh
across distribution upgrades\, the Tumbleweed qcow2 inheriting
<code>root\:libvirt</code> from its parent dir\'s setgid\, and <code>stow</code>\'s
<code>changed\_when</code> anchored on stderr line shape\.

<a id="minor-changes-3"></a>
### Minor Changes

* dev \- document the always\-quote\-strings rule on <code>dev\_incus\_preseed</code> so overrides like <code>ipv4\.dhcp\: yes</code> don\'t get silently bool\-coerced by <code>to\_nice\_yaml</code> and rejected \(or misinterpreted\) by <code>incus admin init \-\-preseed</code>\.

<a id="bugfixes-2"></a>
### Bugfixes

* common\, dev \- anchor the stow <code>changed\_when</code> on stderr lines that <em>start</em> with <code>LINK\:</code> / <code>UNLINK\:</code> rather than substring\-matching anywhere in stderr\, and drop the dead <code>\* existing target</code> disjunct \(stow with <code>\-\-adopt</code> absorbs unmanaged targets silently and never emits that warning\)\. A future stow release that prints the <code>LINK\:</code> keyword in a different position no longer trips a spurious change\.
* common\, dev \- assert that the stow targets \(<code>\~/\.bashrc</code> for bash\-suse\, <code>\~/\.config/nvim</code> for nvim\) are symlinks pointing into <code>\~/dots</code> rather than just checking they exist\. A regression in the <code>\-\-adopt</code> \+ <code>git restore</code> sequence — or a future stow that silently no\-ops because <code>changed\_when</code> misfired — would have left a real file or directory in place and still passed the prior existence\-only assertion\.
* common\, dev \- move the molecule <code>common\_stow\_users</code> / <code>dev\_stow\_users</code> overrides for the default and ci scenarios from <code>inventory\.group\_vars\.all</code> to <code>options\.extra\-vars</code> so they beat the role\-defaults <code>vars\_files</code> load in the verify play\. Previously converge stowed against root \(group\_vars in scope\) but verify saw <code>common\_stow\_users \=\= \[\]</code> \(defaults shadowing group\_vars\)\, the <code>when\:</code> gate on the dotfile assertion block was false\, and the dots\-repo / symlink assertions silently skipped\.
* dev \- derive the storage pool name in the <code>Check whether Incus is already initialised</code> probe from <code>dev\_incus\_preseed\.storage\_pools\[0\]\.name</code> rather than hardcoding <code>default</code>\; overrides that rename the pool no longer make the probe permanently report <code>not initialised</code> and re\-apply the preseed on every play\.
* dev \- drop the explicit <code>chown root\:root</code> in tumbleweed\-image\-refresh so the qcow2 inherits <code>root\:libvirt</code> from the parent dir\'s setgid bit\; qemu now reads the image via group membership rather than the world\-read bit\, which keeps it accessible if <code>/var/lib/libvirt/images</code> is ever hardened to mode 2770\.
* dev \- pin <code>LC\_ALL\=C</code> on the Incus init probe and the image\-cache probe so their stderr substring matches are stable on non\-English hosts\, and gate the preseed re\-apply on <code>\'not found\' in stderr</code> rather than bare <code>rc \!\= 0</code>\; the previous gate could re\-run <code>incus admin init \-\-preseed</code> against a partially\-initialised daemon during a startup race against <code>incus\.socket</code>\.
* dev \- resolve the expected bridge and storage pool from <code>dev\_incus\_preseed\.profiles\[0\]\.devices</code> by device type \(<code>nic</code> / <code>disk</code>\) rather than by hardcoded device keys <code>eth0</code> / <code>root</code>\; a profile that names its NIC <code>enp0s3</code> or its disk <code>rootfs</code> no longer crashes the molecule verify play with <code>\'dict object\' has no attribute \'eth0\'</code>\.
* dev \- set <code>overwrite\_multiple\: true</code> on the Leap OBS repositories so an in\-place distribution upgrade \(e\.g\. Leap 16\.0 to 16\.1\) updates the repo URL in place instead of leaving the repo pinned to the previous release\'s URL\, which made the next <code>zypper refresh</code> 404 and broke the role\'s subsequent <code>Install Incus packages</code> task\.

<a id="v0-3-1"></a>
## v0\.3\.1

<a id="release-summary-5"></a>
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

<a id="bugfixes-3"></a>
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

<a id="release-summary-6"></a>
### Release Summary

Initial release of two roles\: <code>common</code> provides the baseline package set plus sshd\; <code>dev</code> adds developer and Ansible\-author tooling with gated Incus and libvirt/KVM host configuration \(<code>dev\_configure\_incus\_host</code>\, <code>dev\_configure\_libvirt\_host</code>\) and GNU stow dotfile management for configured users\.

<a id="minor-changes-4"></a>
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

<a id="release-summary-7"></a>
### Release Summary

First role release\: ships the motd role with a default Molecule
scenario backed by a Tier\-1 \(Incus\) test pipeline\.

<a id="minor-changes-5"></a>
### Minor Changes

* expand the collection README with a requirements line\, a roles table\, a Galaxy install snippet\, and a pointer to the project repository\.
* motd \- add minimal role that manages /etc/motd content\, intended as a baseline target for the Molecule test pipeline\.

<a id="v0-1-0"></a>
## v0\.1\.0

<a id="release-summary-8"></a>
### Release Summary

Initial scaffolding release of the <code>jedimasterjonny\.lex</code> collection\.
No roles or plugins ship in this version — subsequent releases will introduce
roles for the SUSE/Tumbleweed home lab\.
