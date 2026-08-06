# ssh-signing-key (dev container feature)

Wires up git SSH commit signing inside a dev container for a **hardware-backed**
key — e.g. a YubiKey `sk-ssh-ed25519` resident key.

The private half never enters the container. Signing goes out through your
**host's** ssh-agent over VS Code's automatic agent-forwarding socket; this
feature only wires the container side.

## Usage

```jsonc
{
  "features": {
    "ghcr.io/mmunier/devcontainer-features/ssh-signing-key:1": {}
  },
  // The public key arrives at runtime, not build time — see below.
  "runArgs": ["--env-file", ".devcontainer/devcontainer.env"]
}
```

```bash
# .devcontainer/devcontainer.env  (gitignored)
# One line, from `cat ~/.ssh/id_ed25519_sk.pub` on your HOST. Not a secret.
SSH_SIGNING_PUBKEY=sk-ssh-ed25519@openssh.com AAAA... you@your-host
```

Then, **on the host**, make the key visible to the forwarded agent:

```bash
ssh-add ~/.ssh/id_ed25519_sk
ssh-add -l   # should list it
```

## Options

| Option | Default | Description |
| --- | --- | --- |
| `pubkeyEnv` | `SSH_SIGNING_PUBKEY` | Env var holding the PUBLIC key, read at attach time. |
| `keyFilename` | `id_ed25519_sk.pub` | Filename written under `~/.ssh`. Must be a bare filename. |
| `signAllCommits` | `true` | Sets `commit.gpgsign=true`. Turn off to sign only on demand with `-S`. |

## How it works, and why

**The key is read at attach time, not build time.** A feature's options are
fixed when the *image* is built, and `runArgs: --env-file` only applies at
`docker run` — so a value in that env file can never reach a build-time option.
Reading the environment on attach means the same image works for any user, and
no one has to remember to source anything before launching VS Code.

**Config is reasserted on every attach, not just on create.** VS Code re-copies
`~/.gitconfig` from the host on each connect. A create-time-only setup gets
clobbered by the host's `user.signingkey`, which points at a path that doesn't
exist in the container — and commits then fail with a confusing error.

**A missing key is a skip, not a failure.** Attach must not break because the
variable isn't set yet; the feature says what to set and carries on.

**A private key is refused.** `SSH_SIGNING_PUBKEY` takes the `.pub` file. If the
value looks like a private key it is rejected rather than written to disk and
handed to git as though it were public.

**The forwarded agent is checked.** With the key installed but no keys in the
agent, signing fails later at commit time with a message that doesn't obviously
point back here — so it warns at attach instead.

## Notes

- A public key is not a secret; it's kept in the env file for convenience, not
  confidentiality.
- Requires agent forwarding. VS Code does this automatically; with the bare
  `devcontainer` CLI it does not, so use `ssh -A` into the container (see the
  [`authorized-key`](../authorized-key) feature).
