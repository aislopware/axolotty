# What Slopty measured about remote latency, and what Axolotty takes from it (2026-11-02)

Slopty (/Volumes/Lacie/Workspace/oss/slopty) is the owner's own remote-Mac app. The owner considers its performance work the ceiling and its Rust GUI its only weakness.

The references below point into its docs. These are short names for its files:
- **T:** `docs/decisions/transport.md`
- **TERM:** `docs/decisions/terminal.md`
- **PE:** `docs/decisions/prediction-editing.md`
- **TOP:** `docs/decisions/topology.md`
- **W:** `docs/decisions/workers.md`
- **M:** `docs/MEASUREMENTS.md`

## What Slopty settled

### Transport
- QUIC on a vendored, patched noq 1.4 with a null crypto provider: wire version `SLP1`, no TLS, no AEAD (T:876-881; `crates/slopty-net/src/crypto.rs`). The tailnet is the security boundary.
- Admission is a Tailscale whois before the handshake (TOP:538-553):
  - nodes of the same user get every role;
  - other users get a role only through an app-capability grant;
  - with no tailscaled to ask, it fails closed.

### What it never measured
- TCP against QUIC.
- TLS against null crypto, so how much removing the encryption saved on its own is unknown.
- DERP latency.

The move from iroh to plaintext noq took the LAN round trip from 1.2 to 0.55 ms. That same change also removed relays and multipath (M:3332-3340).

### Where the keystroke milliseconds came from
None of these are "no encryption":

| Fix | Effect |
|---|---|
| A sleep rounded up to tokio's next millisecond | echo 3.1–3.9 → 0.73 ms (M:2447-2486) |
| Drawing no frame on a key unless something new shows | echoed key-to-glass 32.9 → 22.3 ms; 19 ms of that is the macOS compositor (M:3643-3671, TERM:1297-1311) |
| An echo datagram copy 2 ms after the stream copy, plus a pacer patch | keys over 50 ms on the tailnet 13.5 % → 0.5 % (T:1167-1211). The cause was lone losses into the Wi-Fi Mac waiting for a PTO |
| `QOS_CLASS_USER_INTERACTIVE` on every keystroke thread | echo p99 under an all-core spin 11–569 → 0.7–11 ms (T:1279-1295). Never set a Mach latency tier: it drops the class |
| A connection loop that never awaits | echo p99 33 → 4.8 ms (T:963-964) |
| The echo lifted above six busy sessions | p99 30–73 → 11–25 ms (T:1297-1309) |
| An unpaced echo | p90 1.4–2.0 → 0.25 ms (T:1357-1370) |

### Tunings

| Knob | Value |
|---|---|
| Keep-alive | 1 s |
| Idle timeout | 45 s |
| ACK delay | 2 ms |
| Initial RTT | 5 ms |
| MTU | 1232, with no discovery |
| `SO_RCVBUF` | 4 MiB |
| Initial window | 32 packets |
| Congestion control | BBR3 capped at 2 × BDP |
| Stream window | 1.25 MB (4 MB hurt echo) |

### Liveness, in its third generation
- A ping every 2 s on the control stream.
- One missed ping shows the host as silent.
- 6 s without a pong relinks (T:2163-2167).
- Counting packets had shown links alive while their stream was stalled.

### Redial
- 250 ms, doubling to 2 s.
- After a minute, 4 s doubling to 30 s.
- ±20 % jitter (T:2175-2182).

### Measured numbers
- Tailnet Studio↔MacBook, direct, with ICMP 7–16 ms: idle echo p50 10.2 ms, p99 168 ms before the datagram copies (M:4549-4551).

### Predictive echo (TERM:1616-1908, PE)
When it predicts:
- only once the round trip is over half a display refresh;
- never on the alternate screen, at a password prompt, with the cursor hidden, or under mouse tracking;
- after a non-printable key, predictions are tentative until that key is acknowledged;
- ← → ⌫ are predicted inside the OSC 133 input, in mosh-style epochs.

How it draws:
- in the terminal's own style;
- faint and underlined only at a round trip of 80 ms or more, after a 250 ms wait, or after a miss;
- a miss shows for one round trip, then is cleared, and prediction mutes.

