# krew (dev container feature)

Installs [krew](https://krew.sigs.k8s.io/), the `kubectl` plugin manager, plus a
list of plugins — **baked into the image at build time**, so container start is
instant and needs no network.

```bash
kubectl krew list      # what's installed
kubectl ctx            # a plugin, dispatched by kubectl
kubectl krew install x # add more later, no sudo needed
```

Installing `kubectl` itself is left to the official
[`kubectl-helm-minikube`](https://github.com/devcontainers/features/tree/main/src/kubectl-helm-minikube)
feature, declared here as a dependency — so you don't have to list it
yourself.

## Usage

```jsonc
{
  "features": {
    "ghcr.io/mmunier/devcontainer-features/krew:1": {
      "plugins": "ctx,ns,tree,neat"
    }
  }
}
```

That's the whole config: `kubectl` comes in through `dependsOn`, with `helm` and
`minikube` defaulted to `none` — krew needs neither, and minikube in particular
is a heavy install to inherit by accident.

Those are **defaults, not decisions**. Listing the feature yourself overrides
them, and nothing is installed twice:

```jsonc
{
  "features": {
    // Want helm too? Ask for it — this wins over the dependency's defaults.
    "ghcr.io/devcontainers/features/kubectl-helm-minikube:1": { "helm": "latest" },
    "ghcr.io/mmunier/devcontainer-features/krew:1": { "plugins": "ctx,ns" }
  }
}
```

Browse names with `kubectl krew search`, or the
[plugin index](https://krew.sigs.k8s.io/plugins/).

## Options

| Option | Default | Description |
| --- | --- | --- |
| `plugins` | `""` | Comma- or space-separated plugin names. Empty installs krew alone. |
| `version` | `latest` | krew release to install (e.g. `v0.5.0`). |
| `krewRoot` | `/usr/local/krew` | Where krew and plugins live. Exported as `KREW_ROOT`. |
| `failOnPluginError` | `false` | Fail the build if a plugin can't be installed. |

## How it works, and why

**krew is a per-user tool, and that breaks in a container build.** By default it
installs into `$HOME/.krew`. Feature install scripts run as **root**, so the
default would put everything in `/root/.krew` — invisible to the remote user,
who is the one actually running `kubectl`. This installs into a shared
`KREW_ROOT` instead, then `chown`s it to the remote user so plugins can still be
added later without `sudo`. A path outside any home directory also survives a
volume being mounted over the user's home.

**`KREW_ROOT` is exported, not just the `bin` directory.** With only the `bin`
dir on `PATH`, existing plugins work — but the next `kubectl krew install`
falls back to the per-user default and quietly builds a *second*, private
`~/.krew`. Both variables are set, in `/etc/profile.d`, so it applies to every
user rather than whichever dotfiles happened to get edited.

**zsh is wired up separately.** The devcontainer base images default the remote
user's shell to zsh, which does **not** read `/etc/profile.d` on its own. Left
alone, an interactive terminal wouldn't find `kubectl-krew` even though `bash
-lc` would — a confusing split. The snippet is sourced from `/etc/zsh/zshenv`
too.

**Plugins are installed one at a time, on purpose.** Given several names at
once, `krew install` aborts the **entire batch** on the first name it can't
resolve. One typo would silently cost every plugin listed after it, while the
build still reported success. Installing individually means a bad name costs
only itself, and is reported by name. There's a test scenario that puts a bad
name in the *middle* of the list and asserts the plugin after it survives.

**A bad plugin name doesn't fail the build by default.** A plugin that's been
renamed or dropped from the index shouldn't cost you the whole container. The
build warns, lists what it skipped, and carries on. Set `failOnPluginError` if
the list is load-bearing and you'd rather find out at build time.

**The download is checksum-verified.** Upstream publishes a `.sha256` next to
each release asset, so a corrupted or tampered download becomes a clear build
failure instead of a mystery later.

## Notes

- The plugin index is a **git clone**, so `git` is installed if missing — not
  obvious from the download alone, and it otherwise fails with a confusing
  error.
- The index is refreshed **once** up front rather than once per plugin, which
  `krew install` would otherwise do — a git fetch per plugin for no benefit.
- Linux `amd64`, `arm64`, `arm` and `ppc64le` are supported, matching upstream's
  release assets.
- Plugins from the krew index are community-published and **not audited** by the
  krew maintainers; krew prints this warning itself on each install.
