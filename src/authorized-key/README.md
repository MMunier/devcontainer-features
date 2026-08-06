# authorized-key (dev container feature)

Installs one or more SSH public keys into a user's `~/.ssh/authorized_keys`
with correct `700`/`600` permissions. Pairs with the `sshd` feature so a
devcontainer accepts key-based login — including FIDO/`sk-*` YubiKey keys — and
agent forwarding via `ssh -A`.

## Why

The official `sshd` feature has no option to inject an authorized key; it
expects you to set a password manually after the container is up. This feature
fills that gap declaratively, at build time.

## Usage

```jsonc
"features": {
  "ghcr.io/devcontainers/features/sshd:1": {},
  "ghcr.io/mmunier/features/authorized-key:1": {
    "publicKey": "sk-ssh-ed25519@openssh.com AAAA... user@host"
  }
}
```

Then, from the host (YubiKey plugged in, key loaded via `ssh-add`):

```bash
ssh -A -p 2222 vscode@localhost
```

## Options

| Option | Default | Description |
| --- | --- | --- |
| `publicKey` | `""` | Public key line(s) to authorize. A pubkey is not a secret, so hardcoding is safe. Separate multiple keys with `\n`. |
| `targetUser` | `automatic` | User whose `authorized_keys` is written. `automatic` → `_REMOTE_USER` (e.g. `vscode`). |

## Notes

- Idempotent: re-running (rebuilds, layer caching) won't duplicate keys.
- A public key is not a secret — safe to commit. Do **not** put a private key here.
- Resolves the target user's home from the passwd DB, so it works for users
  whose home isn't `/home/<user>`.
