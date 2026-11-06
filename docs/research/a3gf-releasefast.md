---
type: reference
summary: ReleaseFast, whole or for the lexer alone, makes no bench metric faster past its floor and costs 118 KB (+36%) for the whole build; Zag stays ReleaseSmall.
---

# ReleaseFast for drawing and lexing (zag#a3gf, P-023)

## Question

Zag ships ReleaseSmall because a tiny binary is the point (zig-editor#mxc3,
docs/decisions/tiny-binary.md). Do the draw and lex loops get slower for it,
and would ReleaseFast, for the whole app or a split, buy enough to pay for
the size?

## What ran

Three Zag Perf builds of main at 98df6fd, each run 6 times under
`qm with quiet` with the order rotated every round (ABC, BCA, CAB), covered
window (`visible` 0 on every launch), load 10.7 at the start and 6.4 at the end.

- **A**: today's build, ReleaseSmall.
- **B**: ReleaseFast for everything (`preferred_optimize_mode = .fast`).
- **C**: ReleaseSmall, with `src/syntax.zig` (the lexer) as its own module
  built ReleaseFast and imported by view.zig.

A split that makes the drawing code fast isn't a real option: `Ink.run`,
`drawPane` and the rest live in view.zig, which imports nearly every other
file and is most of the binary, so a fast view.zig is close to build B in
size. Zig has no per-function optimize mode.

## Numbers

Medians; per-step metrics pool every sample (n in brackets), per-launch ones
are n=6. Floors are the profile's (4% per step, 15% frame_ms, 35% launch_ms).

| Metric | A small | B fast | B vs A | C fast lexer | C vs A |
|---|---|---|---|---|---|
| binary_kb (`zig build --release`) | 325.0 | 443.2 | +36% | 324.8 | -0.1% |
| tab_ms [360] | 2.597 | 2.598 | 0.0% | 2.567 | -1.1% |
| key_ms [1200] | 0.964 | 0.979 | +1.6% | 0.933 | -3.2% |
| scroll_ms [2400] | 1.041 | 1.044 | +0.3% | 1.013 | -2.7% |
| anim_frame_ms [1440] | 1.050 | 1.039 | -1.0% | 1.021 | -2.8% |
| frame_ms [720] | 2.922 | 2.725 | -6.7% | 3.173 | +8.6% |
| palette_ms [840] | 1.168 | 1.181 | +1.2% | 1.193 | +2.2% |
| activate_ms [240] | 3.105 | 3.134 | +0.9% | 3.068 | -1.2% |
| quickopen_ms [600] | 3.746 | 3.531 | -5.7% | 3.811 | +1.7% |
| quickopen_score_ms [360] | 3.051 | 2.835 | -7.1% | 3.090 | +1.3% |
| quickopen_walk_ms [120] | 156.3 | 150.7 | -3.6% | 156.0 | -0.1% |
| launch_ms | 214.2 | 227.2 | +6.1% | 218.7 | +2.1% |
| main_cpu_ms | 55009 | 54968 | -0.1% | 54922 | -0.2% |
| footprint_mb | 60.6 | 60.4 | -0.2% | 59.2 | -2.3% |
| peak_mb | 118.7 | 118.5 | -0.2% | 118.4 | -0.3% |

## What it says

- Every frame metric is noise for both B and C. The draw and lex loops aren't
  held back by ReleaseSmall. The likely reason, not traced, is that a frame is
  mostly CoreText, CoreGraphics and objc_msgSend, which the optimize mode
  doesn't touch.
- The one clear gain is quick open's scoring (`finder.best`), 7% faster in B,
  about 0.2 ms a letter, already far under a frame.
- B costs 118 KB, a 36% bigger binary, for nothing a person could feel.
- C is free in size and moves nothing past a floor.

## Options

| Option | Speed | Size | Verdict |
|---|---|---|---|
| Keep ReleaseSmall | today | 325 KB | **wins** |
| ReleaseFast everywhere | quick open letters -0.2 ms, rest noise | +118 KB | no |
| Lexer only ReleaseFast | noise | same | no, extra build code for nothing |

Raw numbers: `~/.local/share/zig-editor-perf/runs/2026-11-06-a3gf/` (not in Git).
