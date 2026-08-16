# github-cli-auth (dev container feature)

Authenticates the [GitHub CLI](https://cli.github.com/) (`gh`) from a token
supplied at **runtime**, so issues and pull requests can be read and filed from
inside the container:

```bash
gh issue list
gh issue create --title "Title" --body "..."
gh issue comment 42 --body "..."
gh pr create --fill
```

Installing `gh` is left to the **official**
[`github-cli`](https://github.com/devcontainers/features/tree/main/src/github-cli)
feature, declared here as a dependency. What this adds is the auth wiring, which
that feature deliberately leaves to you.

## Usage

```jsonc
{
  "features": {
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "ghcr.io/mmunier/devcontainer-features/github-cli-auth:1": {}
  },
  // The token arrives at runtime, not build time — see below.
  "runArgs": ["--env-file", ".devcontainer/devcontainer.env"]
}
```

```bash
# .devcontainer/devcontainer.env  (gitignored — this one IS a secret)
GH_TOKEN=ghp_...
```

Create the token at **Settings → Developer settings → Personal access tokens**.
`gh` wants `repo`, `read:org`, and `gist` for its full feature set.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `tokenEnv` | `GH_TOKEN` | Env var holding the token. The default is the name `gh` already reads. |
| `host` | `github.com` | Host the token authenticates against. Set to a GHE hostname to target that instance. |
| `setupGit` | `true` | Runs `gh auth setup-git` so `git push` over HTTPS uses the token. |

## How it works, and why

**Nothing is written to disk for `gh` itself.** Unlike most CLIs, `gh` reads
`GH_TOKEN` straight from the environment, so there is no credential file to
create, persist, or leak. That makes the login survive rebuilds for free — the
token is simply present in the environment every time the container starts.

**So why a feature at all?** Two things still need doing, and both are
attach-time work the official feature doesn't cover:

**1. `git push` over HTTPS.** `gh auth setup-git` registers `gh` as a git
credential helper, which is what lets `git push` work without a separate
credential. It writes into `~/.gitconfig` — and VS Code **re-copies
`~/.gitconfig` from the host on every attach**, silently dropping the helper. A
create-time-only setup therefore breaks on the second connect. This is the same
constraint [`ssh-signing-key`](../ssh-signing-key) works around, and the reason
the config is reasserted on every attach rather than once.

**2. Enterprise hosts read a different variable.** For any host other than
`github.com`, `gh` ignores `GH_TOKEN` and reads `GH_ENTERPRISE_TOKEN`. Setting
the obvious variable leaves the CLI silently unauthenticated against a GHE
instance. Point `host` at your instance and the right variable is exported,
along with `GH_HOST` so commands don't each need `--hostname`.

**The token is exported by reference, never by value.** The snippet written to
`~/.github-cli-auth.sh` contains `export GH_TOKEN="${GH_TOKEN:-}"` — a reference
to the variable already in the environment, not the secret itself. Nothing on
disk ever holds the token, which is why the file survives inspection and backup
without being a liability. (It is still mode 600.)

**The token is checked, not just configured.** `gh` only validates a token when
it makes a call, so a typo'd or revoked one looks identical to a good one until
some later command fails confusingly. The attach runs `gh auth status` and
reports the result — distinguishing a **rejected token** from an **unreachable
host**, since being offline at attach is not a broken setup.

**A missing token is a skip, not a failure.** Attach must not break because the
variable isn't set yet; the feature says what to set, and where, and carries on.

## Notes

- Whitespace around the token is stripped: a trailing newline survives an env
  file easily and would otherwise go out in the `Authorization` header verbatim.
- The rc hook is appended once, guarded, so repeated attaches don't grow
  `~/.bashrc` without bound.
- Rotating the token means editing the env file and reconnecting — no rebuild.
- Compare [`forgejo-cli`](../forgejo-cli), which solves the same problem for a
  CLI that has **no** environment-variable auth and must be given a stored
  credential on every attach.
