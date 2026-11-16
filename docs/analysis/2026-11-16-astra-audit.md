---
type: analysis
summary: Source audit of Zag's editing, persistence, ownership, rendering, discovery, platform integration and measurement boundaries, with evidence and verification gaps.
covers:
  - src/buffer.zig
  - src/editor.zig
  - src/syntax.zig
  - src/files.zig
  - src/settings.zig
  - src/view.zig
  - src/gfx.zig
  - src/tree.zig
  - src/finder.zig
  - src/main.zig
  - src/objc.zig
  - src/preview.zig
  - src/access.zig
  - src/bench.zig
  - src/tests.zig
  - build.zig
  - build.zig.zon
  - scripts/bench.sh
  - scripts/bundle.sh
  - scripts/dev.sh
  - scripts/dmg.sh
  - scripts/ship.sh
  - scripts/check.sh
---

# Astra source audit, 2026-11-16

## Scope and evidence standard

This report consolidated the delivered RenderingAudit, PersistenceAudit, DocumentsAudit, NavigationAudit, PlatformAudit and EditorAudit reports. EditorAudit delivered its findings before this report's preparation; the consolidation included that report rather than leaving an editor-coverage gap. The parent requested this durable analysis as part of the GPT-6 Astra Fast audit.

The auditors traced source, callers, documentation and prior Foundry references. PlatformAudit also checked the installed AppKit SDK contract. The report author read their delivered evidence and searched the motion and tiny-binary decisions. Those source inspections did not establish runtime reproductions or verified fixes. The auditors ran no builds, tests, benchmarks or app checks. A later implementation-status section records the parent's reported checks separately from the original audit evidence.

**Evidence labels:** A confirmed defect means that an auditor established the faulty source relationship or control flow. Scenarios below describe static deductions, not observed app behavior, unless an entry explicitly states otherwise. Performance findings distinguish demonstrable source work from unmeasured release execution cost. Hypotheses appear separately and do not authorize implementation by themselves.

**Source coordinates:** All file paths below refer to this repository. Line numbers preserve the auditors' exact inspection coordinates, not the locations after concurrent implementation. EditorAudit explicitly reported concurrent source changes and did not re-audit the applied edits. A later reader should locate the named function if lines have moved; this report does not assert that every defect remained present after the audit.

### Baseline and verification boundary

| Measurement | Recorded value | Provenance and limit |
|---|---:|---|
| Baseline release binary | 418336 bytes | The assignment supplied this baseline; this report did not remeasure the artifact. |
| Baseline `__text` | 286856 bytes | The assignment supplied this section size. |
| Final unsigned release binary | 436848 bytes | Parent-reported measurement: +18512 bytes, approximately +4.43% against the baseline. |
| Final `__text` | 296616 bytes | Parent-reported measurement: +9760 bytes against the baseline. |
| Final `__TEXT` | 337612 bytes | Parent-reported segment size. |
| Final `__DATA_CONST` | 80 bytes | Parent-reported segment size. |
| Final `__DATA` | 46297 bytes | Parent-reported segment size. |
| Final `__LINKEDIT` | 65536 bytes | Parent-reported segment size. |

The parent owns implementation verification, final measurements and ticket stages. The measured correctness-repair set increased binary size; this audit makes no shrink or size-neutral claim. Source-level removal of a copy does not establish a measured latency gain.

### Implementation references supplied by the parent

These references identify the audit's implementation groups. The parent subsequently reported all 20 ticket implementations complete; implementation completion is not equivalent to full behavioral verification. The report did not mutate tickets.

| Group | References |
|---|---|
| Rendering and motion | zag#7pth, zag#z0qq, zag#4cam, zag#w58p, zag#x62r, zag#5t9g |
| Draft persistence | zag#c325 |
| Document ownership | zag#avv9 |
| Session encoding | zag#epnb |
| Settings | zag#56et |
| Filesystem operations | zag#t8as |
| Navigation | zag#49r3 |
| Discovery and scoring | zag#b500 |
| Benchmark isolation and validity | zag#w9r2 |
| Preview | zag#t9qf |
| Platform integration | zag#rp3n |
| Icon hashing | zag#sk8n |
| Buffer transaction atomicity | zag#p7dp |
| Editor deletion, UTF-8 boundaries and paste | zag#0vf1 |
| Syntax scanning and state | zag#3h4m |

EditorAudit found existing coverage for Find in zag#z0qq and syntax-cache copying in zag#x62r. The parent subsequently supplied zag#p7dp for buffer atomicity, zag#0vf1 for editor deletion/UTF-8/paste, and zag#3h4m for syntax scanning/states. See the implementation-status section for the parent's reported completion, review corrections and limited executed checks.

## Architecture and priority

`Buffer` owns text, line indexes, undo history and invalidation. `Editor` converts commands into replacements. `syntax.zig` supplies line-state transitions and byte kinds. `view.zig` connects those layers to AppKit, document ownership, drafts, session restoration, layout, rendering and discovery publication. `files.write` supplies the shared replacement transaction; its callers decide when to acknowledge disk revisions or release paths.

Within `view.zig`, `Page` owns one editor and its persistence metadata (`1118-1208`). `Doc` owns an active page and parked pages (`1234-1579`); that representation transfers ownership rather than copying the active buffer. `Win` owns the split tree, whose leaves reference registered documents (`1587-1730,1815-1827`). `park` and `install` transfer the active page (`2003-2057`), but `install` also checks external changes and can present a modal sheet or create another pane. That side effect explains several otherwise surprising identity and lifetime failures.

The reviewers identified the highest-risk cluster at commit boundaries: fallible edits after text mutation, destructive transfers before destination allocation, checkpoint failures after quit approval, and revision acknowledgements before successful reads. Modal reentrancy and pointers across owner replacement formed the other memory-safety cluster. The following order prioritizes consequence rather than preserving every scout's local P1/P2 ordering:

1. Protect authoritative text, saved files and stable drafts; repair dangling pointers and invalidated iterations.
2. Repair failed-read acknowledgement, incomplete constructors, session encoding and malformed-input editing.
3. Restore cache identity, animation/input agreement and bounded interactive work.
4. Remove demonstrated copying and maintenance dead weight without changing product contracts.

## Confirmed defects: data integrity and memory safety

### D1. Buffer edits committed before fallible preparation completed

**Evidence:** `src/buffer.zig:138-228`; caller `src/editor.zig:413-424`; UI error-catching callers in `src/view.zig`.

