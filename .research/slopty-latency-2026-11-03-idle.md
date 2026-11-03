# Where an idle Mac's echo time goes (2026-11-03)

This is measured with release `EchoBench`: a unix socket on one Mac, 300 keys 25 ms apart, and `cat -u` in raw mode. The bench now waits on the echo itself. Before, it slept in 100 µs polls, which are timers an idle Mac may coalesce.

| | p50 | p99 |
|---|---|---|
| Idle | 1.0–1.2 ms | 8–11 ms |
| Another pane flooding | 0.18 ms | 0.25 ms |
| A bare PTY with `cat`, no Axolotty | 0.15 ms | 2–5 ms |

The same bench at the Stage A commit (1b89dd3), run the same afternoon, gave 1.00 / 8.0 ms. That rules out a regression. The 0.68 ms in Stage A came from a different moment of the same Mac.

**Where the time goes.** Temporary timestamps at each hop, idle, show that each hop costs a thread's wake-up:

| Hop | p50 | p99 |
|---|---|---|
| Client write → server connection queue | 0.38 ms | 2.6–6 ms |
| → server actor | 0.16–0.24 ms | 1.7–7 ms |
| → pane queue | 0.03 ms | 0.6–2 ms |
| PTY and `cat` | 0.14 ms | 7–9 ms |
| → client | 0.13–0.16 ms | 1.9–2.7 ms |

Under load the cores stay awake and all of this shrinks to 0.18 ms.

**Tried, A/B interleaved, 3 runs each, and not kept.** Runs differ by about ±0.2 ms at p50, so a single run decides nothing.
- **The server actor on a user-interactive serial queue,** with isolated loops (one hop instead of two). Hop p50 was 0.21–0.24 ms against 0.16–0.18 ms on the default executor, and the total p50 was 1.0–1.2 ms against 0.66–0.94 ms. Slightly worse.
- **`FramedConnection.send` writing from the caller when nothing is queued** (one wake fewer each way). Total p50 was 0.90–1.14 ms. No gain.
- **A spin-poll window on the PTY after input** (the pane queue polls the master for up to 2 ms after writing a key, so the echo is read without a kernel wake). Three interleaved rounds, spin off against 2 ms: p50 0.71 / 1.07 / 1.11 ms against 0.87 / 1.10 / 1.10 ms; p99 11.2 / 9.5 / 9.3 ms against 7.8 / 10.2 / 14.6 ms; max 11–15 ms against 26–30 ms. No gain at p50, p99 mixed, and the worst echo twice as late: a pane queue spinning holds the core the shell needs to answer.

**Kept.**
- The bench's event-driven wait.
- A pane's read buffer allocated once (it was 64 KiB zeroed on every read). That is hygiene, not a measured millisecond.

What could still help has to remove wake-ups on both Macs together; spinning is ruled out above. Any such change must win an interleaved A/B before it lands. The remote echo is about 8 ms of network on the tailnet (ping p50 6, p99 14), and the idle hops add 1–2 ms on top.
