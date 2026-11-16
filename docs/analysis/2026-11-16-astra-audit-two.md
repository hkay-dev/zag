---
type: analysis
summary: Second Astra source audit, prioritized repairs, preserved design choices, ticket references and explicitly limited verification.
covers:
  - src/buffer.zig
  - src/editor.zig
  - src/syntax.zig
  - src/files.zig
  - src/settings.zig
  - src/view.zig
  - src/gfx.zig
  - src/finder.zig
  - src/tree.zig
  - src/preview.zig
  - src/access.zig
  - src/objc.zig
  - src/main.zig
  - src/bench.zig
  - src/tests.zig
  - build.zig
  - scripts/bench.sh
  - scripts/bundle.sh
---

# Astra source audit, second pass, 2026-11-16

## Scope and evidence

This report consolidated CoreAuditTwo, PersistenceAuditTwo, LifecycleAuditTwo, RenderingAuditTwo, NavigationAuditTwo and PlatformAuditTwo. The auditors inspected source and related history, then compared the [first audit](2026-11-16-astra-audit.md). The report author read those six reports, the parent's 34-entry ticket manifest and the relevant [guide](../guide/index.md) contracts. The report author changed documentation only and ran no checks.

A **source-confirmed defect** means that an auditor traced faulty control flow or a violated invariant. The term does not claim an observed crash, data loss, UI result or performance measurement. Source coordinates below preserve inspection-time locations; concurrent implementation can move or replace those lines. The findings describe the inspected baseline, not an independent review of subsequent fixes. The parent owns implementation, reviewer integration, executed checks and ticket stages.

The second pass found gaps around successful-operation acknowledgement, logical closure before destruction, shared-cache publication and allocation failure. The auditors preserved the first pass's established repairs rather than treating every related finding as a regression of the same fix.

### Release measurements

| Measurement | Second-pass baseline | Final post-correction build | Delta and evidence limit |
|---|---:|---:|---|
| Unsigned release binary | 436848 bytes | 455136 bytes | +18288 bytes, approximately +4.19%. |
| `__text` | 296616 bytes | 304428 bytes | +7812 bytes. |
| `__TEXT` | Not supplied | 347255 bytes | Parent-reported final segment size. |
| `__DATA_CONST` | Not supplied | 80 bytes | Parent-reported final segment size. |
| `__DATA` | Not supplied | 45348 bytes | Parent-reported final segment size. |
| `__LINKEDIT` | Not supplied | 65536 bytes | Parent-reported final segment size. |

The parent freshly built the baseline under capacity into `/tmp/zag-astra-two-before`; the baseline did not merely reuse the first report's values. The parent supplied the final ReleaseSmall measurements above after the persistence-review correction. This author did not build or remeasure either artifact. Both binary values describe unsigned executables, not signed app bundles. The measured repair set increased executable size; source simplifications do not establish a runtime speedup.

## Prioritized findings and tickets

Each row records the defect and repair boundary, not an implementation-complete claim. All paths below refer to this repository. The parent supplied the ticket references through `local://zag-audit-two-tickets.json`.

### P1: Saved text, memory safety and destructive tooling