`replace` grew a joined undo record before `splice`. `record` allocated old/new bytes without cleanup guards, appended history and cleared redo before splicing. `undo` and `redo` popped their source stacks before appending to the destination. `splice` changed text before allocating inserted line starts or updating `starts` and `wraps`, and published invalidation afterward. Callers caught failures and continued using the editor.

**Static consequence:** An allocation failure after inserting a newline could leave text and line indexes inconsistent. A history append followed by failed text growth could record an edit that never happened. A failed destination-stack append could lose an undo record. These cases threaten authoritative text and memory-safe indexing, not merely an optional cache.

**Targeted repair:** Prepare edit bytes and all required text, history and index capacities before a non-failing commit. Add cleanup for staged allocations. Preserve `spliceUnits`' recoverable lazy-cache discard rather than cloning the entire buffer. Allocator-failure tests should compare text, indexes, dirty state and history with the pre-operation state after each failure.

**Prior contract:** `docs/guide/index.md:358-384` documented typing and undo. EditorAudit found no matching atomic-edit ticket in its history search.

### D2. Quit approved termination before failed draft checkpoints could stop it

**Evidence:** `src/view.zig:3080,3100-3103,3388-3390,3631-3650`; `src/main.zig:164,171`.

Quit settlement asked about named dirty files but not untitled drafts. `keepDraft` swallowed directory and write failures, `saveDrafts` returned no outcome, and `saveSession` attempted checkpoints after termination approval before setting `quitting = true`. `keepDraft` also assigned `p.draft` before `makeParent` succeeded, so later attempts skipped that preparation branch.

**Static consequence:** A full disk or inaccessible Drafts directory could leave an older checkpoint or no checkpoint while quit proceeded. The first failed parent-directory creation could prevent later attempts from repairing the directory.

**Targeted repair:** Flush drafts before approving termination, propagate errors and cancel termination on persistence failure. Commit the draft path only after preparation succeeds, or retry parent preparation. Preserve ordinary no-question quit when all required checkpoints succeed.

**Prior references:** zag#wt11, zag#6mfq; `docs/guide/index.md:344-352`. The no-prompt choice did not authorize silent loss after failed persistence. Implementation group: zag#c325.

### D3. Saving onto the draft's backing path deleted the new save

**Evidence:** `src/view.zig:3156-3185,3656-3660`.

Save As installed the selected destination as `Page.path`, marked the buffer saved, then called `dropDraft`. Cleanup unlinked the old draft path without comparing that path to the new destination.

**Static consequence:** Selecting the current backing `.txt` inside the exposed Drafts folder allowed a successful atomic write followed by deletion of that same file.

**Targeted repair:** Compare canonical destination and draft paths before cleanup. Transfer ownership without unlinking when both paths identify the saved file; release only the obsolete path allocation.

**Prior references:** zag#6zx3, zag#qm1g; `docs/guide/index.md:350-354`. Implementation group: zag#c325.

### D4. Nonempty synthesized pages looked already checkpointed at revision zero

**Consolidated duplicate:** PersistenceAudit identified Show Changes; DocumentsAudit also identified Duplicate Tab. These creation paths need one checkpoint-state repair.

**Evidence:** `src/view.zig:10695-10702,3897-3905` constructed nonempty untitled pages; `src/buffer.zig:21,46-50` initialized revision zero; `src/view.zig:1130-1132,3635-3650,5520-5530` used zero-valued checkpoint/scheduling markers; `3388-3443` omitted pages with neither a file nor draft path from the session.

**Static consequence:** An untouched duplicate or comparison snapshot received neither a checkpoint nor a restored session entry. Editing masked the defect by advancing the revision. Saving the original could also remove the disk version that an uncheckpointed comparison had preserved.

**Targeted repair:** Represent "never checkpointed" separately from "checkpointed revision zero" and schedule nonempty synthesized pages. Preserve valid restored revision-zero drafts. `markUnsaved()` alone did not repair revision equality.

**Prior references:** zag#wt11, zag#6mfq, zag#9pm7, zag#ej28; `docs/guide/index.md:174-178,198-205,334-356`. Implementation group: zag#c325, with ownership coordination in zag#avv9.

### D5. Tab transfers destroyed source ownership on allocation failure

**Consolidated duplicate:** DocumentsAudit and NavigationAudit traced the same transfer contract, not two independent bugs.

**Evidence:** `src/view.zig:2411-2425` (`takeTab`), `2430-2437` (`putTab`), `9181-9190` (`moveTab`), `11186-11200` (`tabOut`), `11155-11177` (window merging), `1203` (`deinitKeepDraft`).

`takeTab` removed the source page before destination preparation. Failed destination parking made `putTab` destroy the incoming page; failed new-window construction likewise destroyed an extracted page. Window merging used those operations before closing the source window.

**Static consequence:** A moved named page could lose unsaved edits because named pages had no recovery draft. Retaining an untitled draft did not repair this ownership contract.

**Targeted repair:** Allocate the destination and reserve tab capacity before extraction. A failed insertion must leave the source intact or return ownership for rollback. Include `install`'s modal external checks in the transfer analysis.

**Prior references:** zag#9pm7, zag#xxg9; `docs/guide/index.md:163-205,249-251,334-349`. Implementation group: zag#avv9.

### D6. Settings menu writes passed a freed path to `stat`

**Evidence:** `src/view.zig:3969-3980,4115-4123`.

`store` captured `const p = conf_path`, wrote settings and called `loadSettings`. Reload called `resolveConf`, which freed the old path. The dirty-config merge branch then called `files.stamp(p)` with that freed allocation. A separate `setConfLine` failure also passed through `catch {}` before the caller acknowledged the merge's disk stamp.

**Static consequence:** Editing unsaved `config.toml` and changing a setting through a menu could pass dangling memory to `stat`; failed merge allocation could acknowledge a change that the editor never incorporated.

**Targeted repair:** Use the newly owned path or successful reload stamp, and advance the document stamp only after a successful merge.

**Prior reference:** zag#ksag established undoable merges into dirty settings documents. Implementation group: zag#56et.

### D7. External-change checks invalidated the registry slice they traversed

**Evidence:** `src/view.zig:3769-3776` (`recheckAll`), `3782-3822,3844-3857` (modal checking), `3897-3905` (Show Changes), `2369-2406,2934-2945` (split/pane creation); activation caller `src/main.zig:85-88`.

