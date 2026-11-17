# nix-instantiate --eval --strict test.nix -I nixpkgs=flake:nixpkgs
let
  pkgs = import <nixpkgs> { };
  flake = (import ./flake.nix).outputs { self = flake; };
  inherit (pkgs.stdenv.hostPlatform) system;
  job =
    name:
    derivation {
      inherit name system;
      builder = "/bin/sh";
    };
  # The parts of a flake input that the wrapper reads.
  target = {
    rev = "0123456789abcdef0123456789abcdef01234567";
    lastModified = 1800000000;
    inputs.nixpkgs.legacyPackages.${system} = pkgs;
    hydraJobs = {
      a = job "a";
      b.c = job "c";
      b.d = job "d";
    };
  };
  jobs = flake.lib.withManifests {
    flake = target;
    series = "test";
    inherit system;
  };
  shards = builtins.attrNames jobs.nidhogg-manifest;
  manifests = map (shard: builtins.fromJSON jobs.nidhogg-manifest.${shard}.manifestText) shards;
  listed = builtins.concatMap (m: map (o: o.attr) m.outputs) manifests;
  expect =
    what: got: want:
    if got == want then true else throw "${what}: ${builtins.toJSON got}";
in
assert expect "the target's jobs are kept"
  (builtins.attrNames (removeAttrs jobs [ "nidhogg-manifest" ]))
  [
    "a"
    "b"
  ];
assert expect "one manifest for each job" shards [
  "shard-0"
  "shard-1"
  "shard-2"
];
assert expect "each job listed once" (builtins.sort builtins.lessThan listed) [
  "a"
  "b.c"
  "b.d"
];
assert expect "the series" (map (m: m.series) manifests) [
  "test"
  "test"
  "test"
];
assert expect "the target's rev" (builtins.head manifests).source {
  inherit (target) rev lastModified;
};
assert expect "a shard count that is set is kept" (builtins.attrNames
  (flake.lib.withManifests {
    flake = target;
    series = "test";
    inherit system;
    shards = 1;
  }).nidhogg-manifest
) [ "shard-0" ];
"ok"
