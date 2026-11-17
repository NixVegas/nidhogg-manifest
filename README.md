# nidhogg-manifest

Eval manifests for Nidhogg, for any flake's Hydra jobs.
A manifest lists the outputs of one eval of a jobset.

## A jobset of another flake

Hydra cannot pass arguments to a flake jobset, so the jobset is a small flake of its own:

```console
$ nix flake init -t github:NixVegas/nidhogg-manifest
```

```nix
{
  inputs = {
    nidhogg-manifest.url = "github:NixVegas/nidhogg-manifest";
    target.url = "github:owner/project";
  };

  outputs = { nidhogg-manifest, target, ... }: {
    hydraJobs = nidhogg-manifest.lib.withManifests {
      flake = target;
      series = "project";
    };
  };
}
```

Point a Hydra flake jobset at it. Updating `target` in its lock makes a new eval. The
manifests take the rev and date of `target`, not of the wrapper.

Nidhogg takes the manifests of a series it is told of:

```toml
[[series]]
name = "project"
keys = ["builder-1:…"]   # the keys that sign what Hydra builds
pushers = ["hydra"]      # the credentials that may push them
```

## `lib.withManifests`

`flake`'s `hydraJobs`, with `nidhogg-manifest` beside them.

| Argument  | Default                          | Meaning |
|-----------|----------------------------------|---------|
| `flake`   | required                         | The flake whose jobs are listed. |
| `series`  | required                         | The name of the `[[series]]` the manifests belong to. |
| `system`  | `"x86_64-linux"`                 | The system the manifests are built on. |
| `pkgs`    | `flake`'s `nixpkgs` for `system` | Builds the manifests: bash and coreutils. |
| `shards`  | one for each job                 | How many manifests. Each evaluates the jobs it lists. |
| `systems` | `null`                           | Split jobs named `<attr>.<system>` into manifests per system. |
| `sources` | `false`                          | Also list fixed-output inputs (source tarballs, patches). |

One manifest for each job keeps each no heavier to evaluate than its job. A jobset of
thousands of jobs, such as nixpkgs' `release.nix`, wants `systems` and a few `shards` for
each.

## `lib.manifestJobs`

The manifests alone, for a flake that adds them to its own `hydraJobs`. It is Nidhogg's
`lib.manifestJobs`, and `manifest.nix` is Nidhogg's file as it is; its header says how to
use it.

## Testing

```console
$ nix-instantiate --eval --strict test.nix -I nixpkgs=flake:nixpkgs
"ok"
```