`recheckAll` iterated `docs.items`. Show Changes could synchronously call `splitOff`, whose pane creation appended to `docs` and could relocate the array. The suspended iterator then resumed against the old allocation. Modal work also required consideration of removal, not just growth.

**Targeted repair:** Traverse stable identities and validate membership across mutating work, or use another explicit mutation-safe traversal. Reserving one extra slot would not establish the required lifetime guarantee.

**Prior references:** zag#ej28, zag#mm5c; `docs/guide/index.md:552-566`. Implementation group: zag#avv9.

### D8. Sidebar creation and rename could replace another directory entry

**Evidence:** `src/view.zig:10761-10796`; `src/files.zig:45-66,105-106`.

`sideCreate` checked existence before replacement-oriented `files.write`; `sideRename` checked existence before replacement-oriented `rename`. Another process could create the destination between the check and operation. Following `stat` also treated a dangling symlink as absent.

**Targeted repair:** Use exclusive New File creation and atomic no-replace Rename, while retaining Save's intentional replacement semantics. Support case-only renames without reopening overwrite races: on case-insensitive APFS, the current destination check rejected `notes.txt` to `Notes.txt` because the source itself satisfied the check (`view.zig:10782-10796`).

**Prior reference:** zag#neg2; `docs/guide/index.md:301-304`. Implementation group: zag#t8as.

### D9. Session benchmarks referenced stable drafts directly

**Evidence:** `scripts/bench.sh:99-105` imported stable defaults and copied obsolete `Application Support/ze/Drafts`; `src/view.zig:3439-3441,3553-3566,3667-3675` serialized, restored and owned absolute draft paths.

Changing `HOME` did not rewrite those paths. Copying the newer `zag/Drafts` directory alone would not isolate the imported session. PlatformAudit traced a conditional deletion path: failed node allocation in `restoreNode` called `closePane` (`view.zig:3590-3592`), `Page.deinit` called `dropDraft` (`1195-1199`), and cleanup unlinked the original stable draft (`3656-3659`). The auditor did not claim that routine launch-only benchmarks deliberately deleted drafts.

**Targeted repair:** Copy current drafts and rewrite imported draft entries to copied absolute paths before launch. Preserve ordinary file-tab paths.

**Prior references:** zag#6zx3, zag#wv2z; `README.md:15`; `.omp/skills/zag-perf/SKILL.md:59` promised copied session/draft data. Implementation group: zag#w9r2.

### D10. Constructors published incomplete ownership and leaked on failure

**Evidence:** `src/view.zig:2853-2898` (`newWin`), `2826-2840` (`newDoc`), `2934-2945` (`newPane`), `2369-2406` (`splitOff`); related restoration paths `3525-3626`.

`newWin` registered a window before finishing construction and leaked the allocated window on append failure. `newDoc` did not unwind an already-created window if pane creation failed. `newPane` lacked rollback for page creation or registry insertion. `splitOff` registered a pane before allocating both split nodes.

**Static consequence:** Failed allocations could expose an unattached pane to global walks or leave a registered window before root/focus initialization completed.

**Targeted repair:** Finish required allocations before publication or add precise reverse-order rollback. Apply the same concrete ownership convention to session restoration; do not introduce a generic lifecycle framework. Implementation group: zag#avv9.

### D11. Palette construction could diverge its parallel arrays

**Evidence:** `src/view.zig:4534-4535,4803-4833`.

Palette construction appended a name before its corresponding command. Failure of the second append left different array lengths, allowing selection to index beyond `cmds`.

**Targeted repair:** Reserve both capacities before committing either entry. Preserve the menu-derived palette rather than introducing another command registry.

**Prior reference:** zag#ard4; `docs/decisions/tiny-binary.md:58-60`. Implementation group: zag#49r3.

### D12. Accessibility teardown could retain a destroyed owner's identity

**Evidence:** `src/access.zig:206-237,220-226,311-315`; destruction caller `src/view.zig:2572`.

The sweep allocated a temporary `dead` list. If append failed, the matching element retained its owner pointer. `docOf` validated owners by pointer membership, so later address reuse could associate an old accessibility object with a new document.

**Targeted repair:** Invalidate destruction without allocating; remove or tombstone before notifying, and account for notification reentrancy during traversal. This repair protects existing behavior rather than adding accessibility scope.

**Prior references:** zag#dkeg, zag#1xsq. Implementation group: zag#rp3n.

## Confirmed defects: persistence and identity

| Finding | Exact source evidence and static consequence | Targeted repair and prior references |
|---|---|---|
| Binary reload acknowledged unread bytes | `src/view.zig:3124-3128,3799-3807`: the binary branch recorded the new stamp and marked the editor dirty without reading the replacement or receiving Keep Mine. A later Save could bypass the external-change warning. | Preserve the accepted stamp until a successful reload or explicit Keep Mine. zag#s9sd already required that discipline; `docs/guide/index.md:550-586`. Coordinate with zag#c325 / zag#avv9. |
| Show Changes updated the replacement page | `src/view.zig:3897-3905,3844-3857,3801-3803`: when no split fit, the comparison became active in the original `Doc`; `checkOutside` then stamped `d.file`, now the comparison. Returning to the original could repeat the conflict. Other `showTab`/`install` callers also assumed the requested page remained active. | Preserve original page identity across the modal operation, acknowledge that page before another check, and explicitly preserve intended activation. `focus(d)` alone identifies only the card. zag#ej28; guide `552-566`; zag#avv9. |
| Metadata-copy failure did not stop replacement | `src/files.zig:61-66`: `if (old) _ = copyfile(path, tmp, null, copy_acl | copy_xattr);` discarded the result before chmod, fsync and rename. A failed ACL/xattr copy could commit new content without the old metadata. | Fail the save before replacement and preserve the error. Existing tests at `175-209` covered successful mode/xattr preservation, not metadata failures or ACL preservation. zag#qm1g; `docs/working-here.md:13`; zag#t8as. |
| Temporary naming rejected legal long basenames | `src/files.zig:46-49`: `.{basename}.ze-XXXXXX` added eleven characters. A legal 245-255-character ASCII basename exceeded a 255-character component limit when the writer created its temporary file. | Use a short same-directory template such as `.ze-XXXXXX`. zag#9vdg originally requested that template; zag#t8as. |
| Session tokens could not represent tabs in paths | `src/view.zig:3425-3463,3479,3525-3595`: `saveLayout` emitted raw paths into a tab-delimited stream and restoration split the stream on tabs. `/tmp/a\tb.txt` could fragment into layout tokens and disturb later entries. | Version a narrow path-token encoding, decode symmetrically, and retain migration for existing sessions. PersistenceAudit and NavigationAudit reported the same defect. zag#2he6, zag#nqdb, zag#xxg9; guide `334-342`; zag#epnb. |
| Failed settings reads replaced working settings | `src/settings.zig:793-797`; `src/view.zig:3979-3986,4207-4210`: read failures became defaults, which reload installed while recording the unread revision. A permission repair without a stamp change could miss a retry. | Separate errors from parsed settings, retain the last successful settings/stamp on reload failure, and distinguish deliberate startup/missing-file defaults. Guide `654-676`; analogous accepted-stamp discipline in zag#s9sd; zag#56et. |
| Dangling symlinks became replacement destinations | `src/files.zig:86-98,105-107`; `src/view.zig:1864-1877,1926-1958,3170`; `src/settings.zig:800-805`: failed `realpath` fell back to an unresolved path, following `stat` reported absence, and Save could replace the link rather than create its missing target. | Resolve leaf symlinks even with a missing ultimate file; report unsupported resolution failures instead of replacing the link. zag#xmy9, zag#9q4k, zag#sdqg covered existing-target/canonicalization cases; zag#t8as. |

