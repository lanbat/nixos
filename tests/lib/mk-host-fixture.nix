# tests/lib/mk-host-fixture.nix
#
# Deploy manifests and mkHost-built systems for VM tests, built from where the
# services run.
#
# A test describes its topology as host keys, their roles and what they run;
# everything else about a host (address, disks, storage drives, platform)
# comes from a template for its role:
#
#   fixture = import ./lib/mk-host-fixture.nix { inherit pkgs agenix inputs nixpkgs nixos-raspberrypi disko; };
#   topology = fixture.mkTopology {
#     hosts = {
#       server = { role = "server"; services = [ "mosquitto" "home-assistant" ]; };
#       kitchen = { role = "voice-pi"; };
#     };
#     deployment.voiceRooms.Kitchen = "kitchen";
#   };
#
#   nodes.server = topology.nodeRunning "home-assistant";
#   nodes.kitchen = topology.nodes.kitchen;
#
# A host entry takes:
#
#   role        server, storage-pi or voice-pi (required)
#   services    names from the service registry, as in hosts.<key>.services;
#               empty (the default) runs everything the host's plugins offer
#   plugins     names from the plugin registry (plugins/default.nix); by
#               default every registered plugin that supports the role, except
#               those the VM tests leave out
#   networking  overrides for the template's ip, interface and hostname
#   anything else a deploy host entry takes (disks, storage, overlay,
#   modules), merged over the role's template
#
# Addresses come from 192.0.2.0/24 on eth1: hosts are numbered from .10 in role
# order (server, storage-pi, voice-pi), then by key. A host's hostname is its
# key.
#
# The topology returned carries the deploy manifest, the systems mkHost builds
# (systems.<key>), a runNixOSTest node module per host (nodes.<key>), the
# profile-wide endpoint table, and lookups by service: hostsRunning, hostRunning
# and nodeRunning.
#
# `default` is the topology the Pi tests have always used: a server running
# every service, a storage Pi and a voice Pi.
{
  pkgs,
  agenix,
  inputs,
  nixpkgs,
  nixos-raspberrypi,
  disko,
}:

