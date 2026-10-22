# guix-apptainer-tool-draft

A draft for discussion with the Guix community: Apptainer images of Guix
packages whose heavy dependencies sit in a separate layer. The layer is
copied to the cluster once, and again only when it changes, and Apptainer
mounts it with `apptainer run --overlay`.

`guix pack -f squashfs` already makes images that Apptainer runs on a machine
without Guix, such as an HPC cluster. Each of those images holds the full
closure of its profile, so a change to your own code means copying the
toolchain, MPI or CUDA to the cluster again. Here an image can name layers:
it leaves out every store item that its layers hold, and runs only with them
mounted. When only your code changes, only the small image is rebuilt and
copied.

This is a port of [apptainer-tools](https://gitlab.inria.fr/coconut/apptainer-tools)
for Nix, where `buildImage` and `buildLayer` do the same with Nix store paths.
Neither `guix pack` nor nixpkgs' `singularity-tools` has layers. Apptainer
itself has an open proposal for overlay images,
[apptainer#3497](https://github.com/apptainer/apptainer/issues/3497), with the
roles reversed: there the shared part is the base image and your code is the
overlay.

## Example

A layer with MPI, in `mpi.scm`:

```scheme
(use-modules (apptainer-tools)
             (gnu packages mpi))

(apptainer-layer
 (name "mpi")
 (packages (list openmpi)))
```

An image of your solver on that layer, in `solver.scm` next to it:

```scheme
(use-modules (apptainer-tools)
             (my packages solver))

(apptainer-image
 (name "solver")
 (packages (list my-solver))
 (layers (list (load "mpi.scm")))
 (run-script "exec my-solver \"$@\""))
```

Build both, copy them, and run the image with the layer on the cluster:

```bash
guix build -L "$DRAFT/modules" -f mpi.scm -r mpi.squashfs
guix build -L "$DRAFT/modules" -f solver.scm -r solver.squashfs
scp mpi.squashfs solver.squashfs cluster:
apptainer run --overlay mpi.squashfs:ro solver.squashfs    # on the cluster
```

This example is an illustration and has not been built: `my-solver` and
`(my packages solver)` stand for your own package, whose module directory
needs its own `-L`, and `$DRAFT` for a clone of this repository. `load`
reads `mpi.scm` from the directory of `solver.scm`. The
[tests](#trying-it) have the same shape and were built and run. Both records have gexp compilers, so `guix build -f` builds a
file that evaluates to one, and either can appear in a G-expression.
Building an image also builds its layers, but `guix build` prints only the
image, which is why the layer has a file of its own. The cluster needs only
Apptainer.

An image leaves out a store item only when the same store path is in one of
its layers, so the layer and the image must be built from the same package
definitions.
Building both with the same channel commits guarantees that; pin them with a
`channels.scm` file and `guix time-machine`. A commit to your own channel
that does not touch the layer's packages leaves the layer unchanged, and
only the image is rebuilt. When the layer does change, images already on
the cluster still need the old layer file, so keep it until they are
replaced: copying each layer under its store file name, the target of the
`-r` link (`<hash>-mpi.squashfs`), keeps the old ones apart. To find out
whether a layer already on the cluster fits a new image, run the image with
it; the image reports a layer that does not fit.

## Differences from `guix pack -f squashfs`

The image format is the same: a plain squashfs, not a SIF. Apptainer runs a
plain squashfs directly, and nothing calls Apptainer at build time.

| | `guix pack -f squashfs` | this draft |
| --- | --- | --- |
| Store items | the closure of one profile | the closure of bash-minimal and of a profile of `packages` and of the layers' packages, minus the store items of `layers` |
| Interface | command line, `squashfs-image` in `(guix scripts pack)` | `apptainer-image` and `apptainer-layer` records, for `guix build -f` or G-expressions |
| `apptainer run` | runs `--entry-point`, a file of the profile | runs `run-script`, shell code |
| Environment | `etc/profile` of the profile, sourced by `/.singularity.d/env/90-environment.sh` | the same, plus the variables in `environment`, in the same file |
| `--env`, `APPTAINERENV_*` | not passed to the container ([#71674](https://issues.guix.gnu.org/71674)) | passed, through `/.singularity.d/env/99-base.sh` |
| `/bin` | a link to the profile's `bin` | links to each file in the profile's `bin`, plus `/bin/sh` from bash-minimal when the profile has none |
| `/etc/passwd`, `/etc/group` | none | an entry for root, to which Apptainer adds the calling user |
| Other links | `-S` | none |
| Packing | `mksquashfs` on the store items, reparented with `-root-becomes`, without a copy | a copy of the store items in a tree, then one `mksquashfs` |

Bug #71674 has a cause independent of layers. Apptainer injects the
variables of `--env` and `APPTAINERENV_*` right after it sources
`/.singularity.d/env/99-base.sh`, a file that Singularity and Apptainer have
put in every image they built since Singularity 2.3 (see
`internal/pkg/util/fs/files/action_script.sh` in Apptainer). `guix pack`
images have `/.singularity.d/env` but not that file, so the variables are
never set. Here the image has a `99-base.sh` that, like the one
`apptainer build` writes, appends `/.singularity.d/libs` (where `--nv` binds
the host's GPU libraries) to `LD_LIBRARY_PATH`, and the image built from
[tests/image.scm](tests/image.scm) passes both `--env` and
`APPTAINERENV_*`. The same file should fix `guix pack` images; that has not
been tried.

## How it works

[modules/apptainer-tools.scm](modules/apptainer-tools.scm) re-exports the two
records from `(apptainer-tools image)` and `(apptainer-tools layer)`. Both
compilers build their squashfs with `(apptainer-tools store-squashfs)`.

- A layer's closure is a `references-file` of a profile of its packages,
  built without profile hooks. The layer holds that closure under
  `/gnu/store`, plus an empty marker file `/.layers/<closure-hash>-<name>`,
  where `<closure-hash>` is the hash part of the `references-file` output.
  The marker changes whenever the layer's closure does. It can also change
  when the closure does not, for example when a Guix update changes the
  Guile that builds the `references-file`; the layer then has to be copied
  again.
- An image's profile includes the packages of its layers, so `/bin` and the
  search paths in `etc/profile` cover them too. The image's closure is the
  `references-file` of that profile and of bash-minimal. The builder reads
  it and removes, with `lset-difference`, every item listed in a layer's
  closure file. bash-minimal is therefore in the image even when the profile
  brings its own `/bin/sh`, unless a layer holds it.
- The image's `/.singularity.d/env/00-layers.sh` checks each marker.
  Apptainer sources env files before anything else in the container, for
  `run`, `exec` and `shell` alike, so an image run without a layer stops
  with an error instead of failing later on a missing library. The error
  names the layer by its store file name, `<hash>-<name>.squashfs`. The
  check looks for the marker, not for that name, so the layer file can have
  any name on the cluster.
- Store items never overlap between an image and its layers, so the overlay
  cannot hide a file of the image. Several layers may hold the same item,
  such as glibc. Pass one `--overlay <file>:ro` per layer.

## Reference

`apptainer-image`:

| Field | Default | Meaning |
| --- | --- | --- |
| `name` | required | The store file is `<hash>-<name>.squashfs` |
| `packages` | `'()` | Packages whose closure goes into the image, through a profile |
| `layers` | `'()` | `apptainer-layer` records; their store items are left out, and the image runs only with them as overlays |
| `run-script` | `"exec /bin/sh \"$@\""` | Shell code that `apptainer run` executes with `/bin/sh` |
| `environment` | `'()` | Alist of variables set in every `apptainer run`, `exec` and `shell`, read back exactly as written (quotes, `$`, `` ` `` and `\` included) |
| `compression` | `"gzip"` | mksquashfs compressor: `gzip`, `zstd`, `xz`, `lz4` or `lzo` |
| `compression-level` | `#f` | 1-9 for gzip and lzo, 1-22 for zstd; `#f` keeps the mksquashfs default |

`apptainer-layer`:

| Field | Default | Meaning |
| --- | --- | --- |
| `name` | required | The store file is `<hash>-<name>.squashfs` |
| `packages` | required | Packages whose closure the layer holds |
| `compression` | `"gzip"` | As for `apptainer-image` |
| `compression-level` | `#f` | As for `apptainer-image` |

Values in `environment` are plain strings; a store path in one is not added
to the image. The Nix version also has `extraCommands`, which this draft
leaves out.

## Trying it

The files in [tests/](tests/) each evaluate to an image or a layer. From a
clone of this repository:

```bash
guix build -L modules -f tests/image.scm -r hello.squashfs
apptainer run hello.squashfs -g Bonjour                     # Bonjour

guix build -L modules -f tests/layer.scm -r coreutils.squashfs
guix build -L modules -f tests/layered-image.scm -r hello-layered.squashfs
apptainer run --overlay coreutils.squashfs:ro hello-layered.squashfs   # Hello, world!
apptainer run hello-layered.squashfs   # error: this image needs the layer ...-coreutils.squashfs
```

The comment at the top of each test lists more commands with their expected
output. On 2026-10-22, on aarch64-linux:

- Guix 1.5.0 (commit 230aa37), installed from the binary tarball in a Debian
  12 container, built all three tests.
- Apptainer 1.5.1, run as root in a `nixos/nix` container, gave the
  expected output for every command in the test comments (`run` and `exec`,
  `--env` and the missing-layer error among them), for
  `APPTAINERENV_GREETING` with the image of `tests/image.scm`, and for
  `id -un` in the layered image.
- Sizes: `hello.squashfs` 31 MB, `coreutils.squashfs` 35 MB,
  `hello-layered.squashfs` 0.7 MB. The layered image holds hello,
  bash-minimal, the image's profile and two profile-hook outputs; glibc and
  coreutils are in the layer.

Not done: x86_64-linux, other Apptainer versions, `apptainer shell`,
`--nv`, more than one layer, compressors other than gzip, a layer from
another Guix revision, and Apptainer as an unprivileged user. Run with
`setpriv` as uid 65534 in that container, Apptainer failed to start any
program in the image ("exec ...: invalid argument"), for the SIF built by
the Nix version as well, so the cause is probably the container rather than
the image, but it is unverified.

The repository is also a channel, with its modules under `modules/` (see
[.guix-channel](.guix-channel)).

## Questions for Guix

1. Would layers fit in `guix pack` itself? The Scheme side is small: a second
   list of reference graphs to subtract in `squashfs-image`, a marker in
   each layer and the check in the image. The command line would need a way
   to name a layer, for example a manifest per layer, and a way to build the
   layer on its own.
2. Should the `99-base.sh` fix for #71674 go into `guix pack` on its own?
3. Should the image be packed without a copy, as `guix pack` does? This
   draft copies the store items first, as the Nix version does, which for a
   CUDA layer costs disk space and time.
4. Is a plain squashfs enough? A SIF would allow `apptainer sign` and
   `verify`, but building one needs Apptainer's tools, and Guix does not
   package Apptainer (it has Singularity 2.6.1).

## Acknowledgement

The development of this tool was assisted by LLMs and AI agents.