## Confirmed defects: editing and syntax

These findings came from the delivered EditorAudit. The examples describe source-derived outcomes, not executed regressions.

| Finding | Exact source evidence and counterexample | Targeted repair and prior references |
|---|---|---|
| Delete Line removed an extra preceding break | `src/editor.zig:650-664`: `end == text.len` also matched the last terminated content line. Deleting `b` from `"a\nb\n"` selected `"\nb\n"`, yielding `"a"` rather than `"a\n"`. | Test whether selected rows include the actual final row. Preserve preceding-break behavior for a genuinely final unterminated or empty row. Existing test `1630-1638` covered an unterminated final line; guide `398-399`. |
| Character helpers disagreed on malformed UTF-8 | `src/editor.zig:931-955,973-1029`; loaders `src/view.zig:1926-1958,3824-3825`; consumer `src/access.zig:429-440`. `decode` consumed malformed bytes individually, while `prevChar`/`charStart` assumed continuation-shaped bytes belonged to an earlier code point. For `"a\x80b"`, two Right moves then Backspace could delete both `a` and the malformed byte. `nextChar` had a matching forward inconsistency. | Use validated UTF-8 boundaries and one-byte malformed-input recovery in both directions; bounded lookbehind suffices. Preserve valid graphemes. Related but distinct fixes: zag#ewm9 and zag#08aq. |
| Unclosed strings repeatedly scanned suffixes and leaked comment state | `src/syntax.zig:313-395,503-509`: failed `findClose` advanced one byte, so later escaped quotes became fresh opener candidates. An opening quote followed by many escaped quotes requested quadratic suffix work; `/*` inside unfinished ordinary strings could affect following lines. | Color the unfinished string remainder and stop that line, preserving normal outgoing state for non-multiline ordinary strings. Compare state-only and token-producing scans. zag#fkj8 concerned earlier quote/lifetime behavior; `docs/research/a3gf-releasefast.md` rejected optimization mode as a substitute. |
| Markdown link candidates repeatedly scanned suffixes | `src/syntax.zig:612-619`: each `[` searched the remaining line for `]`; a line of `[` requested quadratic work. | Reuse lookahead or scan monotonically without suppressing unrelated later markup. Runtime magnitude remained unmeasured. |
| HTML attributes lost open-quote state across lines | `src/syntax.zig:515-608`: `attrs` returned only the surrounding tag state after an unterminated quoted value. In `<div title="first` followed by `second">body</div>`, the next line could treat the closing quote as a new opener. | Retain quote type and enclosing tag destination, including script/style attributes, with state-only/full-output parity. zag#8cqa, distinct from zag#9rsc; guide `598-618`. |
| Embedded HTML end tags accepted prefixes | `src/syntax.zig:515-608`: `endTag` accepted `</script` or `</style` without a name boundary, so `</scripture>` could end script coloring. | Require a valid boundary after the complete name. Preserve existing comment/self-closing fixes from zag#9rsc. |
| Markdown fences forgot opener identity | `src/syntax.zig:457-500` and `State`: one `.fence` state toggled on either three-marker prefix. Backticks could close a tilde fence, three markers could close four, and trailing text could masquerade as a closer. | Retain delimiter type/run length and validate the closing line. Review `src/preview.zig:325-339`, a lexer-state consumer. Guide `614-618`; no parser framework required. |
| Hash-comment rules conflated languages | `src/syntax.zig:99-156,350-352`: every hash-comment language required whitespace or line start, so Python `x=1#comment` missed the comment. | Assign the right language boundary rule; preserve shell `$#` and YAML distinctions. Existing shell test `683-687`; guide listed supported languages. |

## Confirmed defects and costs: rendering and motion

