# Iride

The icon format of Sinty OS. An icon is written as flat SVG layers with a
manifest for shadows, rims and small-size retouches, and compiled into a
`.iride` file of bitmaps for each size in pixels. An icon can also carry a short
motion of its own pieces that ends on the still icon.

Drawing happens at build time with GtkSvg, the renderer of the toolkit, so a
device does not need to support SVG filters to show an icon.

## Status

In development, the format can change without notice. Light, dark and accent
variants are not implemented yet, and the toolkit does not load or play `.iride`
files yet.

## Components

- `cmd/iride/`: the compiler, `build`, `check` and `export` to a freedesktop icon theme
- `libiride/`: C ABI reader and motion compositor with header and Vala binding, no dependencies, also builds for wasm32
- `testdata/`: a source icon for trying the compiler

## Usage

```sh
iride build testdata/ring ring.iride
iride check ring.iride
iride export ring.iride icons/hicolor apps
```

The source and file layouts are in [SPEC.md](SPEC.md).

## Build

Zig 0.16, GTK 4.22 or later and Cairo.

```sh
zig build
zig build test
```

## License

GPL-3.0-only, see [LICENSE](LICENSE). Contributions under the [CLA](CLA.md).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on iride. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
