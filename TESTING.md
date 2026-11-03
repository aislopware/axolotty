# Testing

`swift test` is the gate, with `cargo test --manifest-path Rust/axquic/Cargo.toml`
for the QUIC link (two seconds). It runs on any Mac in about a minute and needs no
network, no second machine and no GUI session. A test that needs one of those
is gated on an environment variable and never runs in the gate.

The real network only measures. It can't hold anything: its loss, jitter and
Wi-Fi rate move from run to run, so a bound checked on it is a coin toss. What
it measured becomes a model, and the gate holds the model in virtual time.

## The rules

- **A flake is a failure.** A test that passes on a retry has shown a bug,
  in the code or in the test. Hunt flakes with
  `swift test --filter <suite> --maximum-repetitions 50 --repeat-until fail`
  (SwiftPM 6.4).
- **Wait on events, never on the clock.** A socket test waits for what it
  means (`until { relay.accepted >= 2 && c.isConnected }`), with a generous
  deadline that only stops a hang. It never sleeps and then asserts. Timing
  rules are held exactly in virtual time instead (see "Pure doors").
- **Every check proves it can fail.** A bound that holds for the fix is
  shown, in the same run, to fail for the arm without it. Examples:
  - `withoutTheFixTheEchoQueues` runs the unpaced and FIFO send paths;
  - `DoorTests` has its own canary;
  - the fuzzer's length nudges were added because a planted off-by-four went
    unseen.

  A check that cannot fail tells nothing.
- **Bounds are relative.** A latency bound is "within 6 ms of the idle link
  on the same model", not "under 12 ms". It then says what the code adds,
  not what the path costs.
- **Seeds name failures.** Every randomised test is seeded (`SimRNG`,
  xorshift64\*). A failure prints its seed, and `AXSEED=<n>` replays it
  exactly. A seed's run is a pure function of the seed: `aSeedRepeatsItsRun`
  compares two runs' digests.
- **Nothing runs unwatched.** A long run that hangs is the worst kind of
  silent: it says nothing until someone looks. Every `scripts/deep.sh` step
  runs under `scripts/watchdog.sh`, after Slopty's xtask watchdog. If no
  output comes for a bound, or the run passes its total, it lists the
  processes under the run, samples each leaf's stacks into the log, and
  ends every process under it with exit 124. Long tests print a progress
  line (`progress(_:)`), so a quiet run is a stuck one. SwiftPM holds a test
  process's output until it exits, so the line also goes straight into the
  watchdog's log (`$AXWATCH_LOG`). Without that, the long sim step looked
  silent for minutes and was ended twice; so did thirty repetitions of a
  four-second test, which is why each faulty-link test reports its end;
  so did the QUIC loss test, which sweeps 200 seeds and now prints one.
  Suites that spawn carry
  `.timeLimit`. One SwiftPM at a time on `.build`: a second one waits
  silently on the first one's lock.
- **The gate is small; long runs widen it.** The same tests take a bigger
  budget from the environment (see "Knobs"). A failure a long run finds
  becomes a named test or a fixed seed in the gate.

## The layers