| Finding | Exact source evidence and consequence | Targeted repair and prior references |
|---|---|---|
| Hidden keyboard-highlight spring requested frames indefinitely | `src/view.zig:1711,6605-6615,7184-7205,7227-7234,1060-1094`: the hidden-sidebar branch parked `hov` and `sel`, omitted `kc`, and still counted unsettled `kc.s` as busy. Hiding or narrowing during motion removed the only advancing draw path. | Park `kc` alongside the existing springs; preserve its time-based alpha tween. zag#8x5k fixed the same lifecycle pattern elsewhere; tiny-binary decision `33-38`. |
| Find ticks requested unused column calculations | `src/view.zig:8231-8237,5362-5368`; `src/editor.zig:1064-1072`: tick generation used only `.row` from `rowColOf`, whose column scan traversed prefixes. A nonwrapping line of repeated matches requested scans of lengths approximately `0,1,2,...,N-1`. The 2,000 tick cap counted distinct rows, not examined matches. | Compute only the visual row and preserve multiline/nonoverlapping `nextMatch` progression. Do not impose an arbitrary match cap or skip logical lines. The reviewer did not inspect optimized code, so dead-code elimination and runtime severity remained unmeasured. zag#nqdb; guide `507-510`; zag#z0qq. EditorAudit added `view.zig:8221-8242`, the distinct 10,000 count cap, and related zag#0qpz, zag#3ts6, zag#xnq3. |
| Find tick identity omitted wrap geometry | `src/view.zig:8216-8247,5169-5198,5362-5368`: total rows did not identify individual match rows. A 100-character line with `X` at byte 55 occupied two rows at both 60 and 50 columns, but `X` moved from row zero to one. The current-match tick recomputed at `8246`; cached ordinary ticks did not. | Add existing layout inputs to identity or invalidate with layout: wrapping mode, width, tab width and hanging indentation. Do not add a second layout cache. zag#nqdb; guide `509-510`; zag#z0qq. |
| Duration retargeting sampled the wrong old curve | `src/gfx.zig:52-56` assigned duration before `aim` sampled `speed(now)` and `at(now)` at `41-49`. Callers included caret motion `src/view.zig:788-791`, scrollbar fading `7882-7888`, and toast retargeting `7254,7272`. | Sample old position and velocity before changing duration; retain same-target no-op and velocity limits. zag#7yvx; zag#a9tj concerned a different persistent-duration issue; motion decision `15-18`. |
| Horizontal scrollbar range used bytes rather than displayed columns | `src/view.zig:7804-7808,7833-7838,1981-1983,7870,7902-7907,9750`: `lineWide` counted bytes plus leading tabs and omitted tab width from cache identity. One hundred `a\t` pairs at tab width eight occupied 800 columns but only 200 bytes. | Reuse `editor.colOf` inside the existing incremental widest-line scan and invalidate on tab-width changes. Preserve incremental scanning. zag#z4tr, zag#nqdb; guide `46-50`. |
| Syntax-cache hits copied entire logical lines | `src/view.zig:7591-7592,5786-5800,7637`; invalidation `src/syntax.zig:253-301`. Every redraw swapped/cleared caches and copied cached kinds even when text and the visible logical-line interval were unchanged. A small visible fragment of a large wrapped line could trigger a whole-line copy. | Reuse the current cache when invalidation and interval permit; preserve rebuild fallback and offset-based entries. Runtime benefit remained unmeasured. zag#nqdb; guide `598-616`; zag#x62r. |
| Prompt draws recopied unchanged snapshots | `src/view.zig:8051-8058,7331`: active draws cleared/appended both field snapshots, although fade-out needed only the retained last contents. | Guard refresh by content equality while retaining outgoing mode/file identity. No new prompt state machine. zag#7yvx, zag#wykz. |

The parent grouped these repairs under zag#7pth, zag#z0qq, zag#4cam, zag#w58p, zag#x62r and zag#5t9g. The table does not claim those repairs passed verification.

## Confirmed defects and limits: navigation and discovery

| Finding | Exact source evidence and consequence | Targeted repair and prior references |
|---|---|---|
| Pending folds undid Collapse All or crossed roots | `src/view.zig:38-60,6250-6264,6372-6384,10853-10862`: root replacement and Collapse All cleared `tree.open` without canceling fold records; completion toggled the now-closed folder open, possibly under a new root with the same relative name. | Cancel both records before changing roots/open sets; completion should close an open folder rather than toggle blindly. zag#g0r3, zag#neg2; guide `307`; zag#49r3. |
| Animated hit tests used destinations, not drawn offsets | `src/view.zig:6224-6248,6475-6497,7946,9661-9671,9900-9903`: sidebar input used `w.side_y`; Quick Open/palette input used `d.plist.to`; drawing used animated current values. | Share the current tween value across drawing, clicks, hover and row geometry. zag#56ya; motion decision `47-58` explicitly required current-position hit testing; zag#49r3. |
| Quick Open refresh restored an offscreen selection | `src/view.zig:100-137,4414-4430,4999-5005`: completion restored selected identity after `pickFiles(true)` snapped scroll to zero, but never called `showPick`. Result 20 could remain selected while the first ten rows appeared. | Restore/clamp scroll or call `showPick` after restoring identity. zag#nqdb, zag#56ya; guide `141-159`; zag#49r3. |
| Scoring overflowed on accepted long queries | `src/finder.zig:112-157`; inputs `src/view.zig:4697,10964`: `i32` accumulation/scaling overflowed for path `a` and 700,000 `a` tokens: `700000 * 51 * 64 = 2,284,800,000`. Debug arithmetic trapped; unchecked release arithmetic supplied no valid overflow semantics. | Accumulate/scale safely and clamp to the representation while preserving ordinary ranking. Do not arbitrarily reject prompt text. zag#qa5x; guide `141-159`; zag#b500. |
| Cold Quick Open bypassed background execution | `src/view.zig:140-148,4350-4375`; `src/finder.zig:26-74`: a cold miss scanned synchronously. The 100,000-file cap excluded directories, so empty-directory hierarchies did not bound traversal; recursive walking retained ancestor descriptors and could exhaust them. | Reuse the existing worker/completion path with explicit loading state and generation checks; address descriptor retention without undocumented truncation of directory-only trees. zag#nqdb, zag#fazb; `docs/changelog/2026-11-05-zig-editor-perf-1105-1.md:18-23`; zag#b500. |
| Sidebar row cap did not bound candidate memory or sort work | `src/tree.zig:140-188`; `src/view.zig:184-241`: the scanner copied and sorted every directory entry before enforcing 50,000 rows and could recurse after filling the cap. | Check capacity before opening another directory. Bound retained candidates without changing natural-order selection; exact selection still requires enumeration. Move enumeration off the UI thread if responsiveness must not depend on directory size. A display cap alone does not establish that guarantee. zag#ceff, zag#ekm5; zag#b500. |
| Filesystem root broke relative-path consumers | `src/view.zig:256-260`: `relOf("/", "/tmp/a")` expected another separator after the root and returned null. Recent/open-file boosts could miss files under root `/`. | Handle the root separator without allocation; zag#49r3. |
| Tree rebuild preserved only eight windows' row identities | `src/view.zig:152-175`: a ninth window lost hover/keyboard path preservation after rebuilding. | Remove the arbitrary preservation ceiling or preserve identity per window. zag#swmk, zag#2nck; zag#49r3. |

Navigation's transfer and session findings appear once in D5 and the persistence table. Its creation/rename and case-only findings appear together in D8. Its palette allocation failure appears in D11.

## Confirmed defects and limitations: platform, preview and measurement

