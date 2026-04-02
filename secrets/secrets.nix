# secrets/secrets.nix
#
# agenix recipients configuration.
# Maps each .age secret file to the public keys that can decrypt it.
#
# HOW TO USE
# ----------
# 1. Fill in the public keys below after the first nixos-install on each machine:
#      ssh admin@server  cat /etc/ssh/ssh_host_ed25519_key.pub
#      ssh admin@pi5     cat /etc/ssh/ssh_host_ed25519_key.pub
# 2. Add your own SSH public key as "admin" so you can edit secrets without
#    needing a running host.
# 3. Create secrets with:
#      cd secrets
#      agenix -e <name>.age
# 4. Commit the .age files (they are safe to commit — encrypted).
#
# NEVER commit the plaintext values.
let
  # Host SSH public keys — fill these in after first install.
  server = "ssh-ed25519 CHANGE_ME_SERVER_HOST_KEY";
  pi     = "ssh-ed25519 CHANGE_ME_PI_HOST_KEY";

  # Your personal SSH public key — allows editing secrets from your workstation.
  admin  = "ssh-ed25519 CHANGE_ME_ADMIN_PERSONAL_KEY";

  # Hosts that need each secret.
  serverKeys = [ server admin ];
  piKeys     = [ pi admin ];
  allKeys    = [ server pi admin ];
in
{
  # ---- Authentik ----
  "authentik-env.age".publicKeys = serverKeys;

  # ---- Nextcloud ----
  "nextcloud-db-pass.age".publicKeys    = serverKeys;
  "nextcloud-admin-pass.age".publicKeys = serverKeys;
  "nextcloud-oidc-env.age".publicKeys   = serverKeys;

  # ---- Immich ----
  "immich-db-password.age".publicKeys = serverKeys;
  "immich-oidc-env.age".publicKeys    = serverKeys;

  # ---- Frigate ----
  "rclone-frigate-config.age".publicKeys = serverKeys;

  # ---- MQTT ----
  "mosquitto-ha-pass.age".publicKeys     = serverKeys;
  "mosquitto-frigate-pass.age".publicKeys = serverKeys;

  # ---- InfluxDB ----
  "influxdb-admin-password.age".publicKeys = serverKeys;
  "influxdb-admin-token.age".publicKeys    = serverKeys;

  # ---- Grafana ----
  # File format (one KEY=value per line):
  #   GF_SECURITY_SECRET_KEY=<64-char random string>
  #   GF_SECURITY_ADMIN_PASSWORD=<break-glass admin password>
  #   GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET=<from Authentik UI>
  #   INFLUXDB_TOKEN=<same value as influxdb-admin-token.age>
  "grafana-env.age".publicKeys = serverKeys;

  # ---- Telegraf ----
  # File format (one line):
  #   TELEGRAF_INFLUXDB_TOKEN=<write token for the metrics bucket>
  # Create this token in InfluxDB UI after first deploy:
  #   Data → API Tokens → Generate API Token → Write to "metrics" bucket
  "telegraf-token.age".publicKeys = allKeys;

  # ---- Vaultwarden ----
  "vaultwarden-env.age".publicKeys = serverKeys;

}