| Layer | What it holds | Where |
|---|---|---|
| Pure doors | Scheduling, pacing, liveness, redial and echo-prediction rules, to the millisecond | `SendLanesModelTests`, `LinkLivenessTests`, `RemoteLinkTests.redialsClimbSloptysLadder`, `EchoPredictorTests`, `DoorTests` |
| Simulated link | Echo latency beside a flood, rate drops, loss, all in virtual time over a TCP model | `LinkSimTests`, `AxTestSupport/LinkSim.swift` |
| Simulated QUIC | The real QUIC link (noq, its patches, `Link`) on Slopty's in-memory network in tokio's paused time: an echo beside twelve flooding panes, the drain after Ctrl-C, loss and reordering, a blackout ridden out and one that ends the link, a seed that repeats its run | `Rust/axquic/tests/sim.rs`, `tests/shape` |
| Model-based | `SendLanes` against a reference model over random op sequences, shrunk; echo prediction against a simulated shell across a delayed link | `SendLanesModelTests`, `EchoPredictorTests` |
| Fuzzing | A peer's bytes, structure-aware, against invariants | `WireFuzzTests` |
| Metamorphic | The terminal engine over Ghostty's fuzz corpus: chunked feed equals one feed; a snapshot restores; snapshot mid-stream then continue equals uninterrupted | `AxVTTests/Relations.swift` |
| Differential | The mirror shows what the host's terminal shows; a mirror never answers queries the host answers | `FaultyLinkTests.mirrorsTheHost`, `Relations.Replies` |
| Faults on real sockets | Blackout, reset and delay on loopback through `LinkRelay`; every line arrives once, in order | `FaultyLinkTests` |
| Crash and recovery | The PTY holder outlives the server, a fresh holder adopts live sessions, concurrent launches leave one | `HolderTests` |
| Pixels | The Metal renderer drawn offscreen and read back | `RenderTests` |
| Sanitizers | Data races and memory errors across the whole suite | `swift test --sanitize=thread` / `=address` |
| Measurement | The real tailnet, Studio to MacBook | `EchoBench` (`AXBENCH=1`), `.research/slopty-latency-2026-11-02.md` |

### Pure doors

Logic that decides anything about time takes time as an argument: a
`Duration` since some epoch. `SendLanes`, `BulkPacer`, `LinkLiveness`,
`HostConnection.redialDelay` and the frame codec read no clock and do no I/O.
`DoorTests` reads their sources and fails on a clock read, a sleep or a
syscall. The shells around them (`FramedConnection`, `HostConnection`) read
the clock once and pass it in.

So a six-second silence is tested as `liveness.state(at: .seconds(6))`, in no
time and exactly. It doesn't need a six-second test that passes when the
machine is idle.

Swift has no supported way to virtualise the global executor. A test clock
(swift-clocks' `TestClock`) only reaches code that takes a clock as a
parameter. Taking time as a value is the same move without the dependency.

### The simulated link

`LinkSim` is a discrete-event simulation in virtual time. It runs the real
`SendLanes` and `BulkPacer` writing into a TCP model, over a seeded shaper.

The TCP model has:
- slow start and AIMD;
- SACK and RACK loss detection;
- tail-loss probes;
- an RTO with backoff;
- a send buffer;
- `TCP_NOTSENT_LOWAT`.

The shaper has delay, jitter that never reorders, random loss, a rate that
can change mid-run, and a drop-tail queue.

Seconds of traffic run in milliseconds. The link it models was measured on
the real tailnet: 50 Mbit/s, 4 ms each way, 100 ms of router buffer.
`AXSIM_REPORT=1` prints every send policy on every link. `AXSIM_TRACE=1`
traces one run's events.

### The simulated QUIC link

`tests/shape` is Slopty's `slopty-shape`: a seeded shaper (delay, jitter that
never reorders, loss, rate, a drop-tail queue) and an in-memory network that
noq's endpoints sit on as their socket. Under `#[tokio::test(start_paused)]`,
tokio's clock jumps to the next packet or timer whenever every task waits, and
noq reads that clock. So the whole stack runs in virtual time: the patched
noq, BBR3 with its bound, and Axolotty's `Link` with its lanes and priorities.
A minute's blackout passes in milliseconds, and a seed repeats its run to the
packet.

It found two things the real network couldn't show:
- an echo stalled 100–450 ms beside a flood, with nothing lost, because noq's
  send window was full (noq-proto patch 23);
- 2.7 s of output still on its way after Ctrl-C, from noq's 10 MB send buffer
  (`SendWindow` now fits it to the congestion window).

### Faults on real sockets

`LinkRelay` is a small Toxiproxy in the test process. The client dials it
over TCP, so `HostConnection` treats the link as remote and runs liveness and
redial. The relay splices each connection to the host's Unix socket. It can:
- black out, holding bytes the way TCP does and refusing new dials;
- cut, resetting every connection with an RST via `SO_LINGER` 0;
- add delay.

