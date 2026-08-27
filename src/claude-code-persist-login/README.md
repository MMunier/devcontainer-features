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
add to `mounts`, and no `postCreateCommand` of your own needed.

Out of the box this also writes `~/.claude/settings.json` with
`remoteControlAtStartup: false`. Newer Claude Code versions enable Remote
Control at startup by default, which lets the session be driven from outside
the container; this turns it off. Set `remoteControlAtStartup` to `"true"` to
keep it on, or `"unset"` to not manage the key at all.

## Options

| Option | Type | Default | What it does |
| --- | --- | --- | --- |
| `remoteControlAtStartup` | `"false"` \| `"true"` \| `"unset"` | `"false"` | Value written for `remoteControlAtStartup`. `"unset"` leaves the key alone. |
| `settings` | string | `""` | Extra settings merged into `settings.json`, as a JSON object. |
| `overwriteExistingSettings` | boolean | `false` | Replace `settings.json` instead of merging into it. |

### Writing the `settings` option

The devcontainer CLI **strips double quotes** from option values, so JSON
written the obvious way arrives as `{model:opus}` and is not parseable. Write
it unquoted and the feature re-quotes it:

```jsonc
"ghcr.io/mmunier/devcontainer-features/claude-code-persist-login:1": {
  "settings": "{model:opus,verbose:true}"
}
```

`true`, `false`, `null` and numbers stay unquoted. A value that is neither
valid JSON nor repairable fails the build with the offending string, rather
than writing a corrupt `settings.json`.

A full working config is in
[`examples/claude-code-configured`](../../examples/claude-code-configured).

## What gets persisted

| Path | Why it needs handling |
| --- | --- |
| `~/.claude/` | Holds `.credentials.json` (the OAuth token). Mounted as the volume. |
| `~/.claude/settings.json` | Your Claude Code settings, incl. the Remote Control default this feature writes. Inside the volume, so edits made in the container survive rebuilds. |
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

## Why the settings are written twice

The volume mounts **over** `~/.claude`, so anything the build writes there is
invisible on any container whose volume already exists — which is every rebuild
after the first. The build-time write only matters for a *fresh* volume, where
it becomes part of the seed.

So the same script also runs from a `postCreateCommand` the feature declares
itself, which is the run that actually applies settings on an existing volume.

By default it **merges**, so settings you changed inside the container are kept
and only the keys named in the options are overwritten. The build-time run
records a copy of exactly what it wrote; if the file still matches that copy it
is an untouched seed and gets rewritten wholesale. Merging needs `jq` or
`python3` — with neither, the feature declines to merge rather than clobber a
file it cannot parse, and says so without failing container creation.

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
- **Settings are merged one level deep.** Naming a nested object (`hooks`,
  `permissions`) replaces that whole object rather than merging into it.
- A failed settings write does **not** fail container creation — the login
  persistence is the feature's real job and keeps working regardless.
