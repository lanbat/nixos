# pkgs/overlay-keys
#
# nix run .#overlay-keys — WireGuard keypairs for the wireguard-mesh overlay.
#
# For each host it generates a private key, encrypts it straight into
# <secrets-dir>/overlay-<host>.age with agenix (the plaintext is never written
# to disk), and prints the public keys ready to paste into deploy.nix. A host
# that already has a key keeps it; its public key is printed when the key can
# be decrypted with your agenix identity.
{
  writeShellApplication,
  wireguard-tools,
  agenix,
  nix,
}:

writeShellApplication {
  name = "overlay-keys";
  runtimeInputs = [
    wireguard-tools
    agenix
    nix
  ];
  text = builtins.readFile ./overlay-keys.sh;
}