The program under test waits on `read go` until the test's tap is in place,
so no output races the test.

Toxiproxy itself (v2.13, darwin-arm64) speaks TCP only and is a second
process with an HTTP control plane. The in-process relay reaches the Unix
socket and needs neither. pf and dummynet need root.

## Knobs

| Variable | Default (gate) | Long run | Effect |
|---|---|---|---|
| `AXSEED` | — | — | Replay one seed of a seeded test |
| `AXSIM_SEEDS` | 4 | 200 | Seeds per simulated-link test |
| `AXSIM_REPORT` | off | 1 | Print every policy on every link |
| `AXSIM_TRACE` | off | 1 | Trace a simulated run's events |
| `AXQSIM_SEEDS` | seed 11 (loss: 1–10) | 200 | Seeds the simulated QUIC echo and loss tests sweep |
| `AXQSIM_REPORT` | off | 1 | Print each seed's echo times without asserting |
| `AXFUZZ_RUNS` | 2000 | 200000 | Mutated streams per fuzz test |
| `AXMODEL_RUNS` | 300 | 20000 | Op sequences per model-based test |
| `AXREAP_RUNS` | 200 | 6000 | Programs the holder must reap in `everyEndedProgramIsReaped` |
| `AXFUZZ_TRACE` | off | 1 | Print each seed as it starts, to name the one that traps |
| `AXBENCH` | off | 1 | Run `EchoBench` against a real host (`AXBENCH_TCP=host:port`, `AXBENCH_CMD`, `AXBENCH_KEYS`) |

`scripts/deep.sh` runs the long set:
- the canaries first: a planted data race, heap overflow and third-run flake
  (`CanaryTests`, on only with `AXCANARY`), each of which its step must
  report by name. A sanitizer that stopped reporting, or a repeat flag that
  stopped repeating, would otherwise pass every step after it;
- the suite under TSan and under ASan;
- the socket suites repeated until a failure;
- the simulations (TCP and QUIC) and the fuzzer at their long budgets.

It tests HEAD in a worktree of its own (`$TMPDIR/axolotty-deep`, with its
own `.build`). Work in progress can't break a half-hour run by failing to
compile under it, and builds here don't queue behind its lock. Commit
before running it.

## What the long runs found

The gate's budgets passed every time. Each of these bugs showed up only under
repetition, a wider budget or a watchdog. Each is now a named test, and
where it could be shown, that test failed before the fix.

| Found by | Bug | Held by |
|---|---|---|
| `--repeat-until fail` on the socket suites | A command's stderr was read once more after its pipe closed, so a failed ssh reported another file's bytes, and the read could steal from a live socket | `RemoteLinkTests.stderrIsNeverReadPastItsEnd` |
| A one-off in a full parallel run | Any failure to lock `d.lock` (no descriptors, no permission) was reported as another server, and `axolottyd` exited 0 | `HostTests.aSecondServerIsRefusedAndOtherLockFailuresSayWhy` |
| `AXSIM_SEEDS=200` | The simulated client resent a lost key only once, so two seeds in 200 lost a key outright: a flaw in the model, not the app, and fatal to what the model is for | `LinkSimTests`, with failing seeds named |
| A repeat run, hung 12 minutes, then the watchdog's stacks | A command that exited before its dispatch process source was registered was never seen to end: `finish()` waited forever beside a zombie, so a link whose ssh failed at once never redialled | `RemoteLinkTests.aCommandThatExitsAtOnceIsSeenToEnd` (the suite's time limit) |
| Repeated host suites, then a probe | Foundation's `Process` carries every open description, close-on-exec ones included, until its exec. 71 of 20 000 lock attempts were refused beside a spawn loop, so a restarting `axolottyd` that met the old server's last spawn took itself for a twin | `HostTests.aLockHeldForAnInstantIsWaitedOut` |
| The ASan step, hung 30 minutes | ASan's fork handler (`asan_mz_force_lock`) deadlocks against other threads' `malloc` on Darwin. The in-process `fork` tests now run alone under ASan. `ptyd`, which forks for real, has one thread | `scripts/deep.sh asan` |
| Repeated host suites | A process-directed SIGPIPE (in XNU, a write into a pipe whose reader is gone) killed the test process. The writer is not found yet. The app now ignores SIGPIPE, as the daemons do, and a test run logs `AXTEST SIGPIPE`, with every pipe write end open at that moment and the broken ones starred, which fails its deep step. XNU raises EPIPE as a process-wide signal only for descriptors that aren't sockets, and every socket here sets `SO_NOSIGPIPE`, so the writer is a pipe | Open |
| A repeat run's `outputSurvivesServerDisconnectAndReattach`, then a probe | XNU can post `NOTE_EXIT` a moment before the child is waitable (1 to 4 exits in 5000 with twelve probes running). `ptyd` reaped with `WNOHANG`, so that program stayed a zombie for good. The old holder left 4 of 6000 under load | `HolderTests.everyEndedProgramIsReaped` |
| A planted off-by-four in the frame check | The fuzzer's random bytes never landed a length a few bytes off a frame's real one | `WireFuzzTests.mutate`, case 7 |

