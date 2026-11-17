{
  inputs = {
    nidhogg-manifest.url = "github:NixVegas/nidhogg-manifest";
    # Update the lock for a new eval.
    target.url = "github:owner/project";
  };

  outputs =
    { nidhogg-manifest, target, ... }:
    {
      hydraJobs = nidhogg-manifest.lib.withManifests {
        flake = target;
        series = "project";
      };
    };
}