| Finding | Exact source evidence and consequence | Targeted repair and prior references |
|---|---|---|
| Save As did not invalidate preview-relative links | `src/preview.zig:109-114,364-366,134-147`; caller `src/view.zig:3163`. `rename` changed title/path without rendering. Saving `/A/readme.md` as `/B/readme.md` left `[guide](guide.md)` resolved to `/A/guide.md`. | Schedule the existing debounced render after a path change and preserve selection/scroll behavior. zag#jfvn, zag#v7wy; guide `116-119`; zag#t9qf. |
| Preview mapping assumed one net edit | `src/preview.zig:596-608`: common-prefix plus total-length delta could not map unchanged middle content across disjoint edits. For old `aaa\nTARGET\nzzz` and new `XXXaaa\nTARGET\n`, equal lengths left the old target offset 4 rather than 7. | Map selection endpoints and viewport anchors through unchanged regions around their positions. A common suffix alone would not cover every disjoint edit. The source established the mapping limitation; the auditor did not exercise its UI effect. zag#2nwp; guide `97-98`; zag#t9qf. |
| Relative benchmark outputs could lose samples silently | `scripts/bench.sh:87-104,111-113`; `src/bench.zig:268-274,69-70,137-138`: the app interpreted relative `ZE_BENCH` from its own working directory, skipped failed opens, ignored writes and later exited successfully. | Canonicalize the created output directory and report failed/incomplete metric writes. `.omp/skills/zag-perf/SKILL.md:61` supplied relative `R`; zag#fazb, zag#wv2z; zag#w9r2. |
| Benchmark callbacks blocked asynchronous completion | `src/bench.zig:64-138,158-171,205-211,299-303`; `src/view.zig:4370-4372,97,103,79`: the benchmark slept/drew/flushed within one main-thread callback. A warm refresh queued completion but never cleared `quick_busy` before later rounds. | Advance explicit phase/index steps through actual main-loop callbacks and pace outside timed regions, not nested run-loop pumping. `bench.zig:151-154` claimed run-loop turns without supplying them. zag#fazb; zag#w9r2. Measurement bias magnitude remained unmeasured. |
| Icon hashing split paths containing spaces | `scripts/bundle.sh:39`: `find "$PWD/AppIcon.icon" -type f \| LC_ALL=C sort \| xargs shasum -a 256` lost filename boundaries. Later pipeline success could conceal failed hash input and publish a wrong cache key. | Preserve boundaries with NUL-delimited processing or `find -exec`, retain deterministic ordering and reject hash failures. zag#2smk, zag#0ex9; zag#sk8n. |
| AppKit open requests lacked completion replies | `src/main.zig:69-74,52-55`; installed `NSApplication.h:324`. `application:openFiles:` ignored the application argument; startup processing deferred filenames, and the source contained no `replyToOpenOrPrint:` call. | Reply after processing each request, preserve startup-deferred request boundaries and return an honest outcome. The missing required reply was source-confirmed; external timeout symptoms remained inferred. zag#jg6t covered startup ordering rather than replies; zag#rp3n. |

Benchmark stable-draft exposure appears separately in D9 because its conditional data-loss consequence takes priority over measurement quality. Accessibility teardown appears in D12 because ownership invalidation takes priority over platform grouping.

## Demonstrated small costs and dead weight

- **Settings preparation:** `src/settings.zig:759-784` scanned present options, then allocated/copied a root prefix before discovering no insertion was needed. An early all-present return would preserve the result while avoiding that work. Prior reference: zag#y6x7; tiny-binary decision `23-43`. Startup impact remained unmeasured; implementation group zag#56et.
- **Paste normalization:** `src/editor.zig:139-150` always allocated/copied a temporary payload, even for single-line text or already-matching line endings, before insertion copied into history and the buffer. Detecting whether conversion was needed would allow direct insertion in the unchanged case. Preserve zag#gdr3 and guide `384`; test LF, CRLF, mixed endings and undo.
- **Ignored scan parameter:** DocumentsAudit and NavigationAudit both found `rescanQuick(dir, _: ?*Doc)` at `src/view.zig:140`, with obsolete arguments at `44,4374`. Remove the ignored argument, its description and the behaviorless `was_palette` contribution when migrating those callers. Retain actual generation/root/hidden-file protections.
- **Redraw copying:** The rendering table recorded syntax-kind and prompt snapshots separately because their ownership and fade behavior differ. Neither finding justified a general memoization framework.

## Hypotheses and unresolved measurement questions

The auditors did not establish these items as implementation-ready defects:

1. **Pinned-row cache lifetime:** `src/view.zig:6214-6222,6372-6381,6699-6708` suggested that `finishFold` could rebuild rows and invoke hover before the next draw refreshed pinned indices. NavigationAudit identified the stale-index path but did not establish a complete crash sequence. A focused transition trace must settle the consequence.
2. **Fold geometry after unrelated refreshes:** `src/view.zig:184-241,3775,6271-6313` showed `refindFold` around fold-owned rebuilds rather than every rebuild. An activation refresh might invalidate cached fold rows/counts. The reviewer requested a transition test before a separate defect claim.
3. **Power-loss directory durability:** `src/files.zig:45-67` flushed the temporary file but not its containing directory. PersistenceAudit found neither an explicit power-loss contract nor a platform experiment that justified promoting this observation to a confirmed product defect.
4. **Release Find cost:** Source requested unused columns, but no reviewer inspected optimized machine code or measured the repeated-line workload. The confirmed source inefficiency does not establish a specific release-time stall.
5. **Performance deltas:** No auditor measured the latency or memory impact of cache copying, lexer suffix scans, discovery work or benchmark scheduling. Proposed repairs address source relationships; numerical speedups need parent-owned measurements after benchmark validity repairs.

## Fine-as-is choices and prior decisions

The audit distinguished defects from intentional choices and already-addressed history:

