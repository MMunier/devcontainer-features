# forgejo-cli (dev container feature)

Installs the [Forgejo CLI](https://codeberg.org/Forgejo-contrib/forgejo-cli)
(`fj`) so issues and pull requests can be read and filed from inside the
container:

```bash
fj issue search                       # open issues on the current repo
fj issue create "Title" --body "..."  # file a new task
fj issue view 42
fj issue comment 42 --body "..."
fj pr create --title "..."
```

The API token arrives **at runtime**, not build time, and is re-applied on every
attach — so the login survives rebuilds without a mounted volume, and rotating
the token means editing one file and reconnecting.

## Usage

```jsonc
{
  "features": {
    "ghcr.io/mmunier/devcontainer-features/forgejo-cli:1": {
      "host": "codeberg.org"
    }
  },
  // The token arrives at runtime, not build time — see below.
  "runArgs": ["--env-file", ".devcontainer/devcontainer.env"]
}
```

```bash
# .devcontainer/devcontainer.env  (gitignored — this one IS a secret)
FORGEJO_TOKEN=abcdef0123456789...
```

Create the token on your instance under **Settings → Applications → Access
Tokens**. For filing and commenting on issues it needs `read:user` and
`write:issue`; add `write:repository` if you also want to open PRs.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `version` | `latest` | Release to install, without the leading `v` (e.g. `0.6.0`). |
| `tokenEnv` | `FORGEJO_TOKEN` | Env var holding the API token, read at attach time. |
| `host` | `codeberg.org` | Instance the token authenticates against. Bare hostname. |
| `setDefaultHost` | `true` | Installs a wrapper supplying `--host`, so `fj` works outside a checkout. |

## How it works, and why

**The token is read at attach time, not build time.** A feature's options are
fixed when the *image* is built, so a build-time option would bake the secret
into an image layer — where it stays readable in the image history even after
it's rotated. Reading the environment on attach keeps it out of the image
entirely, lets the same image serve any user, and means the token can be changed
by editing the env file and reconnecting.

**It's re-applied on every attach, which is what persists the login.** This is a
different trick from [`claude-code-persist-login`](../claude-code-persist-login),
which keeps credentials in a named volume. Nothing is persisted here — the
credential is simply re-derived from the environment each time, so a rebuild
starts authenticated with no volume and no `postCreateCommand` chown.

**`fj auth add-token` refuses to overwrite, and still exits 0.** Given an
existing entry for the host it prints *"key for … already exists"* and returns
success without writing. Left alone, that means a rotated token is silently
ignored from the second attach onwards, while the attach output still claims
success. The attach script therefore runs `fj auth logout` first, so the new
value actually lands.

**The token is checked against the instance, not just stored.** `add-token` only
writes a file; it never contacts the server, so a typo'd or revoked token looks
identical to a good one until the first real command fails somewhere unrelated.
The attach runs `fj whoami` and reports the result. An unreachable instance is
reported differently from a rejected token — being offline at attach isn't a
broken setup.

**A missing token is a skip, not a failure.** Attach must not break because the
variable isn't set yet; the feature says what to set, and where, and carries on.

**`setDefaultHost` exists because `fj` has no default-host setting.** Outside a
checkout of a repo on the instance, `fj` fails with *"could not find host, try
specifying with --host"*. It reads no environment variable for this and stores
no default in its config, so the only way to supply one is on the command line —
hence a small wrapper at `/usr/local/bin/fj` that inserts `--host` when you
didn't. Explicit `--host`, `fj auth …`, and in-repo detection are all passed
through untouched; the real binary stays at `fj.real`.

## Notes

- Whitespace around the token is stripped: a trailing newline survives an env
  file easily and would otherwise produce 401s that look nothing like a
  whitespace problem.
- The token is passed to `fj` on **stdin**, never as a command-line argument,
  which would be visible in `/proc` to every process in the container.
- Upstream ships Linux binaries for `x86_64` and `aarch64` only. On other
  architectures the install fails with a pointer to
  `cargo install forgejo-cli --locked`.
- The keys file (`~/.local/share/forgejo-cli/keys.json`) holds the token in
  plaintext at mode 600, in a 700 directory — the same posture as `gh`.