let
  lib = nixpkgs.lib;

  inherit (import ../../lib/plugins.nix { inherit lib; }) knownRoles;
  endpointLib = import ../../lib/endpoints.nix { inherit lib; };
  validateLib = import ../../lib/validate-deploy.nix { inherit lib; };
  mkHost = import ../../lib/mkHost.nix;

  # The registry flake.nix exposes as self.lanbatPlugins, so a plugin added
  # there reaches the fixture without being listed again here.
  lanbatPlugins = import ../../plugins;

  # Registry plugins the VM tests leave out by default. tv drives the HDMI
  # output and pulls Kodi and the emulators into a VM that has no display.
  vmExcludedPlugins = [ "tv" ];

  # By default a host enables each registered plugin that supports its role, as
  # a deployment enabling everything would, so no plugin's services drop out of
  # the descriptions pass and the endpoint table.
  defaultPlugins =
    role:
    lib.attrNames (
      lib.filterAttrs (
        name: plugin: !(lib.elem name vmExcludedPlugins) && lib.elem role plugin.roles
      ) lanbatPlugins
    );

  pluginByName =
    name:
    lanbatPlugins.${name} or (builtins.throw (
      "mk-host-fixture: no plugin named '${name}' in plugins/default.nix. Registered: "
      + lib.concatStringsSep ", " (lib.attrNames lanbatPlugins)
    ));

  baseDeployment = {
    domain = "home.test";
    rootDomain = "test";
    # The VM tests supply their own throwaway secrets through
    # tests/lib/test-secrets.nix, so this fixture needs no encrypted files.
    secrets = {
      provider = "none";
      root = ../../secrets;
    };
    gatewayIp = "192.0.2.1";
    lanSubnet = "192.0.2.0/24";
    nfsIdmapdDomain = "home.test";
    timezone = "UTC";
    phoneRegion = "GB";
    haLatitude = "51.5";
    haLongitude = "-0.1";
    haElevation = 0;
    zigbeeVendorId = "10c4";
    zigbeeProductId = "ea60";
    adminSshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExampleExample test";
    haLlm = {
      baseUrl = "https://llm.test/v1";
      model = "test-model";
    };
    # The xiaomi-clock plugin configures nothing without a device, so give it
    # the documentation address the example profile uses.
    xiaomiClocks = [ "A4:C1:38:00:00:01" ];
  };

  # The boring parts of a deploy host entry, per role.
  roleTemplates = {
    server =
      placement:
      let
        services = placement.services or [ ];
      in
      {
        system = "x86_64-linux";
        disks.system = "/dev/disk/by-id/test-system-disk";
        # The fixture has no cameras; Frigate refuses that unless told.
        modules = lib.optional (services == [ ] || lib.elem "frigate" services) {
          lanbat.services.frigate.settings.allowNoCameras = true;
        };
      };

    storage-pi = _: {
      system = "aarch64-linux";
      platform = "raspberry-pi-5";
      storage.drives = {
        a = "test-storage-a";
        b = "test-storage-b";
      };
    };

    voice-pi = _: {
      system = "aarch64-linux";
      platform = "raspberry-pi-5";
    };
  };

  roleIndex = role: lib.lists.findFirstIndex (r: r == role) null knownRoles;

  # Turns placement entries into deploy host entries.
  hostsFromPlacement =
    placement:
    let
      unknownRoles = lib.filterAttrs (_: p: !(roleTemplates ? ${p.role or ""})) placement;

      # Role order, then key, numbers the hosts for their addresses.
      ordered = lib.sort (
        a: b:
        let
          ra = roleIndex placement.${a}.role;
          rb = roleIndex placement.${b}.role;
        in
        if ra != rb then ra < rb else a < b
      ) (lib.attrNames placement);
      numbers = lib.listToAttrs (lib.imap0 (i: key: lib.nameValuePair key (10 + i)) ordered);

      mkEntry =
        key: p:
        let
          template = roleTemplates.${p.role} p;
          entry = lib.recursiveUpdate template (
            removeAttrs p [
              "plugins"
              "modules"
            ]
          );
        in
        entry
        // {
          # eth1 is the interface runNixOSTest attaches to the test VLAN, so
          # the static addresses reach the other nodes.
          networking = {
            ip = "192.0.2.${toString numbers.${key}}";
            interface = "eth1";
            hostname = key;
          }
          // (entry.networking or { });
          plugins = map pluginByName (p.plugins or (defaultPlugins p.role));
          modules = (template.modules or [ ]) ++ (p.modules or [ ]);
        };
    in
    if unknownRoles != { } then
      builtins.throw (
        "mk-host-fixture: host(s) "
        + lib.concatStringsSep ", " (lib.attrNames unknownRoles)
        + " need a role, one of: "
        + lib.concatStringsSep ", " (lib.attrNames roleTemplates)
      )
    else
      lib.mapAttrs mkEntry placement;

  # What a runNixOSTest node needs on top of a host's own modules. The node is
  # evaluated by the test's nixpkgs rather than by mkHost, for the test's
  # platform.
  commonVmModule =
    { lib, ... }:
    {
      nixpkgs.hostPlatform = lib.mkForce pkgs.stdenv.hostPlatform.system;

      services.timesyncd.enable = lib.mkForce false;

      lanbat.testSecrets.telegraf-token = "TELEGRAF_INFLUXDB_TOKEN=test-influx-token\n";
      lanbat.testSecrets.ha-voice-token = "test-voice-token";
    };

  piVmModule =
    { lib, ... }:
    {
      virtualisation.memorySize = 2048;

      # OSTest provides a virtio root disk; Pi SD labels from hardware.nix are absent.
      fileSystems."/" = lib.mkForce {
        device = "/dev/vda";
        fsType = "ext4";
      };
      fileSystems."/boot/firmware".device = lib.mkForce "/dev/vda";
      boot.loader.grub.enable = lib.mkForce true;
    };

  # The server's locked layers go on two empty virtio disks, as in
  # tests/server.nix.
  serverVmModule =
    { config, lib, ... }:
    {
      # mkHost passes inputs as a special argument; services/zigbee2mqtt.nix
      # reads it.
      _module.args.inputs = inputs;

      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 8192;
        emptyDiskImages = [
          64
          2048
        ];
        fileSystems = config.lanbat.layers.controlFileSystems // config.lanbat.layers.workloadFileSystems;
      };

      lanbat.layers = {
        controlDevice = lib.mkForce "/dev/vdb";
        workloadDevice = lib.mkForce "/dev/vdc";
      };
    };

  # VM tests use virtio disks, not Pi SD labels; skip hardware.nix (needs nixos-raspberrypi).
  hardwareModule = ../../hosts/pi5/hardware.nix;

  vmModulesFor =
    hostCfg:
    [
      ./test-secrets.nix
      commonVmModule
    ]
    ++ (if hostCfg.role == "server" then [ serverVmModule ] else [ piVmModule ]);

  mkTopology =
    {
      hosts,
      # Merged over the fixture's deployment settings, one attribute at a time.
      deployment ? { },
      profileName ? "test",
    }:
    let
      deploy = validateLib.validateDeploy {
        inherit profileName;
        deploy = {
          deployment = baseDeployment // deployment;
          hosts = hostsFromPlacement hosts;
        };
      };

      buildHost =
        endpoints: hostName: hostCfg:
        mkHost {
          inherit
            lib
            inputs
            agenix
            disko
            nixos-raspberrypi
            profileName
            hostName
            hostCfg
            endpoints
            ;
          deployment = deploy.deployment;
          hosts = deploy.hosts;
        };

      # The same two passes lib/default.nix runs: descriptions first, then the
      # profile-wide table, then the hosts. Every host in the manifest takes
      # part, because a host has to see the accounts and addresses of services
      # that run elsewhere.
      described = lib.mapAttrs (
        hostName: hostCfg: (buildHost { } hostName hostCfg).config.lanbat.services
      ) deploy.hosts;

      endpoints = endpointLib.mkTable {
        inherit profileName described;
        hosts = deploy.hosts;
      };

      systems = lib.mapAttrs (buildHost endpoints) deploy.hosts;

      nodes = lib.mapAttrs (
        hostName: hostCfg:
        { ... }:
        {
          imports =
            lib.filter (m: m != hardwareModule) systems.${hostName}.lanbatModules ++ vmModulesFor hostCfg;
        }
      ) deploy.hosts;

      hostsRunning = name: (endpoints.${name} or { hosts = [ ]; }).hosts;

      hostRunning =
        name:
        endpointLib.soleHost {
          inherit endpoints name;
          consumer = "mk-host-fixture's hostRunning";
        };
    in
    {
      inherit
        profileName
        deploy
        endpoints
        systems
        nodes
        hostsRunning
        hostRunning
        ;
      nodeRunning = name: nodes.${hostRunning name};
    };

  default = mkTopology {
    hosts = {
      server.role = "server";
      pi-storage = {
        role = "storage-pi";
        # tests/storage-pi.nix checks for this address on eth1. It predates the
        # template and sits on the test driver's own VLAN subnet.
        networking = {
          ip = "192.168.1.2";
          hostname = "pi5";
        };
      };
      voice-pi.role = "voice-pi";
    };
    deployment.voiceRooms = {
      "Living Room" = "pi-storage";
    };
  };
in
{
  inherit mkTopology default;
}
