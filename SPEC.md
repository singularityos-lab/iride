# Iride format 1

## Source

A directory with `iride.json` and the SVG layers it names.

| Field | Value |
| --- | --- |
| `format` | `1` |
| `canvas` | width and height in user units, equal |
| `box` | `[x0, y0, x1, y1]` of the body, aligned to whole pixels |
| `stack` | nodes, drawn from first to last |
| `motion` | optional list of pieces, see Motion |

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

Any node may name its `piece`. A node without one takes the piece of its group.

Unknown fields are errors.

## Motion

Motion ends on the still icon: a track only says where a piece starts. Pieces are
listed in drawing order and every layer and rim belongs to exactly one. The
shadow of a group goes to the piece of the first node in that group.

| Field | Value |
| --- | --- |
| `piece` | name used by the nodes |
| `origin` | `[x, y]` around which the piece scales, turns and tilts |
| `clip` | optional `[x0, y0, x1, y1]`, fixed while the piece moves |
| `tracks` | list of tracks, `reveal` at most once |

A track has `kind`, `from`, `duration`, and optionally `at` (default 0) and
`ease` (default `out`). Times are milliseconds.

| `kind` | `from` |
| --- | --- |
| `translate` | `[x, y]` in user units |
| `scale` | `[x, y]` |
| `rotate` | `[degrees]`, clockwise |
| `tilt` | `[degrees]` around the horizontal axis through `origin` |
| `opacity` | `[alpha]`, 1 is opaque |
| `reveal` | `[x0, y0, x1, y1]` of the visible part, moving with the piece |

Tracks of the same kind on one piece add up their distance from the still icon:
0 for `translate`, `rotate` and `tilt`, 1 for `scale` and `opacity`. Opacity is
clamped after the sum. A swing is two tracks, the second starting as the first
ends: `from` -20 then 20 turns the piece from rest to 20 degrees and back.

`ease` is `out` (cubic 0.22, 1, 0.36, 1), `spring` (cubic 0.3, 1.4, 0.5, 1),
`linear` or `steps` (four steps). Tilt is seen from 3.28 times the side of the
icon.

An icon has at most 20 pieces and 48 tracks, lasts at most 1000 ms and its
compiled motion takes at most 2 MiB.

## Compilation

Sizes are device pixels: an icon of 32 at 150% is the 48 image.

- From 32 pixels the edges of `box` are moved to whole pixels.
- Below 32 pixels the grid is off and retouches apply.
- The bevel keeps a minimum width in pixels at every size.
- Pieces and the whole icon are compiled again for motion, from 32 to 256 pixels.
- Each image is the average of `min(16, 1024 / size)` samples per axis, rounded
  down to a whole number and at least 1.

## File

Integers are little endian.

| Offset | Type | Value |
| --- | --- | --- |
| 0 | 6 bytes | `IRIDE` followed by a zero byte |
| 6 | u16 | version, `1` without motion, `2` with motion |
| 8 | u32 | number of images, 1 to 4096 |
| 12 | 16 bytes each | image table, increasing size, version 1 |

Version 2 has three more fields before the table.

| Offset | Type | Value |
| --- | --- | --- |
| 12 | u32 | offset of the motion from the start of the file |
| 16 | u32 | length of the motion |
| 20 | u32 | CRC-32 of the motion |
| 24 | 16 bytes each | image table, increasing size |

| Entry offset | Type | Value |
| --- | --- | --- |
| 0 | u16 | side in pixels |
| 2 | u16 | reserved, `0` |
| 4 | u32 | offset of the PNG from the start of the file |
| 8 | u32 | length of the PNG |
| 12 | u32 | CRC-32 of the PNG |

The motion starts with an 8 byte header: u16 duration, u8 pieces, u8 tracks,
u16 levels and a reserved u16. Coordinates are f32 fractions of the canvas.

| Record | Fields |
| --- | --- |
| piece, 24 bytes | origin (2 f32), clip (4 f32) |
| track, 24 bytes | u8 piece, u8 kind, u8 ease, u8 reserved, u16 at, u16 duration, from (4 f32) |
| image, 20 bytes | u16 side, x, y, width, height, reserved; u32 offset in the motion, u32 length |

Kinds and eases count from 0 in the order given above. Each level has one image
per piece followed by the whole icon. An image is the zlib stream of
premultiplied BGRA rows, cropped to what is visible.

## Reading

Use the image with the requested side, or the next larger one. Never enlarge an
image: a request above the largest side fails with `ERANGE`. Place the image on
whole device pixels.

`iride_motion` gives duration, side and the memory to pass to `iride_prepare`.
`iride_frame` writes premultiplied BGRA and returns 1 once the motion is over:
from there on show the still image. Over the last 64 ms the frame blends into
the whole icon.

- Play once, when the icon is visible and its container is still.
- Never delay what the icon opens. When interrupted, show the still image.
- In a dock, run the time faster so that motion lasts at most 500 ms.
- With reduced motion or power saving, show the still image.