## What the general playbook leaves out

`modern-testing-beyond-pyramid` names nine procedures: fuzz, property,
mutation, contract, golden, simulation, chaos, metamorphic and shadow. They
are the right ones, but for a remote terminal they leave out:

- **Concurrency.** The bugs that matter here are races between the send
  path, liveness and redial. The sanitizers run the whole suite. TSan's
  report alone doesn't fail a test (the helper dies on signal 6 after the
  "passed" line), so check the exit code.
- **Stateful models.** Property tests over single values miss bugs that need
  a sequence: push, write half a frame, push control. `SendLanesModelTests`
  drives op sequences against a model and shrinks a failure to its fewest
  ops.
- **Differential checks across the wire.** The oracle for a mirror is the
  host's own terminal fed the same bytes. It is cheaper and stronger than
  golden screens.
- **Virtual time.** Without it, simulation and chaos degrade into
  wall-clock tests on a loaded machine.
- **Canaries.** Mutation testing proves a suite can fail. The playbook never
  says to prove each new check can fail when it is written.
- **Crash and recovery.** A terminal's sessions must outlive the process
  that drew them. That is a property of its own, not a chaos experiment.
- **A flake policy.** Retries that turn red into green hide exactly the
  timing bugs a remote-first app has.
- **Budgets as counts.** On a shared Mac, wall time is not a pass or fail.
  Bound what the code does (bytes queued, frames sent, allocations), and
  leave times to measurement.

## Tooling, as of Swift 6.4.2 (Xcode 27.2)

| Tool | State here | Use |
|---|---|---|
| `swift test --sanitize=thread,address,undefined` | Works | `scripts/deep.sh` |
| `--maximum-repetitions` / `--repeat-until` | Works (SwiftPM 6.4) | Flake hunts |
| libFuzzer (`-sanitize=fuzzer`) | Not in Xcode's toolchain; the swift.org 6.4.2 toolchain has it | Coverage-guided fuzzing of `FrameDecoder` and the VT parser, when needed |
| swift-property-based 2.0.1 | Works; shrinks; no stateful API | Not needed yet: our own `SimRNG` plus `shrink` covers it |
| Exhaust 1.9 | Needs Swift 6.4; stateful specs, deterministic `await` interleaving | The candidate if actor interleavings need exploring |
| Muter | Last release 2023; master mis-scores Swift Testing | Not usable; canaries stand in |
| swift-snapshot-testing 1.19.7 | Works for NSView | Not for `CAMetalLayer`; the renderer is read back offscreen instead |
| ordo-one/benchmark 1.38 | Works; p99 thresholds against a baseline | Allocation and throughput budgets, when they are added |
