# Iride format 1

## Source

A directory with `iride.json` and the SVG layers it names.

| Field | Value |
| --- | --- |
| `format` | `1` |
| `canvas` | width and height in user units, equal |
| `box` | `[x0, y0, x1, y1]` of the body, aligned to whole pixels |
| `stack` | nodes, drawn from first to last |

A node is exactly one of:

- `layer`: path of an SVG relative to the source, with the same `viewBox` as the
  canvas. IDs are local to the layer. `retouch` is an optional list of
  `{"up_to": N, "layer": PATH}` in increasing `N`, below 32: at sizes up to `N`
  pixels that file replaces the layer, and an entry without `layer` hides it.
- `rim`: absolute or relative path data of the shape that gets the bevel.
  `rule` is `nonzero` or `evenodd`. `light` is an optional box for the light
  direction and defaults to `box`.
- `stack`: a group of nodes, with an optional `clip` path and `rule`, and an
  optional `shadow` with `dx`, `dy`, `blur` (standard deviation), `color`
  (`#rrggbb`), `opacity` and `region` (`[x, y, width, height]`).

Unknown fields are errors.

## Compilation

Sizes are device pixels: an icon of 32 at 150% is the 48 image.

- From 32 pixels the edges of `box` are moved to whole pixels.
- Below 32 pixels the grid is off and retouches apply.
- The bevel keeps a minimum width in pixels at every size.
- Each image is the average of `min(16, 1024 / size)` samples per axis, rounded
  down to a whole number and at least 1.

## File

Integers are little endian.

| Offset | Type | Value |
| --- | --- | --- |
| 0 | 6 bytes | `IRIDE` followed by a zero byte |
| 6 | u16 | version, `1` |
| 8 | u32 | number of images, 1 to 4096 |
| 12 | 16 bytes each | image table, increasing size |

| Entry offset | Type | Value |
| --- | --- | --- |
| 0 | u16 | side in pixels |
| 2 | u16 | reserved, `0` |
| 4 | u32 | offset of the PNG from the start of the file |
| 8 | u32 | length of the PNG |
| 12 | u32 | CRC-32 of the PNG |

## Reading

Use the image with the requested side, or the next larger one. Never enlarge an
image: a request above the largest side fails with `ERANGE`. Place the image on
whole device pixels.
