# Secrets

Secrets are managed with [agenix](https://github.com/ryantm/agenix).

Each secret is an age-encrypted `.age` file in this directory.
They are decrypted at activation time using the host's SSH host key.

Services declare the secrets they read in `lanbat.services.<name>.secrets`; each entry
`<secret> = { }` refers to `secrets/<secret>.age` and is decrypted to
`/run/agenix/<secret>`.

## Chicken-and-egg: secrets before first install

agenix encrypts secrets to the host SSH key — but the host doesn't exist yet
before the first install. The solution:

1. Add your **admin (workstation) public key** to `secrets.nix` and encrypt all
   secrets with it.
2. **Server:** create its SSH host key on your workstation before installing, add the
   public key to `secrets.nix`, run `agenix -r`, and pass the key to nixos-anywhere with
   `--extra-files` (`docs/deployment-checklist.md` step 1c). The server can decrypt its
   secrets on first boot.
3. **Pi:** read the host key of the booted SD image
   (`ssh nixos@<pi-ip> cat /etc/ssh/ssh_host_ed25519_key.pub`), add it to `secrets.nix`
   and run `agenix -r` before the first switch (step 2e).

## Setup

### 1. Create your secrets.nix

`secrets/secrets.nix` is gitignored (like `local.nix`) — it contains real
SSH public keys that identify your machines and should not be committed.

```bash
cp secrets/secrets.nix.example secrets/secrets.nix
```

Fill in the three keys:

```nix
server = "ssh-ed25519 AAAA...";   # from: ssh admin@server cat /etc/ssh/ssh_host_ed25519_key.pub
pi     = "ssh-ed25519 AAAA...";   # from: ssh admin@pi5    cat /etc/ssh/ssh_host_ed25519_key.pub
admin  = "ssh-ed25519 AAAA...";   # from: cat ~/.ssh/id_ed25519.pub
```

Fill in `admin` first and add the host keys at steps 1c and 2e of the deployment
checklist.

### 2. Create all required secrets

Run the generator script — it creates all purely-random secrets automatically:

```bash
bash secrets/generate-secrets.sh
```

For secrets that need manual input (MQTT passwords, rclone config, Telegraf
token), the script prints instructions at the end.

Once Authentik is deployed and running, generate the OIDC client secrets with:

```bash
bash secrets/generate-oidc-secrets.sh
```

This creates `authentik-oidc-secrets.age` and wires the matching secrets into
`grafana-env.age`, `nextcloud-oidc-env.age`, and `immich-oidc-env.age`.  It
also prints the client credentials needed for manual UI setup in Home Assistant
and Jellyfin.

The full list for reference:

```bash
cd secrets

# ---- Authentik ----
# Two KEY=value lines:
#   AUTHENTIK_POSTGRESQL__PASSWORD=<random string>
#   AUTHENTIK_SECRET_KEY=<50+ random chars>
#
# Generate with:
#   openssl rand -base64 36   # AUTHENTIK_POSTGRESQL__PASSWORD
#   openssl rand -base64 50   # AUTHENTIK_SECRET_KEY
#
# AUTHENTIK_SECRET_KEY signs sessions and tokens — generate once and never
# rotate unless you intend to invalidate all active sessions.
agenix -e authentik-env.age

# ---- Nextcloud ----
# Single-line plaintext password:
agenix -e nextcloud-db-pass.age
agenix -e nextcloud-admin-pass.age
# Two KEY=value lines (fill in after creating Authentik OIDC app):
#   NEXTCLOUD_OIDC_CLIENT_ID=<value>
#   NEXTCLOUD_OIDC_CLIENT_SECRET=<value>
agenix -e nextcloud-oidc-env.age

# ---- Immich ----
# One KEY=value line:
#   POSTGRES_PASSWORD=<random string>
agenix -e immich-db-password.age
# Two KEY=value lines (fill in after creating Authentik OIDC app):
#   IMMICH_OAUTH_CLIENT_ID=<value>
#   IMMICH_OAUTH_CLIENT_SECRET=<value>
agenix -e immich-oidc-env.age

# ---- Mosquitto ----
# Each file: single-line plaintext password
agenix -e mosquitto-ha-pass.age
agenix -e mosquitto-frigate-pass.age

# ---- Frigate ----
# Full rclone config file — run: rclone config, then paste the result.
# See: https://rclone.org/docs/
agenix -e rclone-frigate-config.age

# ---- InfluxDB ----
# Single-line plaintext password for the admin user:
agenix -e influxdb-admin-password.age
# Single-line operator token (used by both InfluxDB and Grafana):
#   openssl rand -base64 48
agenix -e influxdb-admin-token.age

# ---- Grafana ----
# Four KEY=value lines:
#   GF_SECURITY_SECRET_KEY=<openssl rand -base64 48>
#   GF_SECURITY_ADMIN_PASSWORD=<break-glass password>
#   GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<from Authentik UI>
#   INFLUXDB_TOKEN=<same value as influxdb-admin-token.age>
agenix -e grafana-env.age

# ---- Vaultwarden ----
# One KEY=value line:
#   ADMIN_TOKEN=<openssl rand -base64 48>
agenix -e vaultwarden-env.age

# ---- Caddy internal CA ----
# Created once when pinning the root CA (see services/caddy.nix). The public
# cert is secrets/caddy-ca-root.crt (committed). Encrypt the private key:
#   agenix -e caddy-ca-root-key.age < /path/to/root.key
# To rotate deliberately: generate a new root, re-encrypt, redeploy, then
# redistribute ca.<domain>/root.crt to every client.

# ---- Telegraf ----
# Leave empty for now — fill in AFTER deploying InfluxDB and creating a
# write token in its UI (Data → API Tokens → Generate → Write to "metrics").
# One KEY=value line:
#   TELEGRAF_INFLUXDB_TOKEN=<write token>
agenix -e telegraf-token.age
```

### 3. Re-key if host keys change

If you reinstall a machine with a new SSH host key, update `secrets/secrets.nix`, then:

```bash
agenix -r
```

## Notes

- The `.age` files are safe to commit to git — they are encrypted.
- `secrets.nix` stays local (gitignored); `secrets.nix.example` is the committed
  template listing every file and its recipients.
- **Never commit plaintext values.**
- The `admin` key allows editing secrets from your workstation without
  needing a running host.

## Complete secret inventory

| File | Format | Used by |
|------|--------|---------|
| `authentik-env.age` | `KEY=value` × 2 | Authentik server + worker |
| `nextcloud-db-pass.age` | plaintext password | Nextcloud |
| `nextcloud-admin-pass.age` | plaintext password | Nextcloud |
| `nextcloud-oidc-env.age` | `KEY=value` × 2 | Nextcloud OIDC setup |
| `immich-db-password.age` | `POSTGRES_PASSWORD=<value>` | Immich postgres container |
| `immich-oidc-env.age` | `KEY=value` × 2 | Immich server container |
| `mosquitto-ha-pass.age` | plaintext password | Mosquitto (Home Assistant user) |
| `mosquitto-frigate-pass.age` | plaintext password | Mosquitto (Frigate user) |
| `frigate-rtsp-env.age` | `FRIGATE_RTSP_USER=<value>`, `FRIGATE_RTSP_PASSWORD=<value>` | Frigate camera RTSP auth |
| `rclone-frigate-config.age` | full rclone config file | Frigate rclone sync |
| `influxdb-admin-password.age` | plaintext password | InfluxDB initial setup |
| `influxdb-admin-token.age` | plaintext token | InfluxDB + Grafana datasource |
| `grafana-env.age` | `KEY=value` × 4 | Grafana |
| `vaultwarden-env.age` | `ADMIN_TOKEN=<value>` | Vaultwarden |
| `telegraf-token.age` | `TELEGRAF_INFLUXDB_TOKEN=<value>` | Telegraf (server + Pi) |
| `caddy-ca-root.crt` | PEM root certificate (public) | Caddy internal CA — committed plaintext |
| `caddy-ca-root-key.age` | PEM EC private key | Caddy internal CA — agenix, owner `caddy` |
