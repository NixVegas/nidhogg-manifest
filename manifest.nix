# nidhogg.lib.manifestJobs: a flake's Hydra jobs as sharded Nidhogg eval manifests. Add the
# result to hydraJobs next to the jobs it lists:
#
#   hydraJobs = let jobs = { … }; in jobs // {
#     nidhogg-manifest = nidhogg.lib.manifestJobs {
#       inherit pkgs jobs; series = "badgeos"; source = self;
#     };
#   };
#
# A manifest is a small derivation with no store references (out paths are listed with
# their string context discarded), so it builds as soon as the eval is queued, before the
# builds it lists. The job attribute paths are split into shards and each shard evaluates
# only its own jobs, because one job that forced every out path of nixpkgs would exceed
# the evaluator's memory.
{ lib }:
{
  # Only `bash`, `coreutils` and `stdenv.hostPlatform.system` are used.
  pkgs,
  # The name of the `[[series]]` these evals belong to.
  series,
  # The flake whose rev and lastModified identify the eval: inputs.nixpkgs for a nixpkgs
  # wrapper, self for a project.
  source,
  # The jobs to list. Bind them before adding the manifest, or it lists itself.
  jobs,
  shards ? 1,
  # With a list of systems, jobs named `<attr>.<system>` (as in nixpkgs' release.nix) are
  # split per system and the rest go under `other`. Without one, the result is flat.
  systems ? null,
  # List each output with the job's attribute path.
  attrs ? true,
  # Also list fixed-output inputs (source tarballs, patches), found by walking each job's
  # `drvAttrs`. This walks the derivation graph, and finds nothing for jobs reduced by
  # `lib.hydraJob` (release.nix's `scrubJobs`).
  sources ? false,
}:
let
  rev =
    source.rev
      or (throw "nidhogg.lib.manifestJobs: the source has no rev (a dirty tree?); a manifest must name the rev it lists");

  tryOr =
    default: v:
    let
      r = builtins.tryEval v;
    in
    if r.success then r.value else default;

  # tryEval alone evaluates only to weak head normal form.
  tryDeep = default: v: tryOr default (builtins.deepSeq v v);

  isSystem = path: systems != null && path != [ ] && lib.elem (lib.last path) systems;

  # Every derivation at or under `path`, with its attribute path.
  leaves =
    path: v:
    if tryOr false (lib.isDerivation v) then
      [
        {
          inherit path;
          drv = v;
        }
      ]
    else if tryOr false (builtins.isAttrs v) then
      lib.concatMap (n: leaves (path ++ [ n ]) v.${n}) (lib.attrNames v)
    else
      [ ];

  # The attribute paths that the shards split: each names a job or, with `systems`, an
  # attribute named for a system. A path is listed without being evaluated, so only its
  # own shard forces it; otherwise every shard would be a full eval, and one job that
  # aborts (which tryEval cannot catch) would fail them all. `attrNames` is sorted, so the
  # same jobs always land in the same shard.
  jobPaths =
    path: v:
    if isSystem path || tryOr false (lib.isDerivation v) then
      [ path ]
    else if tryOr false (builtins.isAttrs v) then
      lib.concatMap (n: jobPaths (path ++ [ n ]) v.${n}) (lib.attrNames v)
    else
      [ ];
  sorted = jobPaths [ ] jobs;

  systemOf = path: if isSystem path then lib.last path else "other";
  groups = if systems == null then { all = sorted; } else lib.groupBy systemOf sorted;

  chunk =
    list: i:
    let
      size = (lib.length list + shards - 1) / shards;
    in
    lib.sublist (i * size) size list;

  noContext = builtins.unsafeDiscardStringContext;

  outputsOf =
    { path, drv }:
    let
      # A job that fails to evaluate builds nothing, so it lists nothing.
      paths = tryDeep [ ] (map (o: noContext drv.${o}.outPath) (drv.outputs or [ "out" ]));
      attr = lib.concatStringsSep "." path;
    in
    map (
      p:
      if attrs then
        {
          path = p;
          inherit attr;
        }
      else
        p
    ) paths;

  # The derivation graph as seen from the Nix language: every derivation, or list of
  # derivations, in `drvAttrs` (`src`, `patches`, the build inputs, stdenv).
  node =
    d:
    let
      key = tryOr null (noContext d.drvPath);
    in
    lib.optional (key != null) { inherit key d; };
  depsOf =
    d:
    lib.filter (x: tryOr false (lib.isDerivation x)) (
      lib.concatMap (v: if builtins.isList v then v else [ v ]) (
        lib.attrValues (tryOr { } (d.drvAttrs or { }))
      )
    );
  fodOf =
    d:
    if tryOr false ((d.drvAttrs or { }) ? outputHash) then
      tryDeep [ ] [ (noContext d.outPath) ]
    else
      [ ];
  sourcesOf =
    drvs:
    let
      closure = builtins.genericClosure {
        startSet = lib.concatMap node drvs;
        operator = item: lib.concatMap node (tryOr [ ] (depsOf item.d));
      };
    in
    # Distinct derivations may share a fixed output; lib.unique would be quadratic.
    lib.attrNames (lib.genAttrs (lib.concatMap (item: fodOf item.d) closure) (_: null));

  manifest =
    system: list: i:
    let
      own = lib.concatMap (p: leaves p (lib.attrByPath p null jobs)) (chunk list i);
      shard = {
        index = i;
        count = shards;
      }
      // lib.optionalAttrs (systems != null && system != "other") { inherit system; };
      body = {
        nidhoggManifest = 1;
        inherit series shard;
        source = {
          inherit rev;
          inherit (source) lastModified;
        };
        outputs = lib.concatMap outputsOf own;
      }
      // lib.optionalAttrs sources { sources = sourcesOf (map (j: j.drv) own); };
      label = if systems == null then "" else "-${system}";
      text = builtins.toJSON body;
    in
    derivation {
      name = "nidhogg-manifest-${series}${label}-${toString i}-of-${toString shards}";
      system = pkgs.stdenv.hostPlatform.system;
      builder = "${pkgs.bash}/bin/bash";
      PATH = "${pkgs.coreutils}/bin";
      # The script must end in a builtin (`exit`), not in cp. Bash execs the last command
      # of `-c`, cp closes stdout and stderr before it exits, and Nix's daemon kills the
      # builder as soon as its log reaches EOF: the build then fails with "signal 9
      # (Killed)" and an empty log whenever the daemon wins that race.
      args = [
        "-c"
        ''mkdir -p "$out" && cp "$manifest" "$out/manifest.json"; exit $?''
      ];
      # Passed as a file, because a large manifest exceeds the size limit of an environment
      # variable. toFile also rejects text with string context, so a manifest cannot
      # depend on what it lists.
      manifest = builtins.toFile "manifest.json" text;
      preferLocalBuild = true;
      allowSubstitutes = false;
    }
    // {
      meta.schedulingPriority = 100;
      manifestText = text;
    };

  shardsOf =
    system: list:
    lib.listToAttrs (
      lib.genList (i: lib.nameValuePair "shard-${toString i}" (manifest system list i)) shards
    );
in
assert lib.assertMsg (
  builtins.isInt shards && shards >= 1
) "nidhogg.lib.manifestJobs: shards must be at least 1";
builtins.seq rev (if systems == null then shardsOf "all" sorted else lib.mapAttrs shardsOf groups)
