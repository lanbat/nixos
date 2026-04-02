# modules/common/ssh.nix
#
# Hardened OpenSSH server config shared by both machines.
{ ... }:

{
  services.openssh = {
    enable = true;

    settings = {
      # Disable password auth entirely — keys only.
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";

      # Reduce attack surface.
      X11Forwarding = false;
      AllowAgentForwarding = false;
      AllowTcpForwarding = "yes"; # needed for SSH tunnels to services
      PrintMotd = false;
    };

    # Limit to modern algorithms only.
    extraConfig = ''
      Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
      MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
      KexAlgorithms curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384
    '';
  };

  # sshd only listens; firewall rules are set per-host.
}
