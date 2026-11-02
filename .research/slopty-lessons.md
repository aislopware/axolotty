# Slopty lessons for Axolotty (2026-11-02)

Read-only study of `/Volumes/Lacie/Workspace/oss/slopty` (pure Rust + GPUI, 2,416 commits from
2026-09-04 to 2026-11-01). Sources: `CLAUDE.md`, `HANDOFF.md`, `docs/{TESTING,DEV,ARCHITECTURE,
DECISIONS,MEASUREMENTS}.md`, `docs/knowledge-from-slop-desk.md`, `docs/decisions/*.md`
(51k lines), `fuzz/`, `xtask/`, `.config/nextest.toml`, and slopty's own studies
`.research/{testing-inventory,testing-rust-modern,build-speed}-2026-10-29.md`,
`.research/{e2e-reduction,speed,check-speed}-2026-10-31/`. All slopty paths below are relative to
the slopty root.

**The short version.** Slopty's tests ran fast and its testing ideas were good. Its CI, e2e and
process cost a lot. On CI a test shard spent 1,627 s building and 436 s running 3,629 tests.
The UI crate ran 310 tests in 1.0 s, and the shell crate 1,544 tests in 5.4 s. The cost was
compile, cold runners, seven target triples, e2e on simulators and VMs, and the agents
coordinating each other. **Keep the oracles: models, metamorphic relations, virtual time,
semantic snapshots, corpus replay. Drop the infrastructure.**

---

## 1. The testing layers, as built

`docs/TESTING.md` lists four layers, fastest first. On 2026-10-29 they were reorganised under
"Simulation, models and mutants carry the tests; e2e is a smoke set"
(`docs/decisions/testing.md:1422`).

### 1.1 Unit tests over pure logic, with fakes behind traits
- About 5,500 test attributes across 40 crates (`testing-inventory` §1.1). Pure crates
  (`slopty-grid`, `-proto`, `-core`, `-predict`, `-math`, `-settings`, `-theme`, `-markdown`)
  forbid `unsafe` and hold the logic. Fakes stand at the edges, e.g. `slopty_input::Recorder` for
  event injection.
- **Mocks of our own logic are banned.** A "door" (clock, id/RNG, spawner, PTY I/O, FS/watcher,
  platform) has a real side and a simulated side. Both sides pass one shared **contract suite**
  (`testing.md:1422` item 2).

### 1.2 Virtual time (deterministic clocks)
- Daemons, CLI and client core read only tokio's clock. clippy bans `Instant::now` and
  `SystemTime::now` in them (`crates/slopty-net/clippy.toml`, `crates/slopty-shell/clippy.toml`).
  Their tests run under `#[tokio::test(start_paused = true)]`, so every wait is exact.
- The UI shell has one clock door, `crates/slopty-shell/src/clock.rs`. Every animation in a
  frame reads the frame's single moment (`App::frame_time`).
- **Measured payoff:** the session actor's five timing tests took 12.5 s on the wall clock,
  needed retries, and claimed every test thread. On the paused clock they take **0.07 s**, and
  200 runs passed (`testing.md:1736`).
- Simulated network: `crates/slopty-shape/src/sim.rs` is an in-memory datagram network on the
  paused clock, seeded per-direction shaping (delay, jitter, loss, reorder, blackout, NAT
  rebinding). `slopty-net/tests/sim.rs` runs real endpoints over it.
- Fake PTY: in `crates/slopty-worker/tests/session_actor.rs` the test *plays the PTY's slave end*
  (`Played`). The actor runs on the test's `LocalSet`. A subtle trap: the paused clock can jump
  while bytes are still crossing the kernel's PTY. The harness counts bytes in flight and holds
  the clock until they arrive.

### 1.3 Property, model and metamorphic tests
- proptest: `crates/slopty-grid/tests/{line_props,scrollback_props}.rs`,
  `crates/slopty-proto/tests/codec_props.rs`. The gate runs few cases; nightly runs 4,096 cases,
  which took **1,685 s** (`testing-inventory` §2.5). Only 7 property tests and **0
  state-machine tests** existed at the 10-29 audit, and that gap was flagged as the main weakness.
- **Metamorphic relations for the terminal engine** (`fuzz/src/terminal.rs` header):
  - *byte chunking*: a second engine fed the same bytes one byte at a time must show the same
    screen, cursor, modes and session state after every write;
  - *resize round trip*: logical lines and the cursor's place survive a resize on the primary
    screen;
  - *expansion*: the alternate screen never reflows, so growing it keeps every cell;
  - *paging*: a scrollback page is the same lines however the history is cut;
  - *checkpoint replay*: a snapshot replayed into a fresh engine shows the same cells, OSC 133
    marks, OSC 8 links, soft wraps, modes and key encodings, and still matches after more input;
  - *multi-viewer*: every viewer applying the diffs it was sent equals a fresh engine's full
    frame (`crates/slopty-engine/tests/scroll_diff.rs`, seeded).