- **Active-page ownership:** `Doc.file` plus parked pages transferred ownership; the representation did not duplicate buffer ownership. zag#yxb3 already removed mirrored fields. A new document model would not repair the specific modal/transfer failures more directly.
- **Save As duplicate closure:** `src/view.zig:3211-3225` deliberately closed another tab after overwriting its path. Harsha approved this behavior in call 6648 on zag#f1yv. Neither DocumentsAudit nor PersistenceAudit reclassified that decision as accidental data loss.
- **Atomic save structure:** `src/files.zig:45-67` used a same-directory temporary, handled partial writes, flushed before rename and removed failed temporaries. Fix metadata/error boundaries rather than replacing the transaction. `files.read` with `Editor.initOwned` also avoided a second full-document copy, rejected nonregular input and bounded allocations.
- **Settings conventions:** `src/settings.zig:729-754` updated the effective last duplicate, preserved trailing comments and inserted root settings before sections. Preserve zag#jmk9. The two-pass theme parser made explicit colors independent of theme-key order. The compact decimal parser/formatter and field metadata did not justify a TOML dependency.
- **Draft timing:** Revision gating prevented nonediting refreshes from postponing ordinary checkpoints. Fix the never-checkpointed sentinel and error acknowledgement, not the timer design.
- **Rendering architecture:** One display link per window, card/strip invalidation and a separate caret layer matched the existing contract. One-shot holds avoided continuous frames during delays. Final-width wrapping avoided reflow during intermediate animation frames, as `docs/decisions/motion.md:47-49` required. `gfx.zig` already separated graphics/motion/cache helpers.
- **Cache representation:** Offset-based syntax entries avoided borrowed slices into growable storage; the bounded UI-line cache did not need a generic replacement. Preserve zag#j9kg. Incremental syntax propagation (`src/syntax.zig:253-302`) used touched ranges, convergence and suffix truncation rather than marking unvisited stale suffix states valid; the reviewers found no new trace that justified reopening zag#t7ts.
- **Editing semantics:** Replace All (`src/editor.zig:516-550`) shared matching rules, used nonoverlapping matches, grouped undo and excluded unchanged outer text; preserve zag#fj9c. Reload (`709-730`, regression `1515-1523`) aligned differences to UTF-8 boundaries; preserve zag#08aq. Lazy UTF-16 cache discard (`src/buffer.zig:232-247`) remained a valid recovery path, unlike corruption of authoritative indexes/history.
- **Discovery design:** Quick Open completion copied worker inputs and checked generation, root and hidden-file settings before publication (`src/view.zig:69-137`). Descriptor-relative `openat`/`fdopendir`, `NOFOLLOW` and unknown-type fallback preserved zag#c4jx and zag#49w6. `finder.best` avoided a result-sized allocation/full sort. zag#npqc had already rejected unmeasured hash-table replacement for linear sidebar lookups. Open-set mutation callers rebuilt the tree, so `Tree.fresh`'s open-count comparison alone did not establish a bug.
- **Menu-derived commands:** Retained menu items and `performActionForItemAtIndex:` avoided a duplicate command registry. Repair construction atomicity rather than replace the model; tiny-binary decision `58-60` documented that choice.
- **Existing lifetime safeguards:** Dissolve callbacks used per-card Objective-C keys, tab-menu actions checked document membership, and window teardown cleared its association. DocumentsAudit found no confirmed stale dereference in those inspected paths. Animation flags such as `going` and `closing` did not alone justify a split-tree rewrite.
- **Platform choices:** Typed Objective-C messaging matched the arm64-only target (`src/objc.zig`); the reviewer found no substantiated need for another bridge or `_stret` handling. Preview retained persistent source/font/style objects, released temporary parsing objects, transferred view ownership to AppKit and canceled deferred rendering on close. Process-lifetime classes/targets did not justify a teardown framework. Preserve existing accessibility approved in zag#1xsq; exclusions on new accessibility work did not authorize deletion.
- **Startup and build choices:** Pending filenames preserved startup input/order from zag#jg6t. The benchmark released created scroll events (`src/bench.zig:195-196`). Release stripping, benchmark exclusion and zero header padding (`build.zig:17-23,37`) supported the size contract; `build.zig.zon` introduced no dependency payload. Release unwind `.none` matched the tiny-binary decision. Optional `mise`/queue integration and public ad-hoc signing followed zag#0ex9; machine-specific requirements would regress public builds. Cross-file searches found callers for apparently spare graphics helpers, so the audit supported no broad graphics deletion.

## Maintenance and implicit-state conclusions

The reports located maintenance risk in a few repeated patterns, not in a lack of frameworks:

1. **A number sometimes stood for two different states.** Revision zero represented both "not checkpointed" and "checkpointed at zero." A nullable checkpoint marker or an explicit existing-draft prerequisite would express the missing distinction without a persistence state-machine library.
2. **A successful local operation sometimes implied a larger transaction had succeeded.** Text mutation preceded index/history allocation; path installation preceded draft cleanup; disk stamps advanced after rejected reads or failed merges. Each repair needs one explicit prepare/commit boundary and a result that reaches its decision-making caller.
3. **A helper's name hid reentrancy.** `install` could check disk, open a sheet and change active identity. Stable page/document identities and publication ordering address that effect more directly than another registry abstraction. Callers must not retain array slices or active-page assumptions across those calls.
4. **A cache key omitted a dependency.** Find ticks omitted wrapping inputs, horizontal width omitted tab width, and preview rendering omitted path changes. Repair identity/invalidation where the dependency changes; avoid a parallel cache framework with another invalidation convention.
5. **A terminal animation action assumed old context.** Fold completion toggled after Collapse All/root replacement; hidden springs retained busy state after their draw path disappeared. Cancel or settle the existing state at that transition rather than add polling or duplicate animation state.
6. **A user-facing limit looked like a resource limit.** Distinct-row tick caps did not bound match work; file caps did not bound directory visits; rendered-row caps did not bound sorting memory. Name and enforce the actual resource boundary without silently changing search or natural-order semantics.
7. **A benchmark simulated turns without yielding turns.** Here a small explicit phase/index state addressed a real scheduling requirement. That local state did not justify a shared state-machine framework for preview, animation or persistence.

Targeted changes beat broad replacements because the existing architecture already supplied the needed primitives: owned pages and stable IDs, allocator reservation, a shared atomic writer, revision invalidation, worker completion guards, tweens and offset-based caches. A replacement framework would add migration surface without making a failed checkpoint succeed, fixing a dangling pointer, or identifying a missing cache dependency. The audit supported concrete cleanup and smaller hot-path work while preserving established product decisions.

## Implementation status and reported checks

The parent reported all 20 ticket implementations complete. This is an implementation-status report, not a claim that every audited scenario passed execution. The original findings and hypotheses above remain the record of the inspected baseline; this document did not independently re-audit the applied changes.

### Review corrections and explicit tradeoffs