| Ticket | Source-confirmed finding | Evidence and repair boundary |
|---|---|---|
| zag#1khd | Load/save acknowledgements could pair A's bytes with replacement B's revision, allowing a later overwrite without a conflict. | `files.zig:20-78`; `view.zig:1958-1991,3308-3318,4229-4236`. Couple bytes and accepted identity through the read/write descriptor; do not acknowledge a later pathname stat. |
| zag#y1jk | Equal-size replacement with preserved modification time bypassed disk-change detection. | `files.zig:188-200`; `view.zig:3241-3244,4010-4022`. Include device/inode and change time; retain coherent snapshot semantics and migrate the tree consumer. |
| zag#nvks | An unchanged untitled buffer could lose its backing checkpoint before quit without triggering another write. | `view.zig:3200-3218,3831-3865`. Force the final checkpoint or validate its backing revision before approving quit; preserve the ordinary revision-gated fast path. |
| zag#a0kr | Animated card closure could destroy a document while a tab drag still borrowed its pointer. | `view.zig:1798-1823,2532-2632,9275-9614`. Cancel source/destination drag references at logical close, before animation teardown. |
| zag#7017 | Failed wrap-layout allocation left callers indexing empty or stale row tables. | `view.zig:5420-5463,5608-5619,7633-7729,9855-9861`. Reserve before publication and make every geometry consumer honor layout readiness. |
| zag#asrj | Rebuilding one command palette could shorten the shared catalog while another palette retained old indices. | `view.zig:4629-4633,4726-4808,5082-5084`. Repick every command-mode document and outgoing animation after publication; a bounds check alone cannot preserve command identity. |
| zag#3v2t | A malformed-byte Find query could match inside a valid UTF-8 scalar, and Replace could split that scalar. | `editor.zig:454-458,512-556,764-888`; `view.zig:4597-4604`. Validate both match endpoints while preserving standalone malformed-byte matches. |
| zag#kgax | Deletion could join malformed neighbors into a valid scalar but publish an interior caret, allowing the next edit to split that scalar. | `editor.zig:84-89,126-135,180-201,424-428`. Normalize committed selection endpoints against resulting text without changing byte-exact history ranges. |
| zag#6az9 | Benchmark fixture generation recursively deleted an existing unmarked directory supplied through `ZE_BENCH_HOME_DATA`. | `scripts/bench.sh:30,34-36,95`. Remove destructive cleanup; create a new owned fixture root or reuse a completed fixture, and reject symlink roots. |

### P2: Persistence and failed-operation publication

| Ticket | Source-confirmed finding | Evidence and repair boundary |
|---|---|---|
| zag#42vm | Immediate quit during a closing animation could checkpoint and later recover explicitly discarded text. | `view.zig:2532-2547,3142-3168,3524-3580,3831-3879`. Dispose of drafts at successful logical close and exclude closing documents from checkpoint creation. Skipping new checkpoints alone does not remove existing ones. |
| zag#0vr8 | Ignored draft-unlink failure let a completed discard resurrect content during recovery. | `view.zig:1212-1224,2294-2333,3871-3974`. Make explicit discard fallible before ownership destruction; report cleanup failure after a named save without claiming that save failed. |
| zag#5hsc | Session serialization caught per-window failures and published a partial replacement session. | `view.zig:3524-3556`; `main.zig:91-92,179,186`. Prepare the entire fallible snapshot before approving quit and preserve the old session on failure. The trace proves restoration/layout loss, not loss of every checkpointed draft. |
| zag#6err | Menu settings writes skipped parked dirty config tabs, producing false external-change conflicts. | `view.zig:4365-4397,3995-4005,2084-2088`. Merge into every matching page without activating tabs, preserve unrelated edits and acknowledge each merge only after success. |
| zag#3f07 | Failed settings writes lost pending zoom; reload/reset could announce success after failure. | `view.zig:4480-4498,11446-11450`; `settings.zig:806-816`. Return explicit outcomes, retain pending zoom and preserve the current config if reset replacement fails. |
| zag#qwfp | Save swallowed enabled whitespace/newline transformation failures and still wrote/marked the document saved. | `view.zig:3253-3254`; `editor.zig:673-709`. Stop before disk write on preparation failure; preserve any completed transformation as an undoable edit. |
| zag#24td | Failed deletion changed selection, and failed Replace One changed typing grouping before Buffer committed. | `editor.zig:180-192,502-518`; `buffer.zig:174-192`. Publish surrounding Editor state only after successful replacement; no Buffer clone or general transaction framework. |
| zag#jdvr | Buffer growth could exceed the `u32` index representation after the loader's separate limit ceased to apply. | `buffer.zig:9-61,220-280`. Check prospective length before allocation/mutation and at initialization; test arithmetic without multi-gigabyte allocations. |

### P2: Geometry, discovery, performance and platform behavior

