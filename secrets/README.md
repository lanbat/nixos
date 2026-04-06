# Secrets

Secrets are managed with [agenix](https://github.com/ryantm/agenix).

Each secret is an age-encrypted `.age` file in this directory.
They are decrypted at activation time using the host's SSH host key.

## Chicken-and-egg: secrets before first install

agenix encrypts secrets to the host SSH key — but the host doesn't exist yet
before the first install. The solution:

1. Add your **admin (workstation) public key** to `secrets.nix` now.
2. Encrypt all secrets with only the admin key initially.
3. After the first boot, get the host SSH key:
   ```bash
   ssh admin@server cat /etc/ssh/ssh_host_ed25519_key.pub
   ssh admin@pi5    cat /etc/ssh/ssh_host_ed25519_key.pub
   ```
4. Add the host keys to `secrets.nix`, then re-encrypt:
   ```bash
   cd secrets
   agenix -r
   ```

Until step 4, only your workstation can decrypt secrets (which is fine —
agenix decrypts them at activation time using whichever key is available).

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

The host keys are only available after first install — fill in `admin` first
and add the host keys in step 3a of the deployment checklist.

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

# ---- Telegraf ----
# Leave empty for now — fill in AFTER deploying InfluxDB and creating a
# write token in its UI (Data → API Tokens → Generate → Write to "metrics").
# One KEY=value line:
#   TELEGRAF_INFLUXDB_TOKEN=<write token>
agenix -e telegraf-token.age
```

### 3. Re-key after first install

Once you have the host SSH keys (see chicken-and-egg above):

```bash
# Update secrets/secrets.nix with the host keys, then:
agenix -r
```

### 4. Re-key if host keys change

If you reinstall a machine (new SSH host key), re-key secrets:

```bash
agenix -r
```

## Notes

- The `.age` files are safe to commit to git — they are encrypted.
- `secrets.nix` should also be committed (it only contains public keys).
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
| `rclone-frigate-config.age` | full rclone config file | Frigate rclone sync |
| `influxdb-admin-password.age` | plaintext password | InfluxDB initial setup |
| `influxdb-admin-token.age` | plaintext token | InfluxDB + Grafana datasource |
| `grafana-env.age` | `KEY=value` × 4 | Grafana |
| `vaultwarden-env.age` | `ADMIN_TOKEN=<value>` | Vaultwarden |
| `telegraf-token.age` | `TELEGRAF_INFLUXDB_TOKEN=<value>` | Telegraf (server + Pi) |
