# hosts/example-settings.nix
#
# Placeholder settings for the example-server and example-pi configurations,
# which CI and contributors evaluate. Addresses are from the documentation
# ranges (RFC 5737) and nothing here matches a real deployment.
#
# Your own values go in local.nix (see local.nix.example).
{
  lanbat = {
    domain = "home.example.com";
    rootDomain = "example.com";
    serverIp = "192.0.2.10";
    piIp = "192.0.2.11";
    gatewayIp = "192.0.2.1";
    lanSubnet = "192.0.2.0/24";
    serverHostname = "server";
    serverInterface = "eno1";
    piHostname = "pi5";
    piInterface = "end0";
    nfsIdmapdDomain = "home.lan";
    timezone = "UTC";
    phoneRegion = "GB";
    haLatitude = "51.5";
    haLongitude = "-0.1";
    haElevation = 0;
    zigbeeVendorId = "10c4";
    zigbeeProductId = "ea60";
    serverDisk = "/dev/disk/by-id/example-system-disk";
    piStorageDriveA = "example-storage-a";
    piStorageDriveB = "example-storage-b";
    piTvFrontend = true;
    haLlm = {
      baseUrl = "https://llm.example.com/v1";
      model = "example-model";
    };
    adminSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample example";
  };
}