| Ticket | Source-confirmed finding | Evidence and repair boundary |
|---|---|---|
| zag#xt9x | General sidebar rebuilds left fold indices and descendant extents stale. | `view.zig:168-260,6558-6671`. Rebase every active fold by saved relative path after rebuild; cancel missing folders and reacquire the opening folder before counting descendants. |
| zag#d5b2 | Pinned ancestors used uncompressed rows while drawing applied fold offsets. | `view.zig:6453-6529,6796-7015`. Share transformed geometry for pin selection, push-off, drawing and hit-testing. The auditor's half-fold example pinned A over B's visible children. |
| zag#zfcc | An idle open Quick Open retained the old hidden-file snapshot after a setting change. | `view.zig:103-147,4295-4311,4610-4626`. Invalidate on the setting transition and rescan when an open prompt needs results. |
| zag#hsb0 | Root enumeration failures became successful empty scans and could replace warm results. | `finder.zig:36-45,81-89`; `view.zig:99,123-147`. Propagate root setup/read errors; preserve descendant-skipping policy and existing warm/cold failure handling. |
| zag#kdxf | Failed sidebar rebuilding could appear permanently fresh with empty or partial rows. | `tree.zig:106-206`. Publish completeness only after traversal; distinguish the intentional 50000-row cap from failure. |
| zag#1pdm | Hanging indentation rescanned prefixes per continuation, and caret/viewport lines evicted each other from the single wrapped-line cache. | `view.zig:5466-5619,7720-7729`. Reuse continuation indentation and independently retain the required caret/viewport work without a general cache framework. |
| zag#wzph | Bracket highlights reused another page's cached result when cursor and revision matched. | `view.zig:1529-1530,2049-2098,7807-7849`. Invalidate page-dependent bracket state at installation. |
| zag#9akq | Trailing-whitespace rendering rescanned a logical line's suffix for each visible wrapped row. | `view.zig:626-628,7883,7928-7958`. Compute one trailing boundary per visible logical line and share that scalar across paint passes. |
| zag#p1a2 | Missing benchmark inputs opened as valid new empty editor files, allowing misleading measurements. | `scripts/bench.sh:88-89`; `bench.zig:54-63,146,351-363`; `view.zig:1882-1883,1958-1990`. Validate all regular-file inputs and observe actual open outcomes without changing normal new-file behavior. |
| zag#2yj8 | Main classified Perf as Regular despite its background-only bundle policy. | `scripts/bundle.sh:22`; `main.zig:163-165`; `bench.zig:43`. Classify `.perf` with `.dev` before setting activation policy; the auditor observed no focus change. |
| zag#cbaj | Preview rendered headings beyond 256 but omitted their navigation offsets. | `preview.zig:56-57,525-527,816-863`. Remove the silent cap, retain reusable storage and report allocation failure rather than publish a partial index. |

### P3 and behavior-preserving reductions

| Ticket | Finding or reduction | Evidence and repair boundary |
|---|---|---|
| zag#ay7p | Icon-cache append failure leaked a retained image and returned a pointer the drawing cache could not find. | `gfx.zig:337-350,385-397`. Reserve before retain, then append without another allocation. |
| zag#mr6a | Installing a Show Changes page replaced its synthesized `(on disk)` title with automatic text naming. | `view.zig:1174-1188,2049-2090,4135-4152`. Mark the title explicit through the existing field. |
| zag#4xey | Merge All Windows ignored sources beyond a 64-window snapshot. | `view.zig:11481-11504`. Traverse the mutable registry without a fixed cap or replacement heap snapshot; preserve transfer reservation and ownership. |
| zag#16ga | Stateless lexers allocated eight-byte `.normal` entries per cached line. | `syntax.zig:12-51,259-315`; consumers `view.zig:5982-5989,6052-6071,7941,11132-11139`. Omit redundant states while preserving invalidation, highlighting and stateful-language switching. |
| zag#e5nq | Preview constructed the same seven syntax colors for every paint call within one render. | `preview.zig:61-62,329-330,505`. Initialize once per render, not in a persistent theme cache. |
| zag#a4h0 | Existing preview anchor regressions never entered the registered test graph. | `preview.zig:723-734`; `tests.zig:1-9`; `build.zig:40-45`. Register the tests directly with their required dependencies; test existence does not establish execution. |

## Design choices and rejected hypotheses