The parent reported additional review corrections for trailing-slash file creation, reload UTF-8 boundaries in both inputs, shell escaped separators, preview scalar/context scanning, a bounded discovery queue, and startup font defaults. These corrections qualify the initial implementation handoffs; they do not establish runtime coverage beyond the checks listed below. PersistenceReview passed the startup-default correction at `src/view.zig:11906`: `if (font == null) applySettings(conf)`. This setup-only fallback initializes fonts, glyphs and themes after an initial read failure; later failed reloads preserve accepted settings and stamps. This was source review, not an app launch.

The parent reported DiscoveryReview's final navigation integration review passed with no required fixes. That review traced worker publication; stale generation, root and close safety; allocation failure, loading and selection; fold and current-tween hit tests; palette and row identity; and exclusive file-operation callers. This was source review, not an executed UI test.

- **Syntax state memory, call 7957:** `State` now uses `usize`, increasing each cached line-state entry from 1 byte to 8 bytes on the target. That is 7 additional bytes per stored state entry, before allocation overhead. The richer state supports the syntax corrections but is an explicit memory tradeoff, not an unqualified performance or memory improvement. No whole-app memory measurement was supplied.
- **Discovery resources, call 7959:** The parent reported 64-child batches, at most 16 live cursors, and depth-only replay. This bounded-resource choice must remain distinct from a claim that total traversal work is constant or capped by the number of displayed results. No measured discovery latency was supplied.

### Executed checks reported by the parent

| Check | Reported result | Scope limit |
|---|---|---|
| Files tests | 12 passed | Module tests, not executed sidebar/AppKit interactions. |
| Buffer tests | Initial 13 passed; targeted allocator-failure check passed after a fixture correction | The initial pass alone did not establish allocation-failure coverage. The parent supplied no count for the later targeted check. |
| Editor reload tests | 5 passed | Reload-focused coverage, not a full editor suite. |
| Settings tests | 24 passed, including the imported 12 files tests | The imported files tests are not 12 additional independent cases. |
| Shell parsing | `bash -n scripts/bench.sh scripts/bundle.sh` passed | Parsing only, not bundle execution, icon-cache behavior or benchmark isolation. |
| Foundry app check | `foundry app check zag` passed in 2.4 seconds | This reported check is not an app launch or UI test. |
| Benchmark-enabled build | Capacity-wrapped `zig build -Dbench=true` passed | Compilation only; no benchmark launch or runtime measurements. |
| Release build | `zig build --release --prefix /tmp/zag-astra-audit-after` passed | The parent measured the unsigned output recorded above. |

No full suite, UI check or app launch was reported. `view.zig` tests are not in the test root: draft, transfer, modal and session AppKit paths lack executed targeted tests. The checks above must not be presented as end-to-end validation of those paths.

The parent supplied the successful checks and measured sizes above and confirmed the builds ran after the startup correction; the report author ran no checks or ticket actions. No app or benchmark launch, runtime performance result, or full behavioral verification was reported. The measured unsigned binary grew by 18512 bytes (+4.43%), with `__text` growing by 9760 bytes. These correctness repairs therefore increased binary size rather than shrinking it.

## Parent verification handoff

This checklist preserves the audit's requested coverage. The implementation-status section above records the limited checks subsequently reported by the parent; unlisted scenarios remain unverified. The report author did not execute these checks.

- **Highest priority, allocation failures:** Inject failures across buffer replace/joined edits/undo/redo; tab moves and window merges; window/pane/split construction and restoration; palette pair construction; settings merges; accessibility destruction. Require authoritative text/history/ownership to match the pre-operation state on failure, and ensure failed construction publishes no incomplete owner.
- **Persistence failures:** Cover failed draft writes before quit; failed first parent preparation followed by retry; Save As onto the backing draft; untouched duplicate/comparison restoration; rejected binary reload followed by Save; failed settings read without acknowledging its stamp; dirty config menu merges; metadata-copy rejection; long basenames; dangling targets; no-replace races and case-only rename; versioned session round trips containing tab delimiters and legacy ordinary paths.
- **Modal and identity transitions:** Cover Show Changes during registry growth, no-space comparison fallback and subsequent return/save; distinguish original page identity from active card identity throughout.
- **Editing and syntax:** Cover trailing LF/CRLF Delete Line cases and undo; malformed UTF-8 movement/deletion symmetry; unclosed strings and comment markers; long unmatched Markdown brackets with later markup; multiline HTML attributes and closing-tag boundaries; matching fence type/length; language-specific hashes; unchanged and converted paste normalization. Compare state-only and token-producing lexer results and review preview's state consumer.
- **Rendering/navigation:** Cover hidden-sidebar spring settlement, equal-total-row wrap changes, internal tabs/UTF-8 horizontal range, duration-changing retargets, cache reuse under invalidation, outgoing prompt fades, animated hit geometry, Collapse All/root switches during folds, selection preservation after refresh, root `/`, and more than eight windows.
- **Discovery/platform/measurement:** Cover cold-scan publication and stale generations, deep/wide directories without descriptor loss or silent ordering changes, large-score arithmetic, preview path-only invalidation and disjoint edits, startup-deferred open-request replies, icon paths with spaces, absolute benchmark outputs/write failures, actual main-loop completion between benchmark phases, and rewritten benchmark draft paths that cannot unlink stable drafts.
- **Coverage gap:** `src/tests.zig:1-9` imported core modules but not `view.zig`. Passing existing unit tests alone would not exercise modal ownership, quit approval, draft scheduling or window transfers. The parent must state any remaining coverage gap rather than treat a core-suite pass as proof of those flows.
- **Measurements:** The parent supplied the release binary and `__text` results recorded above. Runtime performance remains unmeasured; report any later performance result only from the repaired harness and distinguish it from these static findings and build-size measurements.

## Evidence provenance

The report preserved the delivered findings from `agent://RenderingAudit`, `agent://PersistenceAudit`, `agent://DocumentsAudit`, `agent://NavigationAudit`, `agent://PlatformAudit` and `agent://EditorAudit`. Each scout reported read-only work and no ticket mutation. Several scouts could not write their proposed `local://` artifacts because their tool inventory prohibited writing; their delivered reports supplied the evidence instead.

The consolidation merged duplicated draft-zero, transfer, session, ignored-parameter, Find and syntax-cache findings. The report retained prior ticket references, exact audited source coordinates, inferred scenarios and contrary product decisions rather than treating every suspicious pattern as a new defect. Later parent messages supplied implementation completion, review corrections, limited tests, successful build/check commands and measured binary growth, which are recorded separately. Navigation integration and startup-default correction reviews passed. No app/benchmark launch or runtime performance result was supplied.
