# Iride

The icon format of Sinty OS. An icon is written as flat SVG layers with a
manifest for shadows, material and variants, and compiled into a `.iride` file
of bitmaps for each size and variant.

Drawing happens at build time with a known renderer, so a device does not need
to support SVG filters to show an icon.

## Status

In development. The specification and the compiler are not published yet, and
the format can change without notice.

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
