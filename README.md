# devcontainer-features

Reusable [dev container features](https://containers.dev/implementors/features/),
consolidated from several projects that had each grown their own copy.

They exist because of a handful of non-obvious devcontainer constraints — a
feature's options are fixed at **image build** time, `runArgs: --env-file` only
applies at `docker run`, a fresh named volume mounts as `root:root`, and VS Code
re-copies `~/.gitconfig` on every attach. Each feature's README explains which
one it works around and why the obvious approach fails.

| Feature | What it does |
| --- | --- |
| [`claude-code-persist-login`](src/claude-code-persist-login) | Keeps the Claude Code login across rebuilds, in a named volume, with no `postCreateCommand` chown. |
| [`ssh-signing-key`](src/ssh-signing-key) | Git commit signing with a hardware-backed key (YubiKey `sk-ssh-*`), private half never entering the container. |
| [`authorized-key`](src/authorized-key) | Injects SSH public keys into `authorized_keys` with correct perms. Fills the gap the official `sshd` feature leaves. |
| [`forgejo-cli`](src/forgejo-cli) | Forgejo CLI (`fj`) for reading and filing issues, authenticated from a runtime token that never enters the image. |
| [`github-cli-auth`](src/github-cli-auth) | Auth wiring for the official `github-cli` feature: runtime token, plus the `gh auth setup-git` that VS Code's gitconfig copy would otherwise drop. |

## Usage

```jsonc
{
  "features": {
    "ghcr.io/mmunier/devcontainer-features/claude-code-persist-login:1": {},
    "ghcr.io/mmunier/devcontainer-features/ssh-signing-key:1": {},
    "ghcr.io/mmunier/devcontainer-features/authorized-key:1": {
      "publicKey": "ssh-ed25519 AAAA... you@your-host"
    }
  }
}
```

Complete, working configurations are in [`examples/`](examples):

| Example | For |
| --- | --- |
| [`claude-code-dev`](examples/claude-code-dev) | The baseline: Claude Code that stays logged in. Start here. |
| [`signed-commits`](examples/signed-commits) | Adds YubiKey-backed commit signing. |
| [`ssh-accessible`](examples/ssh-accessible) | For the bare `devcontainer` CLI, where VS Code's automatic agent forwarding isn't available. |
| [`forgejo-issues`](examples/forgejo-issues) | Adds the Forgejo CLI, for reading and filing issues from inside the container. |
| [`github-issues`](examples/github-issues) | The same, for GitHub. |

## One thing that bites everyone

Node must be installed **before** `claude-code`, and the order must be pinned
explicitly:

```jsonc
"features": {
  "ghcr.io/devcontainers/features/node:2": { "version": "lts" },
  "ghcr.io/anthropics/devcontainer-features/claude-code:1.0": {}
},
"overrideFeatureInstallOrder": [
  "ghcr.io/devcontainers/features/node",
  "ghcr.io/anthropics/devcontainer-features/claude-code"
]
```

The `claude-code` feature only installs Node when `node`+`npm` are both absent,
and its self-install path can fall through to a distro `nodejs` package that
ships **without** `npm` — so its own `command -v npm` check then fails and the
build dies with *"Node.js and npm are required but could not be installed"*.
Providing Node yourself means it skips that path. `claude-code` declares no
dependency on the node feature, so without `overrideFeatureInstallOrder` the
ordering is up to the resolver.

## Development

```bash
# Test one feature (runs every scenario in test/<feature>/scenarios.json)
devcontainer features test --features claude-code-persist-login .

# Test everything
devcontainer features test .
```

CI runs the same on every PR ([`.github/workflows/test.yaml`](.github/workflows/test.yaml)).
Pushes to `main` that touch `src/` publish to `ghcr.io/mmunier/devcontainer-features/*`
([`release.yaml`](.github/workflows/release.yaml)) — **at the version in each
feature's `devcontainer-feature.json`**, so bump that or the push ships nothing.

Docs are written by hand, not generated. The generator rewrites `README.md`
wholesale from `devcontainer-feature.json`, which would delete the explanations
that are the reason these READMEs exist.
