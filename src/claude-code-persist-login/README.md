# claude-code-persist-login (dev container feature)

Persists the Claude Code login across container stop/start **and rebuilds**, in
a named Docker volume — without the usual `postCreateCommand` chown dance.

Host credentials stay on the host: you authenticate once *inside* the container
and it sticks. This feature deliberately does **not** bind-mount the host's
`~/.claude`.

## Usage

```jsonc
{
  "features": {
    "ghcr.io/anthropics/devcontainer-features/claude-code:1.0": {},
    "ghcr.io/mmunier/devcontainer-features/claude-code-persist-login:1": {}
  }
}
```

That's the whole setup — the feature declares its own volume mount. Nothing to
add to `mounts`, and no `postCreateCommand` needed.

## What gets persisted

| Path | Why it needs handling |
| --- | --- |
| `~/.claude/` | Holds `.credentials.json` (the OAuth token). Mounted as the volume. |
| `~/.claude.json` | Account/session config — `oauthAccount`, `mcpServers`, `projects`. A **file in `$HOME`**, outside `~/.claude/`, so the volume doesn't cover it. Stored inside the volume and symlinked back. |

Missing the second one is the usual reason a container "stays logged in" yet
loses its MCP servers and project history on every rebuild.

## How it works, and why

**Ownership is solved at build time, not with a runtime chown.** A fresh named
volume mounts as `root:root`, so the common recipe is
`"postCreateCommand": "sudo chown -R vscode:vscode /home/vscode/.claude"`. That
needs `sudo` in the container and runs on every create.

Instead, this feature pre-creates the mount target owned by the remote user at
**image build** time. When Docker first mounts the empty volume it *seeds* it
from the image directory underneath — copying contents **and ownership** — so
the volume comes up already owned by the remote user. No runtime chown, no
`sudo` requirement.

Note this seeding only happens when the volume is **empty**; an existing volume
keeps whatever ownership it already had.

## Caveats

- **The mount target is hardcoded to `/home/vscode/.claude`.** The `mounts`
  block is resolved by the CLI before any install script runs, so it cannot
  reference `_REMOTE_USER_HOME`. For a remote user with a different home, the
  install script prints a warning at build time — edit the feature's
  `mounts` target, or declare your own mount instead.
- **The volume is named `${devcontainerId}-claude-code-config`**, so it is
  per-devcontainer. Two projects each get their own login.
- Do not also set `CLAUDE_CONFIG_DIR` to a different directory; the symlink
  already consolidates both files onto the one volume.
