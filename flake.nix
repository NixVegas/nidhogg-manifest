# Nidhogg eval manifests for another flake's Hydra jobs.
{
  description = "Nidhogg eval manifests for a flake's Hydra jobs";

  outputs =
    { self }:
    {
      lib = {
        # Nidhogg's own; manifest.nix is its file, unchanged.
        manifestJobs = args: import ./manifest.nix { inherit (args.pkgs) lib; } args;

        # `flake`'s hydraJobs and their manifests. One manifest per job by default: a
        # manifest evaluates every job it lists.
        withManifests =
          {
            flake,
            series,
            system ? "x86_64-linux",
            pkgs ?
              flake.inputs.nixpkgs.legacyPackages.${system}
                or (throw "nidhogg-manifest: the flake has no nixpkgs input to build the manifests with; pass pkgs"),
            shards ? null,
            ...
          }@args:
          let
            jobs = flake.hydraJobs;
            count = builtins.length (pkgs.lib.collect pkgs.lib.isDerivation jobs);
          in
          jobs
          // {
            nidhogg-manifest = self.lib.manifestJobs (
              removeAttrs args [
                "flake"
                "system"
              ]
              // {
                inherit pkgs jobs series;
                source = flake;
                shards = if shards == null then pkgs.lib.max 1 count else shards;
              }
            );
          };
      };

      templates.default = {
        path = ./template;
        description = "A Hydra jobset of another flake's jobs, with Nidhogg eval manifests";
      };
    };
}