- **Local commit boundaries, not new frameworks.** The auditors recommended explicit results, capacity reservation, existing page IDs and logical-close helpers. They rejected a new registry, TOML parser, document model or general state/cache framework. `closing` and split-node `going` describe interaction and animation separately; `palette` preserves outgoing presentation; `restoring`, `quitting` and startup latches describe independent boundaries.
- **Exact syntax state.** CoreAuditTwo preserved zag#3h4m and call 7957's exact Markdown fence marker/run length. Blindly narrowing the eight-byte state would undo correctness. Eliminating stateless entries saves a source-derived eight bytes per cached line, or 8 MB per million entries before capacity overhead; nobody measured whole-app memory savings.
- **Discovery bounds, not global-memory claims.** NavigationAuditTwo preserved zag#b500's approved 64-child batches and 16 live directory cursors. Pending frames can grow with depth, path storage can grow quadratically with depth, and the 100000-file cap does not bound directory count or scan time. The sidebar's 50000-row candidate policy bounds each directory's retained candidates, not all ancestor arrays together. The auditors found no reason to restore a directory-count cutoff or replace linear structures with hash maps.
- **Distinct symlink policies.** Finder includes regular-file symlinks but does not recurse into directory symlinks; the sidebar follows a directory symlink only after explicit expansion. The auditors found no automatic symlink-cycle trace and preserved descriptor-relative `NOFOLLOW` protection during finder replay.
- **Pinned-cache crash hypothesis rejected.** NavigationAuditTwo traced `pinnedAt` and row rectangles to fresh pin computation. The first audit's proposed stale cached-pin dereference did not occur in current source. The separate fold-refresh hypothesis became the source-confirmed zag#xt9x finding.
- **Nested-modal callback hypothesis rejected as a ticket.** LifecycleAuditTwo found that nested modal helpers could restore the guard incorrectly, but did not establish the required AppKit callback delivery sequence. The parent rejected a speculative ticket, not the distinction between nested and outer guard state. PersistenceAuditTwo likewise found a borrowed config pathname across reset confirmation without proving callback delivery that freed the path. Mutable save/close iteration observations lacked complete destruction traces. These observations do not establish runtime defects or authorize a modal framework.
- **Prior product choices remained authoritative.** The auditors preserved approved duplicate-tab closure after Save As, active-plus-parked page ownership, deferred external checks, final-width wrapping, existing accessibility behavior, the typed Objective-C bridge and ReleaseSmall configuration. Source inspection did not justify deleting those systems.
- **Small cleanup carried no measured gain.** The auditors proposed local pinned-row scratch, one dissolve-cleanup owner and private internal graphics types. Those changes reduce duplicate state or exposed detail, not a demonstrated release-time cost.

### Parent-reported calls

| Call | Decision supplied by the parent | Rejected alternative or limit |
|---|---|---|
| 7962 | Reset stages an independent metadata-preserving copy of the old config to Trash before atomic replacement and may leave an extra backup if replacement fails. | A hardlink would not provide independent backup contents. The parent reported the copy correction implemented, its targeted tests passed and final files/settings source reviews passed. |
| 7963 | Benchmark generation rejects existing unmarked, empty or partial roots and symlinks. | Generation does not adopt or clear an existing directory merely because the completion marker is absent. |
| 7964 | Buffer's growth bound follows its `u32` representation. | The separate loader limit does not define the editing bound. |
| 7965 | Stateless-cache omission follows only the existing flags that prove a language stateless. | Stateful languages retain exact wide state; the change does not narrow Markdown fence semantics. |
| 7966 | One caret-row cache uses complete page/revision/layout identity. | The implementation does not add a second segment cache or a general cache framework. |
| 7968, zag#1khd | The writer captures the temporary descriptor's accurate receipt before rename, then verifies published bytes with bounded stack storage and stable stamps. | Uncertain post-publication verification returns the conservative prepublication receipt, not false replacement failure or acknowledgement of unrelated bytes. The parent reported the correction implemented, its targeted tests passed and final files/settings source reviews passed. |
| 7969, zag#0vr8 | Quit retries retained draft cleanup on a named saved page; cleanup failure cancels quit and preserves ownership. | The ordinary named save still succeeds with a cleanup warning; the cleanup result does not retroactively invalidate the successful save. |

## Implementation and verification status

The parent reported all 34 ticket implementations complete, including view/main integration and file-snapshot caller migration. Persistence review found a required P1 correction before its final pass. The worker implemented that correction, and the parent supplied its passing targeted helper test, successful post-correction debug/benchmark-enabled/release builds and fresh measurements. All eight source-review slices ultimately passed with no remaining required fixes; all reported final checks passed within the scopes below. The parent had not yet committed the changes or moved the 34 tickets to Built. Implementation completion and source-review passes do not establish full behavioral verification, and first-pass checks in the earlier report do not verify these new changes.