- **Metamorphic relations for the agent transcript decoder**
  (`crates/slopty-agent/tests/metamorphic.rs`): arrival in pieces of any size, cut inside UTF-8
  and in any order; a file rewritten shorter then grown; unknown record types and unknown fields
  change nothing. Every relation runs on every captured real scenario.
- **Paint oracle** (`crates/slopty-terminal/src/view/paint_oracle.rs`): the incrementally keyed
  grid must paint exactly what a grid painted from scratch paints. This is checked with a stub
  glyph system and again with real Core Text.
- **Whole-UI model fuzzer** (`crates/slopty-shell/src/shell/fuzz_tests.rs`): seeded sequences of
  user and engine steps on Mac, iPhone and iPad windows. Every step is checked against the model's
  selection, focus and a11y-tree invariants (every control named, nothing overlaps, shortcuts
  spelled). Failures shrink by delta debugging to `SEED` and `KEEP`. The gate runs 4 seeds × 8
  steps, about 1 s; the long run is nightly.

### 1.4 Differential testing (inherited from slop-desk, `docs/knowledge-from-slop-desk.md` §1)
- **Static double-reader oracle:** feed one terminal, then read it through libghostty-vt's
  `RenderState` (the render path) and through its `Formatter`, an independent reader over
  `Screen`, and diff. It ran over ghostty's own fuzzer-minimised corpus
  (`test/fuzz-libghostty/corpus/stream-cmin`, **3,271 files, ships inside the ghostty tree**) in
  **about 6.5 s on all cores**. Break tests: a 1-row shift failed 238 of 3,271 files, and a 40 px
  offset failed 587.
- **Incremental vs fresh sweep:** recorded real programs (nvim, fzf, lazygit, less, opencode;
  461 `read(2)` chunks with their real boundaries) fed in their real chunks must end
  byte-identical to a one-shot feed. **This caught the production bug the static oracle could
  not**: a cursor-only change (`?25h`) on a "clean" grid was reported as unchanged. Eight other
  planted bugs (key-encoder or mouse-mode desync, bracketed paste always off, focus reports never
  armed, resize never reaching the engine, ...) pass the static oracle and fail this sweep.
- VT conformance itself is upstream's job. Ghostty runs esctest headless against libghostty-vt
  (`test/esctest`, about 1 min, report-only). **Slopty's risk was in its own glue:** extracting
  the grid, damage tracking, key/mouse encoding, and resize plumbing. Test that glue.

### 1.5 Headless UI: semantic snapshots before pixels
- `#[gpui::test]` (675 of them) gives a real layout, `simulate_keystrokes`/`simulate_click`, and
  views read like a DOM (`debug_bounds`, `painted_quads`, a11y tree). No pixels and no process.
- **Three golden kinds per surface** (`crates/slopty-shell/src/shell/goldens.rs`,
  `.../goldens/snapshots/*.snap`; 445 `.snap` files):
  1. *a11y tree as text*: one line per node (`Tab │ Providers (focused)`). A changed word fails
     as a text diff. Pixels cannot reliably see a changed word (`testing.md:1039`).
  2. *scene lines*: one line per primitive (quad bounds, clip, colour, radii; glyph runs with
     colour). This covers layout, colour and order as text.
  3. *PNG*, only where only pixels can say it (glass, Metal). The plan was about 12 of 104.
- Dark mode is checked as a *relation*, not a picture: the dark scene must place every node
  identically, paint no colour unique to the other theme, and keep contrast ≥3
  (`scene::fainter`).
