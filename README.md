# ubuntu-vps-bootstrap

Safe, repeatable initial bootstrap for Ubuntu 24.04 VPS/server installations.

> Status: early development. Do not use on production systems yet.

## Configuration choices

The bootstrap has built-in defaults, documented by
`bootstrap.conf.example`. An explicit `--config` selects a configuration.

| Choice | Purpose |
|---|---|
| Built-in defaults | General Ubuntu VPS baseline without optional SSHD/X11 changes |
| `profiles/extended.conf` | Extended tools and optional IPv4 SSHD/X11 setup |
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
`xauth`, and `xclip`, and enables `SSHD_X11_IPV4=true`.
This configures IPv4-only SSHD listeners and X11 forwarding; use it only
when IPv4 SSH access is available. Client-side X11 support is also required.
It does not install or configure a desktop environment or MobaXterm.

The general baseline remains available without selecting this profile.
On machines with an existing `bootstrap.local.conf`, explicitly selecting
a config avoids accidentally relying on an ignored local file.

Tracked profiles are intended to survive VPS reinstallation.
Keep credentials and server-specific secrets out of public configs.
The full `--apply` performs the bootstrap's normal system/APT updates;
`--plan` is the safe preview.