**Persistence-review correction:** Save As to a page's own draft path could publish successfully but fail subsequent path resolution, retaining draft ownership. Later cleanup could then unlink the named saved file. The worker centralized identity-safe cleanup across save, discard, duplicate closure and the final checkpoint. Cleanup resolves and compares draft and named destinations, releases ownership without unlink when they match, and preserves ownership on resolution failure. The parent reported the helper regression passed; the report recorded the original defect as a source-review finding, not observed data loss.

| Check reported by the parent | Result | Evidence limit |
|---|---|---|
| `foundry capacity with build zag -- mise exec zig@0.17.0 -- zig test src/buffer.zig` | All 17 tests passed. | Parent-reported Buffer module result, not an app, Editor, persistence or lifecycle check. |
| Capacity-wrapped `zig test src/editor.zig --test-filter "editor regression"` | All 10 tests passed. | Targeted Editor regressions, not the full suite or AppKit integration. |
| `foundry capacity with build zag -- mise exec zig@0.17.0 -- zig test src/settings.zig -lc` | All 45 tests passed. | The combined settings/files class included restored-mtime in-place overwrite, conservative receipt after verification failure, independent archive mutation and copy-failure cleanup. These module tests do not execute AppKit reset, quit or draft interactions. |
| RenderReviewTwo | PASS, source-only | The review covered geometry readiness, caches, access sentinels, gfx and stateless consumers; the reviewer did not execute UI paths. |
| PlatformReviewTwo | PASS, source-only | The review covered benchmark safety/open/completion, Perf policy, preview ownership/colors and test registration; the reviewer did not execute a 257-heading preview. |
| CoreReviewTwo and DiscoveryReviewTwo | PASS, source-only | The parent supplied review conclusions, not executed editing, discovery or sidebar UI results. |
| FilesReviewTwo | PASS, source-only; no required fixes | The review covered byte-verified receipts with conservative fallback, independent metadata-preserving backups, staging cleanup and deterministic race regressions. The reviewer excluded view/main integration. |
| SettingsReviewTwo | PASS, source-only; no required fixes | The review covered the final files/settings contract, independent backup and precommit failure propagation. The reviewer excluded view/main integration. |
| Benchmark safety sandbox | Passed | The parent reported refusal, content preservation, completed-fixture reuse and validation of all five inputs. The sandbox did not launch the app or execute a full benchmark. |
| `bash -n scripts/bench.sh` | Passed | Shell parsing only. |
| Capacity-wrapped `zig test src/tests.zig -lc -lobjc --test-no-exec -femit-bin=/tmp/zag-astra-two-test-graph` | Compiled successfully without execution | The result established test-graph/native-link compilation, including preview registration, not a runtime test pass. |
| Registered debug check | Passed in 1.9 seconds after the final persistence correction | An earlier build caught a local `pick` shadowing function `pick` in view; the worker renamed the local `selected_index`. The parent reran the check after the subsequent persistence correction. No app ran. |
| Benchmark-enabled debug build | Passed after the final persistence correction | Compilation only; no benchmark execution. |
| ReleaseSmall build | Passed after the final persistence correction | The parent freshly measured the unsigned artifact in the table above; no app ran. |
| ViewNavigationReviewTwo | PASS, source-only; no required fixes | The review covered drag teardown, comparison titles, unlimited merge ownership, command identities/outgoing reset, fold rebasing/current pin geometry and hidden-picker invalidation. |
| ViewPersistenceReviewTwo | Final PASS, source-only; no remaining required fixes | After correction, the reviewer traced all cleanup callers passing the named destination, equal paths releasing ownership without unlink, and resolution failures preserving ownership and propagating failure. The reviewer ran no checks. |
| Capacity-wrapped `zig test src/view.zig -lc -lobjc -framework AppKit -framework QuartzCore --test-filter 'draft cleanup'` | 1 of 1 passed after correction | The isolated regression, `draft cleanup preserves its named destination and unresolved ownership`, exercised the cleanup helper, not the complete AppKit Save As or quit flow. |
| UI, app benchmark and runtime performance | No result supplied | The report author launched no application and measured no latency, focus behavior or memory. |