- **Retained-frame oracle** (`crates/slopty-kit/src/retained.rs`, `TESTING.md:19-84`): redraw
  the same state from scratch and diff it against what the incremental frame showed. It catches
  "view not notified, so stale on screen while every state assertion passes". It can run on
  every frame (as Chromium's `checkUnderInvalidation` does).
- **Pixels in the test process:** a headless Metal renderer draws the real window offscreen in
  milliseconds, with no app and no window server (`testing.md:1955`). This replaced 108 of 118
  e2e PNGs.
- **Comparator** (`crates/slopty-testkit/src/golden.rs`): channel slack 4; edge slack 64 where
  both neighbourhoods explain it (macOS glyph anti-aliasing drift); fail if any **16×16 window
  has >24 differing pixels**, or a straight run of 64 differs, or >0.2% of the frame (0.05% on
  the simulator). Rationale: GPU noise scatters while real changes are compact (pixelmatch v8).
  A missing golden fails unless the run accepts; CI never writes goldens. Each golden has one
  writer.

### 1.6 App self-test (e2e), now a smoke set
- The app, built with feature `e2e`, serves a JSON-lines **control socket**
  (`SLOPTY_TEST_SOCKET`) with `keys`, `type`, `click`, `scroll`, `resize`, `dump`, `render`,
  `quit`. Input goes through the window's own dispatch, so bindings and focus run as for a
  user. Each command settles on the next frame before it answers (`testing.md:14`). No external
  event posting and no screen capture. `dump` returns the model plus the a11y tree plus surfaces.
- The harness (`crates/slopty-e2e`, `harness::Stack`) starts real daemons in a temp dir named
  for the test, with a clean environment and pinned binaries.
- Shrunk to seven smoke cases S1–S6 plus VM (`xtask/src/gate/impact.rs`). They are chosen per
  change by a reachability map over the dependency graph and `cfg`s, and all run nightly.

### 1.7 Agent stand-ins and recorded fixtures
- **No test runs a signed-in agent.** `slopty-stub-claude` (`crates/slopty-testkit/src/
  claude_tui.rs`, 970 lines) is a TUI in a real terminal. It writes Claude Code's registry
  (`sessions/<pid>.json`) and transcript JSONL, runs the hooks it is given, and is scripted by
  its prompts (`ask`, `hold`, `STUB_TURNS`). It records every read (`STUB_RECORD`).
- Real transcripts are recorded as fixtures (`crates/slopty-agent/tests/fixtures/conversation/`)
  and re-recorded on each Claude Code release. A hooks drift check compares against the Agent
  SDK's published `HookInput` union.
- A canned Messages API on loopback (`xtask/src/canned.rs`).

### 1.8 Fuzzing
- `fuzz/` sits outside the workspace with 19 targets: every decoder a peer's bytes or an agent's
  records reach (wire messages, hooks, registry, transcript, markdown, terminal output through
  the engine). One entry point builds for both libFuzzer and AFL++.
- Seeds are captures of real programs (`fuzz/seeds/terminal/*.vt`: alt-screen, kitty graphics,
  modes/queries, scroll region, SGR+links, shell prompt, sync update, wide/combining) plus a VT
  token dictionary.
- Targets also bound the heap: more than 64 bytes per input byte (or more than 2 MiB) is a crash
  (`slopty_testkit::alloc::Counting`).
- **Corpora are regression tests:** the minimised corpus (≤2 MiB per target, 28 MB total) and the
  crash regressions are committed. `fuzz/tests/regressions.rs` replays them on an ordinary build
  in the gate, on every core. Fuzzing itself runs nightly (1 min per target).

### 1.9 Budgets and perf: count, don't time
- **Allocation counts** in the gate (`crates/{slopty-engine,slopty-media,slopty-grid}/tests/
  allocs.rs`). A counting global allocator measures, per thread, what a hot path allocates in
  steady state (keystroke echo, Enter at prompt, frame encode). Fan-out asserts equality: eight
  viewers cost exactly what one does.
- **Retired instructions** per operation (`proc_pid_rusage` `ri_instructions`), held within 5%
  of `xtask/budgets.toml`. Wall time is only a nightly trend: "wall time cannot pass or fail on a
  machine other sessions load" (`testing.md:395`).
- Soak: real daemons under scripted load. Footprint growth is judged by a Theil–Sen slope over
  900 s, with descriptors, threads and `leaks <pid>` (`testing.md:761`). A latency probe
  (`slopty-probe echo`) measures keystroke-to-echo outside the gate.

### 1.10 Deep checks and test hygiene
- Nightly or weekly: Miri, ASan/TSan/RTSan, loom (audio ring), `cargo hack` features, coverage,
  `cargo mutants` (tier A: every mutant in the diff must be caught), Metal validation, `leaks`.
- **"Red means something"** (`testing.md:1675`): every check carries a **canary**, a planted
  defect it must fail on for the planted reason (`xtask/src/deep/canary.rs`). Why: from 10-04 to
  10-11 no sanitized test ran while every job was green, and a missing `pipefail` made every red
  pass.
- **Flakes fail** (`.config/nextest.toml`: `retries = 0`, `flaky-result = "fail"`). A flake is
  called fixed only after n clean runs with (1−p)^n ≤ 5% (14 runs for 1-in-5, 29 for 1-in-10)
  (`tooling.md`, "A flake is measured").
- **A test that leaves a child process behind fails** (nextest leak-timeout).
- **A test waits on the event it means**, never a wall-clock step budget; a hang is the
  runner's timeout (`testing.md:1092`). Six CI "failures" came from this.
- Live tests are explicitly ignored with the command that runs them (`#[ignore = "live: …"]`),
  never silently gated by an env var. Inside the VM a skip counts as a failure.
- A test that sets a process-wide fake holds a lock until it ends. nextest's process-per-test
  had hidden that race (`testing.md:833`). **This matters more in Swift Testing, which runs every
  test in one process.**

---

## 2. Value per CPU-second vs cost sinks

### 2.1 High value, low cost (keep)
| Technique | Cost | Evidence of value |
|---|---|---|
| Pure unit and model tests behind doors | ms each; 1,544 shell tests in 5.4 s | most behaviour pinned at the lowest layer |
| Virtual time | 12.5 s → 0.07 s; flakes and retries gone | `testing.md:1736` |
| Incremental-vs-fresh and byte-split sweeps over recorded VT | seconds | caught the real cursor bug and 8 planted ones the static oracle missed |
| Double-reader oracle over ghostty's stream-cmin corpus (3,271 files) | about 6.5 s parallel | free corpus, break-tested |
| a11y-tree and scene snapshots as text | ms; diffs reviewable in git | catches word, layout and colour drift that pixels miss |
| Fuzz corpus replay in the gate | seconds | every past crash stays fixed |
| Allocation and instruction budgets | deterministic, no wall clock | regressions fail without flakes |
| Stub agent TUI + recorded transcripts + metamorphic decoder tests | seconds | no signed-in agent; robust to Claude Code updates |
| Seeded whole-UI fuzz, short in the gate | about 1 s | finds focus, a11y and stale-frame bugs |
| In-process headless Metal goldens | ms per frame | replaced a 31-min e2e round for 108 of 118 frames |

### 2.2 Cost sinks (measured)
- **Compile, not tests.** Green gate: median **9.8 min wall, 50.6 runner-minutes**. 36% went to
  building test binaries, 29% to four lint jobs (one per triple), 20% to job setup, and **13% to
  running tests** (`build-speed-2026-10-29.md` §0). One CI shard: `nextest build` 1,627 s vs run
  436 s. `slopty-shell`'s test harness alone was 227 s on a 3-core runner.
- **Cold starts.** A one-line leaf edit cost 11–19 s warm vs 27–41 s cold. A core-crate edit cost
  37–90 s, because cargo has no early cut-off. Cold clippy rebuilt 1,335 units, including
  ghostty's Zig build (126 s) and Luau (67 s). 411 proc-macro and build-script units were built
  **twice** because of a `--target` mismatch.
- **Disk.** `target/` was 117–212 GB, growing about 130 GB/day, from one warm dir per lane.
  Pruning became a subsystem (`xtask/src/prune*`).
- **e2e.** One round (app + iPhone + iPad) took about **31 min**: build 42%, simulator boot and
  settle 28%, tests 25%. An iOS job once took 44 min, then 6 min after a week of tuning
  (`MEASUREMENTS.md` 2026-11-01). **All of the last 10 `e2e.yml` runs were red, and 5 of 6
  scheduled runs were red from UI drift, not flakes.** Full-window PNGs (118) caused 20 golden
  commits in 2.5 days, some touching 83–282 files.
- **Deep nightly.** Miri 32–41 min, fuzz 37–39 min, TSan 70 min, coverage 43–73 min (then
  dropped to weekly), proptest at 4,096 cases 28 min, mutants on `slopty-proto` about 1 h per
  shard ×4. **Red 8 of 9 nights** before canaries existed. Mutation run: 299 of 1,459 mutants
  missed (proto 71.5%, predict 78.5%).
- **Wall-clock tests** produced most flakes (per-step budgets, "echo within 50 ms", load-bound
  bounds).
- **Orchestration and agent process.** Lanes were model-bound: generation took 56–64% of lane
  time and checks only 11–17%. Review→fix→re-review took 69–117 min per checkpoint, and
  lock-moving serialization 25–34 min per lane (`speed-2026-10-31/A-where-time-goes.md`). Push
  to main: median 16 min, p90 64 min, max 107 min (`MEASUREMENTS.md` 2026-10-12).
- **Infrastructure churn.** `xtask/` is **33,868 lines** of Rust orchestration (gate, lanes,
  remote, e2e, VM, GitLab, prune, canaries, ...). CI moved from hosted runners to warm runners on
  this Mac, then tart guests, back to hosted ("this Mac runs none", 99 GB freed), then office
  Macs, all within about 4 weeks.

---

## 3. Rules to port to Axolotty (Swift 6.4 + C + prebuilt libghostty-vt)

Target: **the whole default suite under about 30 s locally (build plus run), one triple, no
simulator, no VM.**

### 3.1 Module layout so tests never touch AppKit
```
Package.swift
  GhosttyVT        binaryTarget (xcframework, checksum-pinned; never built in the loop)
  AxCore           pure Swift: models, reducers, attention ladder, agent-state machine,
                   hook/transcript/registry decoders, session/workspace model. Foundation only.
  AxTerm           libghostty-vt wrapper: Terminal, render-state → GridSnapshot, key/mouse
                   encoders, damage. No AppKit.
  AxScene          GridSnapshot + Theme + Metrics → Scene (rects, glyph runs, cursor,
                   selection, decorations) as plain values. No Metal, no AppKit.
  AxRender         Scene → Metal (and Core Text glyph atlas). Thin.
  AxPTY            PTYIO protocol + real posix_openpt impl + in-memory fake.
  AxApp            AppKit views, menus, windows. Thin glue only.
Tests/
  AxCoreTests, AxTermTests, AxSceneTests   default lane (fast, parallel)
  AxRenderTests                            pixel goldens, Metal (separate command)
  AxLiveTests                              real PTY + real shells, stub agent, control socket
```
- Default lane = `swift test --filter 'AxCoreTests|AxTermTests|AxSceneTests'`, or a test plan
  holding exactly those targets. Test targets *are* the lanes, so no env-var gating
  (slopty's "a live test reads no variable to decide").
- `AxApp` gets only a handful of tests. Its behaviour is pinned below it, in a view-model or
  reducer that `AxCore` owns.
- One triple only (arm64-apple-macosx). No iOS, Linux or simulator targets until there is a
  product reason.

### 3.2 Swift Testing specifics
- Swift Testing runs tests **in parallel, in one process**. Slopty's process-wide-fake race
  shows up immediately here. Rule: **no singletons in AxCore/AxTerm.** Inject clock, IDs, RNG,
  FS and PTY through initialisers. Where a global cannot be avoided, use `@Suite(.serialized)`
  on that suite only.
- Name tests as sentences (slopty: `a_key_after_a_pause_does_not_wait_for_the_checkpoint`):
  `@Test("a cursor-only change after a clean frame is still drawn")`.
- Parameterise over fixtures with `@Test(arguments: Fixtures.vt)`, one case per recorded
  stream, so a failure names the file.
- Tags (`.vt`, `.scene`, `.agent`, `.metal`, `.slow`) are for Xcode test plans and reports. The
  CLI split stays by target. Give the default lane a `.timeLimit(.minutes(1))` trait, and make
  the runner script fail if the lane exceeds its budget (move tests out rather than raise it).
- Use XCTest only where it is still better: `measure(metrics: [XCTCPUMetric()])` for
  instruction counts, and nothing else.

### 3.3 Determinism doors
- **Clock:** take `any Clock<Duration>` (or an own `AxClock` protocol with `now` and `sleep`)
  everywhere. Tests use a manual clock (`TestClock` from swift-clocks, or a 50-line own one).
  Ban `Date()`, `.now`, `ContinuousClock()`, `DispatchTime.now`, `CFAbsoluteTimeGetCurrent`,
  `Task.sleep(` outside the door with a SwiftLint custom regex rule or a `grep` step in the
  check script. A UI frame reads one moment per frame.
- **PTY:** `protocol PTYIO { func read() async -> [UInt8]; func write(_:); func resize(_:) }`.
  Unit tests use an in-memory pair where the test plays the program. A small **contract suite**
  runs against both fake and real (`posix_openpt`) in `AxLiveTests`. Avoid slopty's
  "paused clock vs bytes in the kernel" trap by keeping real-PTY tests off the manual clock.
- **IDs and RNG:** injected, seeded. Every randomized test prints its seed and reruns from
  `AX_SEED`.
- Spawned processes get a clean environment (fixed `HOME`, `PATH`, `TERM`, locale). A test that
  leaves a child running fails (check in a suite-level teardown).
- Wait on events, never on wall-clock step budgets. Let the runner's time limit catch hangs.

### 3.4 Terminal correctness (the highest-value block; all in the default lane)
1. **Recorded VT streams with real chunk boundaries.** Store them as `Tests/Fixtures/vt/<name>.vt`
   plus `<name>.chunks` (read sizes) or a ttyrec-like framing. Record nvim, less, fzf, lazygit,
   htop, `claude` (stub and, once, real), zsh prompts with OSC 133/7, kitty keyboard, sync
   update 2026. Keep them small (KBs).
2. **Byte-split invariance:** feed the stream one byte at a time vs whole vs real chunks. Assert
   the same screen, cursor, modes, title/pwd/OSC state, and the same **GridSnapshot / Scene**.
3. **Incremental vs fresh:** apply damage-driven updates frame by frame. The final Scene must
   equal one built from scratch for the final state. Cursor-only changes and mode changes count.
4. **Double-reader oracle:** compare the render-state extraction (`render.h`) with
   `formatter.h` plain text over ghostty's `test/fuzz-libghostty/corpus/stream-cmin`
   (3,271 files, already in `.research/bench/ghostty`). Copy or pin a subset. Run a
   deterministic sample in the default lane (for example every 8th file) and all of it in a
   nightly or `--full` run.
5. **Resize relations:** primary-screen logical lines survive a resize; the alt screen keeps its
   cells when it grows; snapshot/restore round-trips (`snapshot.h`).
6. **Encoders** (key/mouse/paste/focus): table tests built from Ghostty's own
   `SurfaceView_AppKit.keyEvent` construction. slop-desk shipped a wrong key-press shape and
   wrong wheel quantization.
7. Do not re-test VT parsing: that is upstream's job (esctest, fuzzers). Test the glue.

### 3.5 Rendering without a GPU
- **The Scene is the test surface.** `AxScene` produces a value list (rect, glyph run with font
  id and positions, colours, cursor shape, underline kind). Snapshot it as sorted text lines,
  like slopty's scene `.snap` files. This gives no pixels, runs in ms, and diffs readably.
- Add a stable-dump fake for glyph metrics, so scene tests don't depend on installed fonts. Run a
  few with real Core Text (as slopty's `paint_oracle` does twice).
- **Metal pixel goldens** live in `AxRenderTests`. `MTLCreateSystemDefaultDevice()` in the test
  process renders offscreen to a texture and reads it back. Use few goldens, scoped to a
  component (cursor shapes, box-drawing sprites, underline variants, ligature fast path, wide-glyph
  cursor), never the whole window. Port slopty's comparator constants (§1.5).
- Regression tests for slop-desk's Metal bugs: draw **count** not capacity; underline under
  glyphs; bold doesn't brighten unless configured; a wide-cell cursor covers 2 cells; sync mode
  2026 holds frames (1 s timeout); draw skips when clean.
- **a11y as text oracle:** dump the NSAccessibility tree of key views (role │ label │ value │
  focused) as text goldens. It tests VoiceOver and catches word drift.
- Golden workflow: a missing golden fails; `AX_ACCEPT=1` writes; CI never writes. One writer
  per golden. Goldens live beside the test in `__Snapshots__/` (swift-snapshot-testing) or
  `Tests/<Target>/Goldens/<suite>/<name>.{txt,png}`.

### 3.6 Agents without signed-in agents
- `ax-stub-claude`: a small executable (Swift or shell) that behaves like Claude Code's
  observable surface. It posts hook JSON to our socket, writes `sessions/<pid>.json` and
  transcript JSONL, and is scripted by its prompt (`ask …`, `hold`). It records what was typed
  and when.
- Commit real recorded hook payloads and transcripts as fixtures. Re-record on Claude Code bumps
  and pin the version in a decision.
- Metamorphic decoder tests: split arrival, truncation and regrowth, and unknown fields and
  record types change nothing.
- Model the agent-state machine (§4.1) as a pure reducer in AxCore, with model-based tests: a
  random sequence of hook events and PTY facts vs a simple reference model.

### 3.7 UI e2e: a control socket, not XCUITest
- Debug builds only: the app listens on `AX_TEST_SOCKET` (JSON lines `keys`, `type`, `click`,
  `resize`, `dump`, `render`, `quit`). Events go through the app's own dispatch, and each command
  answers after the next frame. `dump` returns model + a11y tree.
- Keep **≤5 smoke tests** in `AxLiveTests`: launch, shell echo, split/close, agent attention
  via the stub, relaunch with restore. Run them on demand or before a release, never in the
  default lane.

### 3.8 Perf without flakes
- Use counts, not times. For alloc counts of C/Swift hot paths, use a malloc-zone hook or
  `malloc_zone_statistics` deltas around the operation in a single-threaded test. For CPU work,
  read retired instructions via `proc_pid_rusage(RUSAGE_INFO_V4).ri_instructions`, held within
  5% of a checked-in `budgets.json`. Keep wall time and latency (keystroke→glyph, using a probe
  tool) as a trend file only.
- Track these from the start: bytes→Scene for a full-screen TUI frame, idle draw = 0 Metal
  submits, a keystroke echo allocates ≤N blocks.

### 3.9 Fuzzing, cheaply
- Fuzz only *our* decoders that take untrusted bytes: hook JSON, transcript lines, OSC payloads
  we parse ourselves (OSC 7501-like status, OSC 9/777 notifications), and the control socket.
  libFuzzer harnesses in C (or a swift.org toolchain with `-sanitize=fuzzer`; unverified for
  Swift 6.4 on macOS) run nightly or by hand.
- **Commit minimised corpora and crash repros, and replay them as a parameterised Swift Testing
  test in the default lane.** This was the cheap half of slopty's fuzzing value.

### 3.10 Hygiene rules to adopt verbatim
- No retries. A flake is a failure, and it is fixed only after the (1−p)^n ≤ 5% clean runs.
- Every slow or nightly check has a canary (a planted defect it must fail on for the planted
  reason), plus `set -o pipefail` in every script.
- A behaviour is pinned at the lowest layer that can see it. Upper layers only prove the seams.
- Run only what a change can reach. With about 6 small targets, SwiftPM's incremental build is
  the reachability map: do not build an impact-map tool.
- One check script (`script/check`), under 100 lines. No orchestration framework.

---

## 4. Product and architecture lessons for an agentic terminal

### 4.1 Agent detection (slopty TUI-first, plus slop-desk's fusion machine)
- **Read agents only through their own records and published doors**: Claude Code hooks for
  status, its live-session registry `<config>/sessions/<pid>.json` (names the session a process
  holds; moves on `/clear` and `/resume`), and its transcript JSONL plus subagent files,
  followed by FS events. **Never read the screen**; slopty also ruled "Nothing reads a
  terminal's title" (2026-10-17, `agents.md`). For programs with no adapter, accept a status
  OSC (slopty's `OSC 7501`, `terminal.md:3935`) as the generic door.
- **Never type into an agent at a dialog.** Never answer for the person, never touch
  credentials. If an orchestrator must type: bracketed paste, then Enter as a separate write at
  least 200 ms later, after the TUI has read the paste (Ink treats an Enter in the same read as
  part of the paste).
- slop-desk's hard-won detection rules (`knowledge-from-slop-desk.md` §5):
  - Tier 1 (the agent's own hooks or a `ctl report working|blocked|done|idle` verb any wrapper
    can call) is authoritative. Inference may corroborate but never overrule it.
  - Coverage is per session, not a recency window: a question unanswered for 10 minutes is not
    a dead feed.
  - Dissent watchdog: 3 s to let evidence *raise* a block, 10 s to *release* one. Hooks do not
    reset it.
  - Block ledger = a **set keyed by `tool_use_id`**, not a bool, because batches mix
    `AskUserQuestion` with `Bash`.
  - `PostToolUseFailure` also ends a call. Esc = finished turn with **no `Stop`**.
  - **Session ownership:** a nested `claude -p` inherits the pane env and posts hooks to the
    parent's pane. Claim the pane on the first id-carrying event and drop other session ids.
    Allow a takeover only when the pane is at rest (crash restart).
- **Don't build a GUI replacement for the agent's TUI.** Slopty built a GUI-first "driven" chat
  (composer, approvals, cards), then deleted it on 2026-10-29 (`agents.md:7`): no GUI covered
  all of Claude Code's TUI or kept up with its releases. Keep the GUI read-only toward the agent:
  status, tasks, subagents, changed files, a turn timeline. The TUI does approvals.

### 4.2 Attention and notifications (`docs/decisions/layout.md`, 2026-10-30)
- **One state vocabulary everywhere:** at work (spinner, blue), needs you (amber, glyph names
  the need), failed (red), done-unseen (green ✓, heavier title until looked at), at rest (no
  mark). The same mark goes on the sidebar row, titlebar, pane header, picker, inbox,
  notification and Dock badge. "Seen" is one state.
- **The session list is stable:** grouped by project/repo, in start order, **never re-sorted by
  state**. Done is a mark, not a group. Sessions idle for 72 h fold into "Inactive". Collapsed,
  the sidebar is a rail of the loudest mark per project.
- **Attention is an inbox and a jump, never a feed:** the inbox is ordered needs-you → failed →
  done-unseen → working, keyboard-only, and answers nothing. ⌘J jumps to the next session that
  needs you.
- **Notifications point, they don't talk:** muted for the session on screen; a system
  notification only when the session or app is in the background, and only after a real wait;
  withdrawn once seen; a click lands on the session with a 0.4 s accent fade. The Dock badge
  counts needs-you + failed. A need left open is re-notified once, at 30 min. Hold phone pushes
  while a client is focused.

### 4.3 Window and workspace (what worked in UX)
- "The window is a terminal, not an app with a terminal in it": one row of chrome taking the
  terminal's background (follows OSC 11). The terminal gets ≥80% of the width. No permanent right
  column; inspector, files, changes and browser are summoned panes (⌘I and others), with Esc
  back to the terminal.
- Splits follow Ghostty's craft: a 1 pt divider with a 7 pt grab target, panes snapped to whole
  cells, double-click to equalize, unfocused panes dimmed by brightness (about 0.85, no hue
  shift), a thin accent ring on an unfocused pane that needs you.
- Model: project (folder/repo) → tabs → split tree (`workspace.md`, "Tiling replaces the
  scrolling strip"). **The infinite canvas was built and retired twice** (slop-desk and slopty).
- Terminal craft: never scroll the reader away (a "↓ N new lines" pill); find as Ghostty's
  floating card; an exit bar with the code; a "120 × 40" overlay on resize; a pending-chord
  capsule; Secure Keyboard Entry when the PTY stops echoing (password prompt), read from the PTY.
- ⌘K picker over all sessions (a filter that creates on no match) plus ⇧⌘P palette ranked by
  frequency and recency. Every app key is a ⌘ key; ⌃ belongs to the TUI.
- Worktrees: a new agent may start in its own worktree; setup scripts run; worktrees with
  unpushed commits are kept and landed ones swept.
- **PTY custody** (slop-desk superd, slopty ptyd): a tiny, rarely changed daemon holds PTY
  masters and keeps reading them, so the app can crash or be rebuilt without killing shells. It
  has a minimal versioned protocol and never auto-restarts. Worth it for Axolotty's own dev loop
  once sessions matter. Reverse lesson: if the custodian holds the fd but nobody reads it, the
  kernel buffer fills and the child blocks.
- Pre-ack wedge class: data racing ahead of the verdict that interprets it on the same stream →
  stage the data until the verdict is adopted (`knowledge-from-slop-desk.md` §4).

### 4.4 Never do again
1. **Multi-lane agent swarms in one checkout** with an orchestrator, staging, a review cycle,
   lock-owner hand-offs and per-lane warm dirs. They were model-bound (56–64% generation) and
   review cycles took 69–117 min. Use one agent at a time on a small codebase, or worktrees with
   a cheap build.
2. **Many target triples in the dev loop** (macOS, iOS, iOS-sim, Linux, plus clippy for each) and
   lint pedantry on all of them. One triple.
3. **Building heavy native deps from source in the loop** (ghostty's Zig at 126 s, Luau at 67 s,
   inside every cold build). Use prebuilt, checksum-pinned binaries.
4. **Forking the UI framework** (gpui-fast, gpui-kit, zed) and chasing upstream syncs. Dozens of
   `tooling.md` entries are sync logs. AppKit is the platform; don't fork it.
5. **e2e as the main proof, and full-window PNG goldens.** 31-min rounds, permanently red, and
   golden churn across hundreds of files.
6. **CI or infrastructure as a product:** a gate branch with promotion, warm runners, tart
   guests, office Macs and hosted simulators, rebuilt every week, plus 33.8k lines of xtask. A
   push-to-main p90 of 64 min.
7. **Wall-clock assertions and retries.**
8. **Nightly checks without canaries**, and any always-red job (delete or fix it).
9. **Unbounded docs:** a 19k-line MEASUREMENTS, a 14.8k-line `ui.md`, and 51k lines of
   decisions, too large to read, so every agent turn re-reads them (63% of file reads were
   re-reads).
10. **Big product pivots after building:** GUI-first → TUI-first, observed → driven → TUI-first
    agents, canvas → tiling, zeron's chat layout → terminal layout. Decide the product shape
    (TUI-first, terminal-owns-window) **before** building UI.
11. **Scope creep:** Parsec-class remote video, iOS, Linux workers, a tailnet, QUIC tuning and an
    audio pipeline, all before the local terminal was done. Axolotty: a local macOS terminal
    first.
12. **Coverage as the strength metric.** Coverage held a Mac for over an hour a night. The
    mutation score of pure modules is the meaningful one, and only weekly.

---

## 5. Conventions worth keeping

- **Commits:** Conventional Commits with a module scope and an imperative, outcome-phrased
  subject: `fix(engine): keep the scrollback past 10 KB`, `perf(e2e): hold the simulator still
  while its build downloads`. Lint the message (`committed`). One concern per commit (a
  checkpoint was capped at about 1,000 changed lines with frozen scope). A change that moves the
  lockfile or deps goes first, alone.
- **Hard lines in CLAUDE.md, short:** slopty's CLAUDE.md is 33 lines (product statement plus 5
  hard rules) and points to the maps. Keep that shape.
- **Pre-release: no backward compatibility, no versioning.** Replace cleanly and delete the old.
- **Lints never loosened.** Every suppression needs a reason (`#[expect(..., reason = "…")]` →
  `// swiftlint:disable:next <rule> - <reason>`).
- **Decision records:** one file per topic under `docs/decisions/`, with an index in
  `docs/DECISIONS.md`. An entry is `- ✅ **Bold one-sentence ruling** (YYYY-MM-DD)` followed by
  why, the evidence (verified against a primary source: header, upstream commit, own
  measurement) and the rejected alternatives. Statuses: ✅ decided, 🔬 measure before relying,
  ⏸ deferred, ❌ superseded (with a pointer to its successor). Cite by bold title. Inherited
  claims are untrusted until re-verified. **Add a cap:** one screen per entry, and archive
  superseded entries out of the main file.
- **Same-change rule:** a decision worth a paragraph goes into `docs/decisions/` and an
  optimisation's number into `docs/MEASUREMENTS.md` **in the same commit**. Every measurement
  states date, hardware, build profile, the exact command, and before/after. **Add a cap:** one
  file per month, or prune to the latest number per metric.
- **Docs paraphrase the person, never quote them.** Plain declarative sentences that name the
  file and symbol.
- **Test names are sentences of behaviour**; a test file's header comment states the relations
  or invariants it holds (see `fuzz/src/terminal.rs`, `crates/slopty-agent/tests/metamorphic.rs`).
- **Agent operating rules** (from the HANDOFF and lanes skill, still good for one agent): run
  long checks in the background and read verdict lines, not whole logs; batch reads; read big
  files by outline first; never poll or sleep-wait; never edit source while a check runs on it.
