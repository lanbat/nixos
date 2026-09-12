# services/redis.nix
#
# Shared Redis instance; services use separate DB numbers:
#   DB 0 — Authentik  (sessions, cache)
#   DB 1 — Immich     (job queues, cache)
# Nothing is persisted (save = []): both consumers treat Redis as a cache.
{
  lanbat.services.redis.extraPorts = [ 6379 ];

  services.redis.servers.shared = {
    enable = true;
    port = 6379;
    bind = "127.0.0.1";
    save = [ ];
  };
}