## Coverage gaps and parent handoff

The checklist below records requested coverage, not a claim that every case remained untested. The parent-reported checks above cover only their stated scope; unlisted runtime scenarios lack supplied execution evidence.

1. **Exact filesystem acknowledgement:** Cover deterministic replacement between read and acknowledgement and between rename and acknowledgement; same-size/preserved-mtime replacement; in-place changes with restored mtime; and the shared tree stamp consumer. A stronger stamp alone does not close the acknowledgement race.
2. **Draft/session commit:** Cover unchanged drafts whose backing file disappeared or changed; final checkpoint failure; unlink failure before discard; immediate quit during closing with and without prior checkpoints; multiple tabs plus a surviving draft; canceled close; and allocation failure at every multiwindow session append boundary. Require byte-exact surviving drafts and no partial session publication.
3. **Settings/save outcomes:** Cover dirty parked config tabs, merge allocation failure, failed read/write/reset creation, pending zoom retention and truthful success notices. Cover each save transformation's failure before disk write and preservation of already-applied undoable edits.
4. **Editing:** Cover malformed continuation/leading-byte Find queries in both directions, counts and Replace One/All; scalar formation across insertion/deletion/replacement seams; two-, three- and four-byte scalars; byte-exact undo/redo; and allocation failure preserving selection, preferred column and typing grouping. The reported Buffer pass does not exercise Editor publication.
5. **AppKit/layout ownership:** At inspection, `tests.zig` imported neither view nor gfx. Core tests therefore did not exercise card drag cancellation, palette publication, wrap readiness consumers, bracket cache installation, multiwindow merge or draft/session UI decisions. Cover initial and stale-layout allocation failure, armed/live drags through fold completion, shortened catalogs in two palettes and more than 65 windows. A successful compile does not fill these behavioral gaps.
6. **Geometry/work:** Cover fold insert/delete/reorder/removal, opening and closing, two folds and windows, pin push-off endpoints, and all relevant layout identities. Count indentation/suffix inspections and segment constructions rather than asserting timing gains. Cover stateless highlighting across edits and language changes without regressing Markdown/HTML state convergence.
7. **Discovery:** Existing wide batching did not cover depth greater than 16 and cursor spill/replay. Cover files before/after children at each depth, regular-file and directory symlinks, missing/unreadable roots, reader errors, warm-result preservation, hidden-setting changes while idle/in flight and incomplete-tree retry versus intentional truncation.
8. **Preview/tooling:** The parent compiled the registered test graph without execution. Runtime coverage still needs headings 255/256/257, removal/reordering, non-BMP UTF-16 offsets, repeated-context ambiguity and unchanged anchors. The reported sandbox covered fixture refusal/preservation/reuse and all five inputs, but no app benchmark or Perf activation ran.
9. **Measurement boundaries:** PlatformAuditTwo traced `quickopen_ms` to synchronous handler/frame CPU, not asynchronous time-to-results, and CPU totals to a point before Quick Open. Source-derived quadratic indentation, repeated suffix work, per-render color calls and cache-entry bytes do not establish measured speedups. The parent supplied the release-size deltas above, not runtime latency or memory results.

The guide already promised complete window merging, heading navigation, settings retention after failed reads, hidden-file filtering, draft deletion after Don't Save and external-change protection. Those promises defined repair targets rather than reasons to weaken the guide. After the parent confirmed the independent reset backup, the report author corrected the guide to describe copying the old config to Trash before replacement, rather than moving the original away first. The report author also corrected the first audit's two malformed references to zag#7pth.

## Provenance

The six delivered reports were `agent://CoreAuditTwo`, `agent://PersistenceAuditTwo`, `agent://LifecycleAuditTwo`, `agent://RenderingAuditTwo`, `agent://NavigationAuditTwo` and `agent://PlatformAuditTwo`. The parent supplied the ticket manifest, implementation completion, targeted check/build results, source-review conclusions, release measurements and calls 7962-7966, 7968 and 7969. The report author also read the first audit, relevant guide sections and matching motion/tiny-binary decision lines. No auditor report claimed an executed runtime reproduction; this consolidation did not turn source traces into runtime claims.