What it buys: keys look final at 21 ms instead of 35–42 ms.

### Reconnect UX
- Tiles dim and are never emptied.
- Relinks are make-before-break.
- Shells keep their view across a drop.
- A DERP notice ("Relayed via fra — adds latency") shows only after 10 s on a relay. Read `CurAddr`, not `Relay`, to tell direct from relayed.

### macOS pitfalls
- launchd jobs need `ProcessType Interactive`.
- Sockets must not live in `$TMPDIR`.
- The default `SO_RCVBUF` is too small.
- XNU dual-stack ephemeral ports can collide.
- `CAMetalLayer` shows a second frame inside one refresh a refresh late.

### Slopty's design that Axolotty does not share
Slopty ships rendered row diffs, not bytes. It rejected raw bytes plus a client-side VT for replay cost, iOS and slow links (TERM:5-7).

Axolotty's journal design answers those three:
- warm resume from an offset;
- libghostty-vt runs on iOS too;
- a client that lags past 2 MiB is resynced from a snapshot.

## What Axolotty does

**Stage A (now): TCP over the tailnet.** Bound to the tailnet addresses only, with:
- Nagle off, DSCP EF and keepalives;
- whois admission, same user only;
- the 2 s / 6 s liveness;
- Slopty's redial ladder;
- user-interactive QoS on the pane and connection queues.

Then measure key→echo against the MacBook (direct path) with and without load. That is the number Slopty never took for TCP.

**Stage B: QUIC with null crypto, if Stage A's tail is TCP's fault.** A lone loss waiting for an RTO/TLP is the failure Slopty fixed with echo datagram copies.
- A Rust staticlib with a C ABI around Slopty's patched noq, linked by SwiftPM. `slopty-net` itself has no C ABI and pulls in Slopty's own wire types.
- One stream per pane, so a busy pane never holds another's echo.
- Echo datagram copies.

It sits behind the same link interface as the Unix socket, so nothing above it changes.

**Applies to every link, local included:**
- draw no frame on a key unless the grid changed;
- user-interactive QoS on the keystroke path.

**Predictive echo** follows Slopty's rules above.

## Stage A, measured (2026-11-02)

The route was Mac Studio → MacBook over the tailnet, with ICMP at 8.6 ms (`tailscale status` later showed the MacBook via relay "dc-old"). Each figure is key to echo through `cat -u` in raw mode, release build, 300 keys 25 ms apart (`Tests/AxHostTests/EchoBench.swift`).

| Link | p50 | p90 | p99 |
|---|---|---|---|
| Unix socket, idle | 0.68 | 1.49 | 4.15 ms |
| TCP, idle | 9.2 | 10.7 | 19.9 ms |
| ssh bridge, idle | 9.5 | 11.0 | 18.4 ms |
| TCP + another pane flooding, one FIFO | 77.6 | 114.7 | 135.1 ms |
| … with a lane per pane | 29.3 | 46.3 | 65.0 ms |
| … with lanes and bulk pacing | **10.1** | **15.6** | **25.5 ms** |
| ssh bridge + flood | 66.0 | 83.0 | 98.9 ms |

What this shows:
- **Idle TCP costs about 0.6 ms over ICMP.** Encryption, the framing and TCP itself are not where the time goes.
- **The tail under load came from head-of-line blocking, at two levels.**
  - The connection had a single FIFO. Lanes fixed it, scheduling control first and then the least-queued lane; a lane per pane does the work of QUIC's stream per pane.
  - The path's buffers. Delay-based pacing of bulk lanes fixed them: the cap shrinks when the RTT rises over its floor, after LEDBAT. The flood's throughput was the same with pacing and without it (6.0–6.4 MB/s). Without pacing, 16 of 200 keys took over 2 s.
- **ssh can't be fixed from our side.** Its own buffers sit between the lanes and the wire.

The verdict on Stage B: QUIC with null crypto is not needed for what was measured. What it would still buy:
- recovery from a lone loss without waiting for TCP's RTO or TLP. Slopty's echo datagram copies target exactly that, and it is the likely source of the remaining p99;
- a connection that survives an address change.

Revisit Stage B if p99 on a lossy Wi-Fi path matters after predictive echo lands.
