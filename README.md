# ubuntu-vps-bootstrap

Safe, repeatable initial bootstrap for Ubuntu 24.04 VPS/server installations.

> Status: early development. Do not use on production systems yet.

## Configuration choices

The bootstrap has built-in defaults, documented by
`bootstrap.conf.example`. An explicit `--config` selects a configuration.

| Choice | Purpose |
|---|---|
| Built-in defaults | General Ubuntu VPS baseline without optional SSHD/X11 changes |
| `profiles/extended.conf` | Extended tools, IPv4 SSHD/X11 and root Git identity |
| `bootstrap.local.conf` | Ignored, machine-specific configuration; not preserved by Git |

Preview the extended profile without changing the server:

~~~bash
./bootstrap.sh --plan --config profiles/extended.conf
~~~

On a fresh VPS, after checking the plan:

~~~bash
./bootstrap.sh --apply --config profiles/extended.conf
~~~

The extended profile adds `nghttp2-client`, `socat`, `strace`, `tcpdump`,
`xauth`, and `xclip`, and enables `SSHD_X11_IPV4=true`. It also configures the global Git commit
identity for the bootstrap user (`root`) to `ncludo` and the public GitHub
noreply address. Git author identity is separate from SSH agent forwarding.
The default profile does not manage Git identity; an existing conflicting
root identity causes the extended-profile apply to stop rather than overwrite it.
This configures IPv4-only SSHD listeners and X11 forwarding; use it only
when IPv4 SSH access is available. Client-side X11 support is also required.
It does not install or configure a desktop environment or MobaXterm.

The general baseline remains available without selecting this profile.
On machines with an existing `bootstrap.local.conf`, explicitly selecting
a config avoids accidentally relying on an ignored local file.

Tracked profiles are intended to survive VPS reinstallation.
Keep credentials and server-specific secrets out of public configs.
The full `--apply` performs the bootstrap's normal system/APT updates;
`--plan` is the safe preview. For isolated Git identity checks without
APT updates, use `bash modules/git-identity.sh --audit true ncludo
109440419+ncludo@users.noreply.github.com` or the analogous `--apply`.
The isolated module changes only the invoking user's global Git configuration.
