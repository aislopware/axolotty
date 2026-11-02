# Axolotty: client–server architecture (research + recommendation)

2026-11-02 · proposal, nothing built yet. The process model, terminal-state sync, wire protocol, transport/auth and module layout for an agent-first terminal where **one client talks to many servers and many clients share one server**. The macOS app is a client and a local host; the iOS app is a client only. Swift 6.4 + C, libghostty-vt `ae0dc1b7`.

Citations: `sd:` = `/Volumes/Lacie/Workspace/oss/slop-desk/docs/`, `sl:` = `/Volumes/Lacie/Workspace/oss/slopty/`,
`vt:` = `Vendor/GhosttyVT.xcframework/macos-arm64/Headers/ghostty/vt/`. External URLs are in §13.

---

## 0. Decisions in one screen

| # | Decision | Why (short) |
|---|---|---|
| D1 | **Three processes, three layers**: `axolotty-ptyd` (holds PTYs + children, nothing else) ← `axolottyd` (terminal state, agent status, sync, listeners) ← clients (mac/iOS). `axolottyd` is an SMAppService LaunchAgent. ptyd is a `setsid` orphan started by `axolottyd` from a version-named copy outside the app bundle (iTerm2's pattern), so no launchd job or bundle replacement owns it. | An app or server update must never kill a shell. slop-desk (`superd`) and slopty (`slopty-ptyd`) both converged here; the holder parses no terminal output, so it almost never changes and almost never crashes. |
| D2 | **One holder for all sessions**, written in C (~1.5k LOC, one kqueue thread). It **passes the master fd** to the server (SCM_RIGHTS); the server reads it directly. No byte relay on the hot path. | Same as iTerm2's multiserver, slopty, shpool, tmux. Per-session holders (dtach/old iTerm2) buy isolation the holder doesn't need, because it never interprets bytes. |
| D3 | **Durable per-session journal**: a shared-memory ring (owned by ptyd, written by whoever reads the master) with **absolute u64 offsets**, plus **libghostty snapshots as checkpoints** on disk. A server restart = checkpoint + replay of the ring tail. Offsets survive restarts, so clients resume byte-exactly. | slopty's checkpoint+tap rule (`sl:docs/decisions/workers.md:101`), but with ghostty's exact snapshot (continuation included) instead of a hand-corrected formatter dump, and with a zero-syscall ring instead of a socket tap. |
| D4 | **Terminal sync = hybrid**. Relay raw VT bytes into a **client-side libghostty-vt mirror** while the client keeps up. A late joiner, a laggard, or a resume past the ring gets a **`ghostty_snapshot` at offset N**, then bytes from N. | `snapshot.h` was built for exactly this: READY first, history streamed after, and "the terminal may be rendered, resized, and fed live PTY input between calls". Full fidelity: scrollback, search, selection, kitty images and OSC 8 work locally with no cell protocol. |
| D5 | **Only the server terminal talks back to the PTY.** Client mirrors run with `WRITE_PTY = NULL` and every effect callback off. Query replies, OSC 52, notifications and status come from the server once. | This kills slop-desk's worst bug class (replayed `?2048h`/mouse modes injected garbage into shells, `sd:decisions/vol-01.md` "Replay hygiene") and "N clients answer `CSI 6n` N times" (`sd:decisions/vol-14.md:298`). |
| D6 | **Input is semantic and encoded on the server** (ghostty key/mouse/paste encoders against the authoritative modes). Clients send key events (with layout-translated text), mouse in cell+pixel coords, and paste text. | The latency is the same as sending bytes. It removes mode races (DECCKM, kitty keyboard flags, mouse modes changing in flight), and two clients with different modes can never disagree. |
| D7 | **PTY size: one "driver" client per pane**, plus explicit **Take** ("Fit to this device"). iOS is passive by default. A single `TIOCSWINSZ` writer. Non-drivers fit or letterbox with a label. `smallest` is an optional server policy. | slopty's driver model survived pair testing. slop-desk's min-fold had several fixed-point bugs (`sd:45:1702-1774`), and tmux `latest` flaps across devices. |
| D8 | **Workspace document is host-truth** (workspaces, split trees, panes, sessions, agent status, attention epochs). View state is device-local; presence is ephemeral. Sync uses mosh-SSP-style **snapshot/diff from the acked revision** and **intents** with client-proposed UUIDs. Last writer wins per field at one actor. No CRDT. | This is the part of slop-desk's doc 45 that worked (`sd:decisions/vol-04.md`), minus the parts it had to retract. |
| D9 | **One protocol over any reliable byte stream**: unix socket (local), TLS 1.3/TCP (remote v1), QUIC (remote v2, one stream per pane), `ssh host axolottyd --stdio` (power users). Fixed binary envelope; **Protobuf for control messages, raw frames for bytes**. Versions are negotiated in Hello. | slop-desk's "no negotiation, both-ends constants" caused permanent stalls on version skew (`sd:31-…HANDOFF.md:33`). The iOS (App Store) and Mac (Sparkle) release trains skew by design. |
| D10 | **App-layer security on every non-local link**: mutual TLS with pinned self-signed device keys, paired by a QR code or link (128-bit one-time token), with TOFU + SAS as the fallback. No TLS-PSK, which Network framework limits to TLS ≤1.2 and no QUIC. CryptoKit has no PAKE. Local access = same-uid check on a 0700 socket directory. | A terminal server is remote code execution. Unlike slop-desk/slopty ("rely on the WireGuard mesh") we support Bonjour on a LAN, so the network can't be the boundary. |
| D11 | **Swift everywhere except ptyd and hot C shims**. One `AxProto` module is shared by server, macOS client, iOS client and CLI. | slop-desk's Swift⇄Rust drift and golden-vector maintenance (`sd:decisions/vol-07.md:855-874`). Same-language drift still happens, so we keep per-release wire fixtures. |

---

## 1. What the prior art teaches

### 1.1 slop-desk (host daemon + mac/iOS clients; ~9k lines of design docs on this exact problem)

**Worked (keep):**
- **A dedicated PTY custodian** (`superd`, a LaunchAgent with KeepAlive) that dup-passes master fds to hostd. "If hostd crashes … nothing is lost", and a restart took ~0.2 s with an unchanged child count (`sd:51-process-supervision.md:157-164, 902-904`).
- **The custodian must keep draining.** Otherwise "the pane … spends the whole restart frozen" because the kernel PTY buffer is a few KB. The fix was a ring addressed by **absolute offsets since the pane was born**, with eviction "announced, never silent" (`sd:51:266-283`).
- **State transfer beats replay.** Cold reattach went from replaying seconds of history to "render the screen model once" (`sd:decisions/vol-03.md`, 2026-07-25). Up to 64 MiB of overnight agent churn was the bulk of the pain.
- **The multi-client ownership test**: "would two people … disagree about a fact, or about a view?" Facts are host-truth, views are device-local, presence is TTL-ed. Diffs go from the **acked** base; depth-1 coalescing; an `epoch` UUID per daemon start; client-proposed ids; "assigned, never toggled"; LWW per `(kind, id, field)` (`sd:decisions/vol-04.md`).
- **Laggards are evicted rather than allowed to stall a pane.** This is affordable only because a cold reattach costs one screen (`sd:decisions/vol-04.md` §5).

**Failed or painful (avoid):**
- **Client-side replay executed history.** nvim's `?2048h`/kitty/mouse modes were re-armed in a fresh client mid-replay, and the client's replies went to the shell as `zsh: command not found: 18M65` (`sd:decisions/vol-01.md`, 2026-07-13). The fix grew into five stream "strippers" plus a hand-written screen model. *Root cause: a client terminal was allowed to write to the PTY, and state was transferred as history.*
- **The host ran a different VT model than the clients** (a Rust `screend` vs libghostty), so snapshots were lossy: OSC 133 marks were dropped and "every jump silently landed nowhere" (`sd:20-wire-protocol.md:691-697`).
- **Credit-window flow control** produced three separate permanent wedges: the pre-ack wedge "15 wedged / 20" (`sd:72:232`), a 13-byte header dead zone (`slopdesk-wire/src/mux/flow.rs:146`), and both-ends window constants with no negotiation, where "old client + new host = permanent channel stall" (`sd:31…HANDOFF.md:33`).
- **No version negotiation** ("accepts only protocolVersion == 1", `sd:20:112`), and prose and code drifting on constants (`sd:20:545`).
- **Four copies of the PTY bytes** in two processes (`sd:59-hostd-projection.md:25-38`), and four `TIOCSWINSZ` writers (`sd:45:1661`).
- **Resize fixed points.** With only an iPhone attached, the shell stayed at 80×24 "for its whole life" (`sd:45:1702-1774`).
- **Many servers per client was never designed**: "two documents … must compose them itself" (`sd:45:1857`).
- **No app-layer auth**: "the client label … is a LABEL, not a credential" (`sd:decisions/vol-04.md` §1).

### 1.2 slopty (Rust/GPUI successor; workers + clients over QUIC)

- **`slopty-ptyd` is a model PTY holder.** It spawns with setsid and a controlling tty, keeps the master, drains into a bounded ring while no worker holds it, and on `Attach` "ships the ring contents plus the master over SCM_RIGHTS, and the worker reads the fd directly … no relay hop" (`sl:docs/ARCHITECTURE.md` "PTY custody").
- **Crash survival = checkpoint + tap.** The worker sends ptyd a copy of each read and a `Checkpoint` after 500 ms of quiet or every 1 MiB, so a restart replays one checkpoint plus at most 1 MiB (`sl:docs/decisions/workers.md:101-118`). The checkpoint was ghostty's *formatter* VT output plus a page of hand corrections: the alt screen, the mode reset, blank rows, cursor-after-DECSTBM, and "a pending wrap … is lost". We get all of that for free from `ghostty_snapshot_*`.
- **Two races from tapping on a second connection** ("a dying host's buffered taps … landing after its master connection's EOF"), fixed by using one connection (`workers.md:114-118`).
- **Upgrades**: keep ptyd when its **custody fingerprint** (a hash of protocol goldens and shell scripts) is unchanged. Otherwise do in-place `execv` "succession" with masters kept open and state in an unlinked file. Only if the succession format itself changed is the user asked "Updating ends N sessions" (`workers.md:931-960`). New binaries are **renamed over, never written in place**, because writing in place "kills a running signed Mach-O" (`workers.md:947`).
- **Dual custody**: the worker keeps its dup of each master. A *fresh* ptyd gets it back via `Adopt` and watches the child by pid and start time (`sl:crates/slopty-pty/src/protocol.rs:128-145`).
- **Server-side VT with row diffs.** "The client needs no VT engine at all. iOS never builds Zig." The cost was a custom row/cell/link/image protocol, a line cache, symbolic colours, absolute line indices, prediction, and a vendored QUIC stack with BBR patches. We take the opposite trade (§5.1) because libghostty-vt already builds for iOS here (`ios-arm64` slices exist).
- **Multi-client rulings worth copying** (`sl:docs/decisions/multi-client.md`): input is serialised by the session actor and no client "holds" the keyboard; the size **driver** plus a "take" pill; "latest input drives" was rejected twice ("a phone would keep resizing the desktop's terminal"); a dying connection detaches only its own sinks; a permission answer is client-local until the host's next word.

### 1.3 External prior art (details and URLs in §13)

| Project | Model | Take / reject |
|---|---|---|
| tmux | One server per socket holds every PTY. It **re-renders per client** (`tty_write()` loops over clients; "a scene is built for the client and cached"). `PROTOCOL_VERSION 8` must match exactly. `window-size latest` (default)\|largest\|smallest\|manual. Control mode: `%output` carries the raw pane bytes; `pause-after=N` gives `%pause` / `%extended-output` / `%continue`, and "it is up to the client to update the content … e.g. capture-pane". | **Take** control mode's "pause and resync, never stall the pane" (§5.3). **Reject** the exact version lock. |
| zellij | One server process per session. Protobuf with a u32 LE length prefix. Server-rendered frames. The socket lives under `contract_version_1/`. A tab is sized to the **min of the clients viewing it**; unviewed tabs keep their size; "not configurable". `mirror_session=false` gives each user their own cursor. | **Take** per-viewer, device-local focus. **Reject** smallest-wins as the default. |
| mosh SSP | `current_state.diff_from(assumed_receiver_state)`; idempotent instructions; send interval `ceil(SRTT/2)` clamped to 20–250 ms; 8 ms collection; underlined predictions; no scrollback. | **Take** diff-from-acked-base (document) and "skip intermediate states" for laggards. Prediction is phase 3. |
| Eternal Terminal | TCP with a BackedWriter resend buffer (≤ 64 MiB); reconnect exchanges the last received sequence number, then a `CatchupBuffer`. Byte passthrough, so `-CC` works. | **Take** byte-exact resume while the offset is buffered (§7.3). |
| WezTerm mux | unix/ssh/tls domains. Leb128 frames, varbincode, zstd above 32 bytes. Server sends dirty-line ranges + seqno, and the client pulls `GetLines`. `CODEC_VERSION` must match exactly. Local echo when RTT ≥ 100 ms. | **Reject** exact-version coupling and the cell protocol. **Take** the "predict only when RTT ≥ threshold" gate. |
| Zed / VS Code | A version-locked server auto-uploaded over SSH. Zed: protobuf `Envelope` with a u32 LE length, a proxy that reconnects to a daemon. | **Take** `axolottyd --stdio` behind SSH. We **can't** version-lock: the iOS app updates on Apple's schedule. |
| **cmux** | v2 JSON socket API and `cmux notify`. `cmux ssh` uploads a SHA-pinned `cmuxd-remote` and runs `serve --stdio`. Sizing is "the process that owns the PTY decides", default `smallest`. Its old Go daemon did "raw-byte scrollback replay (1 MiB cap) [that] can begin mid-escape-sequence and corrupt the client grid". The **new cmux-tui daemon** uses versioned binary frames (4 lanes, per-lane replay cursors), Noise, a 120 s resume lease, then "clients resynchronize from terminal snapshots (ghostty-vt state)". | Independent confirmation of D4: relay + ghostty-snapshot resync. |
| **herdr** | A server owns panes; clients draw. Vendored libghostty-vt; bincode with `PROTOCOL_VERSION 22` plus a "stable endpoint generation" that tolerates version skew. Sizing: the last client to focus or interact with a tab. Status: process detection + **screen manifests** for idle/working/blocked, overridden by integration reports. `done` is a **per-client unseen** badge. | **Take** layered detection (§4.3) and per-device "seen". Its "latest" sizing is what slopty rejected. |
| **Rex** (Superlogical, Mitchell Hashimoto) | In public testing since 2026-10-05: "The macOS application self-hosts its own Rex server and it is able to connect to other Rex servers"; iOS/Linux/Windows clients; "scrollback, selection, and scrolling all work natively". Its protocol is unpublished. OSC 7501 was designed with it. | The closest prior art, and our closest competitor. Its shape matches D1/D4. Watch its protocol and libghostty API changes. |
| iTerm2 | `iTermServer` hands the master to the app over SCM_RIGHTS and keeps its own copy. 3.4: "Use a single daemon process for all sessions instead of one per session … reduces the number of process IDs … improves the time to launch a new session." It is fork+exec'd with `setsid`, "not daemonized". It runs from a version-named copy `iTermServer-<version>` in Application Support "where Autoupdate won't delete it". It **never reads the master** while the app is away (the child blocks), and the screen comes back from macOS window restoration, not from the server. | **Take** fd passing, one holder, setsid + an out-of-bundle versioned binary. **Reject** not draining. |
| dtach / abduco | One process per session; raw byte relay; "no terminal emulation layer"; redraw on attach via ^L or SIGWINCH; output with no client attached is read and dropped. | **Reject**: an extra hop, and the screen is lost. |
| shpool / zmx | shpool: one daemon for all shells, vt100 "screen" restore + SIGWINCH; a protocol mismatch means "restart your daemon", which kills the shells. zmx: one daemon per session, restores with the **libghostty-vt formatter**; "daemons and clients must be on the same version". | Confirms: keep VT state for reattach. No surveyed holder except slopty's upgrades without killing shells, which is why §3.5 exists. |
| tmate / upterm / sshx / Wave / Warp / zellij resurrection | Relay raw pane bytes (tmate, msgpack) or reverse SSH tunnels. Wave and Warp install a version-matched helper over SSH. zellij, kitty and Warp "restore" by re-running commands, not by keeping processes. | No new idea beyond the above. |

---

## 2. Shape

```
 iPhone/iPad (UIKit)          Mac B (AppKit)              Mac A (AppKit, hosts a server)
 ┌──────────────────┐        ┌──────────────────┐        ┌───────────────────────────────────────┐
 │ AxClientCore     │        │ AxClientCore     │        │ Axolotty.app  (client only)            │
 │  ServerLink × n ─┼─TLS/───┼─ ServerLink × n ─┼─TLS/───┼▶ AxClientCore ──UDS──┐                 │
 │  mirrors (vt)    │  QUIC  │  mirrors (vt)    │  QUIC  │  mirrors (vt)         │                 │
 │  AxRender(Metal) │        │  AxRender(Metal) │        │  AxRender(Metal)      ▼                 │
 └──────────────────┘        └──────────────────┘        │ ┌─────────────── axolottyd (LaunchAgent)┐│
        ▲ also connects to other servers (Mac B, Linux…) │ │ Listener: UDS · TLS · (QUIC) · stdio ││
                                                         │ │ ClientSession actor per connection   ││
                                                         │ │ DocumentActor (workspace truth)      ││
                                                         │ │ PaneActor per session:               ││
                                                         │ │   ghostty terminal (authoritative)   ││
                                                         │ │   reads master fd · writes journal   ││
                                                         │ │   key/mouse encoders · status detect ││
                                                         │ │ Checkpointer → sessions/<id>/*.ghsnap││
                                                         │ └──────▲───────────────────────────────┘│
                                                         │  custody socket (SCM_RIGHTS: master,    │
                                                         │        │          journal shm fds)      │
                                                         │ ┌──────┴── axolotty-ptyd (setsid orphan)┐│
                                                         │ │ spawn(setsid,TIOCSCTTY) · reap · hold ││
                                                         │ │ masters · own journal rings · drain   ││
                                                         │ │ when no server attached · never parses││
                                                         │ └──────┬───────────────────────────────┘│
                                                         │   shells / claude / codex (children)    │
                                                         └───────────────────────────────────────┘
```

The process tree on a Mac host:
- `launchd → axolotty-ptyd` (a setsid orphan, started by `axolottyd`) `→ {zsh, claude, …}`
- `launchd → axolottyd` (LaunchAgent)
- `launchd → Axolotty.app`
Killing, updating or crashing the app or `axolottyd` leaves every child running and its output drained.

---

## 3. Layer 1: the PTY holder `axolotty-ptyd`

### 3.1 Responsibilities, and the line it never crosses
The boundary rule, adopted from `sd:51:40-60`: *what is a running process allowed to depend on?*
ptyd owns exactly these:
- fork/exec/wait;
- master fds;
- each session's journal ring (shared memory);
- the child environment (`TERM`, `AXOLOTTY_PANE_ID`, `AXOLOTTY_SOCKET`, shell-integration `ZDOTDIR`).

It **never parses output**, never knows the terminal size beyond the kernel's own `TIOCGWINSZ`, has no TLS, and has no client protocol. "If a change seems to need a new verb, the change probably belongs in" the server (`sd:51:124`).

### 3.2 One holder vs one per session: **one**
- Per-session holders (dtach, abduco, zmx, pre-3.4 iTerm2) isolate crashes. But a holder that parses nothing has almost no crash surface.
  - iTerm2 left per-session servers for pid count and session launch time (3.4 release note).
  - tmux, shpool and slopty are single too.
  - One holder also means one socket, one lock and one succession, rather than N orphans to discover.
- The real crash isolation we need is **libghostty's parser out of the PTY-owning process**. libghostty-vt had a UAF advisory on 2026-10-27 (`.research/stack-2026-11-02.md` §3). D1 already provides that isolation.
- **Dual custody covers the holder's own crash.** `axolottyd` keeps its dup of every master. If ptyd dies (masters it held close, but the server's dup keeps the line open, so no SIGHUP), launchd restarts it and the server hands each session back with `Adopt`, as slopty does. Children re-parent to launchd, so ptyd watches them with `kqueue EVFILT_PROC NOTE_EXIT` and reports status `-1`.

### 3.2b How ptyd is launched (and why it is not a LaunchAgent)
- **Who starts it.** `axolottyd` starts it when ptyd's socket doesn't answer: fork+exec, `setsid()`, SIGHUP/SIGPIPE ignored, an advisory lock on `ptyd.lock` (iTerm2 does exactly this).
- **Which binary.** The binary is copied from the bundle to `~/Library/Application Support/Axolotty/bin/axolotty-ptyd-<custody-fp>` (content-addressed) and is replaced only by rename. Apple: modifying a signed file in place leaves a stale kernel signature cache and a "hard-to-reproduce code-signing crash"; write a temp file and replace it. Old copies are deleted only when no process runs them (`iTermServerDeleter`).
- **Why not a LaunchAgent.**
  - A Sparkle update replaces the bundle.
  - `SMAppService.unregister` or a re-register is documented only as "no longer launches it", and whether bootout reaps descendants is undocumented.
  - launchd kills "remaining processes with the same process group ID as the job" (`launchd.plist(5)`).
  - With ptyd outside any job and in its own session, none of those can reach it. **Spike S5 verifies this** on macOS 26/27: update, unregister, `launchctl kickstart -k`.
- **Keeping it alive.** A dead ptyd is relaunched by `axolottyd`, which then `Adopt`s the sessions back.

### 3.3 Journal ring (shared memory, absolute offsets)
- **Allocation.** Per session, ptyd creates an unlinked file in its 0700 runtime directory, sized to `ringBytes` (default 8 MiB; only touched pages cost RAM), and `mmap`s it. Header: `magic, version, capacity, journal_id (UUID), head:u64 (atomic), tail:u64`.
- **Records**: `[u32 len][u8 kind][payload]`, with `kind ∈ {output, resize(cols,rows,px), gap, exit}`. Offsets are absolute and monotone for the life of the session, so they are the **only sequence numbers in the system**. Server restarts don't reset them, and clients ack and resume in them.
- **Single writer.** Whoever holds the *reader role* appends: ptyd while detached, `axolottyd` while attached. The append happens **before** `ghostty_terminal_vt_write`, so a server crash loses at most the chunk being copied. The reader-role handoff is synchronous: ptyd removes the fd from its kqueue *before* answering `Attach`. When the custody connection drops, ptyd resumes draining. A server that loses its custody connection stops reading until it re-attaches, so there are never two readers.
- **Replay boundary.** The server owns the boundary between the checkpoint and the replay: each checkpoint records its offset. slop-desk's "printed twice" bug came from two processes sharing that number (`sd:51:446`).

### 3.4 Custody protocol (UDS `…/run/ptyd.sock`, length-prefixed, append-only verbs)
```
Hello{custody_version, build}            → HelloAck{custody_fingerprint, pid, sessions:[SessionInfo]}
Spawn{id, argv, env, cwd, cols, rows, px} → Spawned{id, pid, start_mark}   + fds[master, ring]
Attach{id}                                → Attached{id, pid, start_mark, exit?} + fds[master, ring]
Release{id}               (reader role back to ptyd; also implicit on disconnect)
Adopt{id, pid, start_mark} + fds[master, ring]   (ptyd restarted empty; server returns custody)
Signal{id, signo, to_foreground_pgrp}     (SIGINT to tcgetpgrp(), not the shell — sd:51:500)
Close{id}  ·  List  ·  Succeed{program}  ·  Shutdown
Event: Exited{id, status|-1}
```
The protocol is versioned in `Hello`. Unknown verbs are answered `unsupported` (`sd:51:110-142`). The custody fingerprint is a hash of golden encodings of every message plus the shell-integration scripts (slopty's scheme).

### 3.5 Lifecycles
| Event | What happens | Sessions |
|---|---|---|
| App quits, crashes or updates | Nothing on the host side; the client reconnects on relaunch and resumes. | kept |
| `axolottyd` planned restart or upgrade | (1) Stop reading the masters. (2) Write a final checkpoint at the exact head of every session (`ghostty_snapshot_encode`), plus a **formatter-VT fallback** in case the new build's snapshot decoder rejects the old format (§5.7). (3) `Release` every session. (4) Exit. The new server runs `Attach`, decodes the checkpoint, and replays the ring after its offset (the bytes ptyd drained during the gap). | kept, byte-exact |
| `axolottyd` crash | launchd KeepAlive restarts it. It attaches, loads the newest checkpoint (≤ 2 s / ≤ 2 MiB old) and replays the ring from the checkpoint offset. If the ring has wrapped past that offset, it writes a `gap` marker and sends a resize jiggle (SIGWINCH) so TUIs repaint. | kept |
| ptyd crash | The server still holds the masters. A fresh ptyd receives `Adopt` for each session and watches exits by pid and start time. | kept |
| ptyd upgrade, same fingerprint | Nothing to do. The content-addressed path is unchanged and the running ptyd is kept. | kept |
| ptyd upgrade, new fingerprint | Default: **keep the old ptyd running** (iTerm2's versioned-binary approach), because the server speaks every custody version still in use. Optional `Succeed`: the session table goes into an unlinked file, `FD_CLOEXEC` is cleared on the masters, rings and listener, then `execv(new, --inherit fd)`. `execve(2)` keeps the pid, ppid, pgid and open fds, so the children stay its children. Only slopty does this. | kept |
| Succession format changed | Ask "Updating ends N sessions" (slopty). This should almost never happen. | ended (consent) |
| Reboot or logout | The children are gone. The server restores each pane's last checkpoint as a dead "restored" screen with a divider. Agents are offered `--resume`. | restored screen |

launchd: `axolottyd`'s plist (`Contents/Library/LaunchAgents`, `BundleProgram`, `SMAppService.agent(plistName:)`) uses `KeepAlive{SuccessfulExit:false}`, with a clean exit 0 for "already running" (slop-desk's respawn loop, `sd:60:1395`), and `ProcessType=Interactive`. Children call `setsid()` + `TIOCSCTTY`.

**Survival rule** (POSIX `close()`): "If fildes refers to the manager side of a pseudo-terminal, and this is the last close, a SIGHUP signal shall be sent to the controlling process." A session therefore dies only if **ptyd and axolottyd both lose the master at once**. A reboot is the only routine case.

---

## 4. Layer 2: the server `axolottyd`

### 4.1 Concurrency model (Swift 6 strict concurrency)
- **`PaneActor`, one per session**, owns:
  - the `GhosttyTerminal` (authoritative);
  - a dedicated read thread on the master (C shim; `read` → journal append → `vt_write` in ≤ 64 KiB chunks);
  - the key and mouse encoders;
  - subscriber cursors;
  - the checkpointer.

  Terminal access is serialised, as `ghostty_snapshot_encode` requires ("caller must prevent concurrent writes").
- **`DocumentActor`** is the single serialisation point for the workspace document and intents.
- **`ClientSession`, one per connection**, runs the handshake, auth, a fair send scheduler, and subscriptions.
- **`Listener`s**: UDS (always on); TLS and QUIC (opt-in, "Allow remote access"); `--stdio`.

### 4.2 The authoritative terminal answers everything
The server terminal installs:
- `WRITE_PTY` (replies → master);
- `BELL`, `TITLE_CHANGED`, `PWD_CHANGED`, `DESKTOP_NOTIFICATION` (OSC 9/777), `PROGRESS_REPORT` (OSC 9;4);
- `SEMANTIC_PROMPT` (OSC 133), `PROGRAM_STATUS` (OSC 7501);
- `CLIPBOARD_WRITE`/`READ`, `COLOR_SCHEME`, `SIZE`, `DEVICE_ATTRIBUTES`.

These become document fields or events. Colour queries (OSC 10/11/4, mode 2031) are answered with the **driver client's** theme colours. Each client sends `SetAppearance` (fg/bg/palette/scheme), as slopty does. Security defaults stay off: `TITLE_REPORT` and `XT_CHECKSUM_REPORT` (`vt:terminal.h:2551, 2729`).

### 4.3 Agent status (host-truth, fanned out to every client)
Agent status comes from several sources, highest precedence first:
1. **Explicit**:
   - OSC 7501 program status, which libghostty parses into `idle|working|done|blocked|error` plus `permission|question|auth` (`vt:terminal.h:1423-1469`). The server advertises support by setting the callback, so `OSC 7501;?` is answered.
   - Hooks: Claude Code and Codex hooks run `axolotty status --pane $AXOLOTTY_PANE_ID …` against `AXOLOTTY_SOCKET`.
2. **Protocol hints**: OSC 9/777 notifications, OSC 9;4 progress, and OSC 133 C/D (command running, exit code).
3. **Process facts**: `tcgetpgrp(master)` + `proc_pidinfo` for the foreground program name.
4. **Screen heuristics**, as a last resort, on the server terminal only.

The state is published as `pane.agent{state, kind, app, message, progress, since}` plus a monotone `attentionEpoch`. Each client stores `seenEpoch` locally, so a badge is a shared fact and acknowledging it is device-local (`sd:decisions/vol-04.md` §4).

### 4.4 Persistence
- `workspace.json` holds the document; it is written atomically, and a corrupt file is set aside.
- `sessions/<id>/{recipe.json, ckpt-<offset>.ghsnap}`.
- Checkpoint policy: 1 s after output goes quiet, or every 2 MiB of journal, with at least 2 s between checkpoints. A checkpoint is forced when the journal since the last one exceeds ring/2, so a crash replay never meets a wrapped ring.
- History pages are written compressed (`COMPRESS_HISTORY` on decode, `vt:snapshot.h`).

---

## 5. Terminal state streaming

### 5.1 Options compared

| | Raw VT relay only (slop-desk) | Server state-diff (slopty, mosh) | **Hybrid: relay + snapshot resync (chosen)** |
|---|---|---|---|
| Client needs a VT engine | yes | no | yes (libghostty-vt, already built for iOS) |
| Late join / reconnect | replay history (O(bytes), dangerous) | screen + line pages | `snapshot` O(state); READY renders first, history streams after |
| Fidelity (scrollback, images, OSC 8, semantic marks, search, selection) | full | only what the cell protocol carries | full, by construction (same engine, same bytes) |
| Bandwidth, steady state | = PTY output (a TUI spinner ~1–20 KB/s; compresses ~10×) | ~rows changed per frame, rate-limited | = PTY output; for laggards, bounded by snapshot size |
| Slow link / laggard | stalls or backlog | natural (frame skip) | skip backlog → snapshot at current head |
| Query replies | N clients reply (bug) | server only | server only (D5) |
| Protocol surface | tiny | big (cells, styles, links, images, palette…) | tiny + snapshot blob |
| Version coupling | VT only | own cell protocol | snapshot format v1 is "WIP, no binary-compat guarantee" (§5.7) |

The hybrid keeps the relay's small protocol and full fidelity. It removes the relay's two failure modes, history replay and N repliers, with the snapshot API and D5.

### 5.2 Attach (late join, cold or warm)
```
C: PaneAttach{pane, chan, mode, have?{journal_id, offset}, viewport{cols,rows,cell_px}, history: all|pages(k)}
S (inside PaneActor, between two vt_writes, at journal head N):
   if have.journal_id == journal_id && have.offset >= ring.tail:  // warm resume
        send Output records [have.offset, N) …                      // byte-exact, cheap
   else:
        bytes = ghostty_snapshot_encode(terminal)                  // shared by all joiners at offset N
        send SnapBegin{chan, at:N, len, fmt_version} · SnapChunk… · SnapEnd{complete|truncated}
   then live Output records from N, in order with Resize records
C: decoder_ready() as soon as the bytes through READY have arrived → render immediately
   apply live Output (offset ≥ N) while decoder_next() prepends history pages
   (the header explicitly allows rendering, resizing and feeding live input between next() calls)
```
- **Ordering**: snapshot chunks go on a low-priority lane. The client buffers live records with offset ≥ N until READY has decoded, then interleaves.
- **Truncated history** (iOS on cellular): the server stops after `k` history pages at a record boundary. The snapshot records are self-delimiting (`tag|len|crc`), so the server can cut without understanding them. The client frees the decoder after its last `next()`. Per the header, "the terminal remains … usable with its already-restored history". A later "load full history" re-attaches with `history: all`. *Risk R3: ask upstream for an encode-side history limit.*

### 5.3 Steady state, backpressure and resync (no credit windows)
- Each `(client, pane)` subscription tracks `sent` and `acked`. The client acks **after applying to its mirror**, at least every 32 KiB or 50 ms.
- **Lag rule** (server-side constants only; nothing on the client has to match):
  - If `head − acked > 2 MiB`, or the oldest unacked record is older than 3 s, the subscription enters **RESYNC**: stop queueing output, wait until the bytes already sent are acked (or the transport drains), then send a fresh snapshot at the then-current head and resume.
  - This is tmux control mode's `%pause` / `%continue`, and mosh's "skip intermediate frames".
  - Acks never gate correctness; they only trigger a resync. That makes slop-desk's credit wedges impossible by construction.
- **Fair send scheduler, per connection**:
  - **P0**: control, document, status, and output from a pane that received input in the last 50 ms (echo);
  - **P1**: output of visible panes;
  - **P2**: background subscriptions;
  - **P3**: snapshot history.

  Keep ≤ 128 KiB in flight on the `NWConnection` (send-completion driven), so the priorities actually take effect on TCP.
- **Subscriptions are per visible pane.** A pane a client isn't showing gets **status only** (document fields), no bytes. Showing it means attach: a warm resume if the offset is still in the ring, otherwise a snapshot. That bounds client memory, and iOS only mirrors what's on screen.
- **Compression**: zstd streaming per subscription, negotiated, off on UDS. zstd is vendored C. Repaint-heavy agent TUIs compress well (risk R6: measure).

### 5.4 Resize with clients of different sizes
- **One writer.** `PaneActor.applySize()` is the only `TIOCSWINSZ` caller. It does: ioctl on the master → journal `resize` record → `ghostty_terminal_resize`. Clients apply the resize **at the same offset** from the stream. Reflow is deterministic for the same libghostty build.
- **Driver policy (default)**:
  - The driver is the client that created the pane.
  - If the driver detaches, the most-recently-interactive remaining *active* client becomes driver.
  - **Take** (an explicit gesture, or a macOS preference "take size on focus") moves the driver.
  - iOS is **passive** unless the user taps "Fit to iPhone". *But* when only passive clients are attached and the pane has never been sized, the first one drives (the fix for `sd:45:1702`).
  - Driver changes settle over 250 ms; the driver's own live resizes are coalesced to one per frame.
- **Non-drivers** render the driver's grid scaled to fit (font scale clamped), or pan, with a pill: "120×40 · sized by Mac Studio · Take".
- **Policies `smallest` / `largest`** (tmux semantics) are a per-server setting for people who want them.

### 5.5 Input path
- **Client → server events:**
  - `Key{action, key, mods, consumed_mods, text(utf8, layout-translated), unshifted_cp, composing}`, mirroring ghostty's `key/event.h`. IME composition stays client-local; commits arrive as text.
  - `Mouse{action, button, mods, cell(x,y), px(x,y)}`; `Wheel{dy_rows_fractional}`.
  - `Paste{text}`. The server applies bracketed paste or the safety check against *its* modes (`paste.h`) and can bounce `PasteHeld` for confirmation.
  - `Focus{in/out}`. The server sends mode-1004 focus to the PTY on the union of "any client focused".
  - `Signal{SIGINT}`.
- **On the server**, the `PaneActor` encodes with ghostty encoders configured `from_terminal`, then writes to the master. Keys from several clients are serialised in arrival order. No keyboard ownership (slopty ruling).
- **Viewport scroll, selection, search, copy, URL hover**: local on the client mirror. Nothing goes to the server, except wheel events when the program tracks the mouse or is on the alt screen.
- **Prediction / local echo** (mosh-style) is *phase 3*, iOS-on-WAN only. It draws as an overlay (never written into the mirror), only on shell input lines identified by OSC 133 `B`, and is off inside agent TUIs.

### 5.6 Hazards the relay must neutralise
- **Kitty graphics with file, temp-file or shared-memory media** read *server* paths. Client mirrors set `KITTY_IMAGE_MEDIUM_*` to off. The server detects such APCs with `ghostty_terminal_vt_write_until(APC_START|APC_END)` and **marks the pane for an image resync**: a snapshot carries pixels via `KITTY_IMAGE_PAYLOAD`.
- **OSC 52 clipboard**: the server applies policy and then delivers `ClipboardWrite` only to the client that most recently sent input. Reads (`CLIPBOARD_READ`) need an explicit prompt on that client.
- **Effects on mirrors are off** (bell, title and notifications come from the document), so a resync never re-fires a notification.

### 5.7 Version skew and divergence
- **Negotiation.** `Hello` carries the client's libghostty commit and snapshot `fmt_version`s; `Welcome` carries the server's.
  - Same commit → full hybrid.
  - Same snapshot version but different commit → hybrid, with the divergence check below on.
  - Incompatible → **formatter mode**: the server builds the attach state with `ghostty_formatter` emitting VT, with extras for palette, modes, scrolling region, tab stops, pwd, keyboard, cursor, style, hyperlinks, kitty keyboard and charsets. That is lossy (no images, soft wraps), but it is VT, which every version speaks. This is exactly the role slopty's checkpoint played.
- **Divergence check** (cheap and periodic): when output goes quiet, the server sends `Digest{chan, offset, hash(formatter plain text + cursor of the active area)}`. The client compares against its mirror at that offset. A mismatch triggers a resync and is reported in telemetry.

---

## 6. State model and conflicts

| Bucket | Contents | Sync |
|---|---|---|
| **Host-truth (document)** | servers' workspaces (name, order, cwd, color) · per-workspace **split tree** (ratios, not pixels) · panes ↔ sessions (pane = layout leaf; session = one process lifetime with its `journal_id`) · spawn recipes · titles/cwd/foreground program · `agent{…}` · `attentionEpoch` · exit status · size driver + resolved grid · per-pane `zoomed` (assigned) | snapshot/diff by rev |
| **Device-local** | windows and which workspace each shows · sidebar · focused pane (with an optional `followFocus`, default on for mac, off for iOS) · font, theme, cell scale · scroll position, selection, search · `seenEpoch` per pane · iOS presentation (one pane at a time, derived from the same tree) | never sent (except appearance → server for query replies) |
| **Presence** | which clients are attached, what each is viewing, who is driver | ephemeral, ≤ 10 Hz, never persisted |

**Layouts are shared** (tmux/zellij semantics; a tab opened on the Mac exists on the phone, as slop-desk's Phase 5 established), but **presentation is per device**: iOS renders the same tree as a pager, and a Mac can zoom a pane locally without changing the shared tree.

**Sync algorithm (document).**
- `epoch` (UUID per server start) + `rev:u64`.
- The server sends `DocSnapshot` on subscribe or on a foreign epoch, otherwise `DocDiff{base: client's acked rev}`. One frame is outstanding per client, with depth-1 coalescing.
- A diff is a set of idempotent field assignments and object add/remove. Duplicates and reordering are no-ops.

**Writes and conflicts.**
- Clients send `Intent{intent_id, ops[]}`.
- New objects carry **client-proposed UUIDv7**s, which the server validates. That gives optimistic UI and idempotent retries.
- The single `DocumentActor` applies intents in arrival order. LWW per `(kind, id, field)`. Ops are **assignments, never toggles**.
- The client overlays its pending intents, retires them on the first document frame after `IntentResult.applied`, and snaps back at once on `rejected`. Pending intents are **dropped on disconnect**, not replayed (`sd:45:1846`).
- **Structural conflicts** (a split of a pane another client just closed) are rejected as `targetGone`, and the client's overlay is dropped.

**Many servers per client.**
- `ServerDirectory` (local, Keychain-backed) holds the paired servers. There is one `ServerLink` actor per server, each with its own document replica.
- All ids are scoped `(serverID, id)`. The UI aggregates workspaces and attention across servers.
- Panes can't move across servers, because a PTY lives on one host.

---

## 7. Wire protocol v1

### 7.1 Envelope (identical on UDS, TLS, QUIC streams and stdio)
```
u32  len        little-endian, bytes after this field; ≤ 1 MiB (data frames ≤ 32 KiB for fairness)
u8   type       0x01 CONTROL(protobuf) · 0x02 OUTPUT · 0x03 RESIZE · 0x04 SNAP_CHUNK · 0x05 ACK · 0x06 DIGEST
u8   flags      bit0 zstd · bit1 first · bit2 last · bit3 truncated
uvarint chan    0 = connection control; otherwise a pane subscription id chosen by the client
payload         CONTROL: one `Envelope{oneof}` protobuf; OUTPUT: u64 offset + bytes; RESIZE: u64 offset,
                u16 cols, rows, cell_w, cell_h; SNAP_CHUNK: u64 at_offset + bytes; ACK: u64 offset
```
- **Serialization**: protobuf (`swift-protobuf` 1.39, codegen via the SwiftPM plugin) for the control plane. zellij (prost, u32 LE prefix) and Zed (`Envelope`, u32 LE prefix) make the same choice. It gives unknown-field tolerance, field-level evolution, a schema file as the source of truth, and a path to a third-party or CLI client in another language. The hot path never touches protobuf: bytes ride raw frames.
- **Rejected**:
  - hand-rolled TLV: slop-desk spent its golden-vector budget there;
  - FlatBuffers: zero-copy is pointless for control messages;
  - Codable + binary plist or Network `Coder` (JSON/plist only): no evolution rules, slow;
  - MessagePack: no schema;
  - "New Codable": experimental;
  - swift-binary-parsing 0.0.4: a parser only.
- **Versioning**:
  - `Hello{proto_min, proto_max}`; the server picks the highest common version.
  - Capability strings for optional features (`zstd`, `quic-streams`, `snapshot-v1`, `prediction`).
  - No both-ends constants: every threshold is server-side or advertised in `Welcome.limits`.
  - Released wire versions get frozen fixtures under `Tests/AxProtoFixtures/<version>/`. Tests compare decoded *fields*, not just round trips (`sd:decisions/vol-07.md:869`).

### 7.2 Message catalog (control plane, `oneof` in `Envelope`)
**Session**
- `Hello{client_id, device_name, platform, app_build, proto_min/max, vt_commit, snapshot_fmts[], caps[], resume?{server_epoch}}`
- `Welcome{server_id, server_name, epoch, proto, vt_commit, snapshot_fmt, caps[], limits{max_frame, ring_bytes, lag_bytes}, you{client_id, is_owner}}`
- `Ping{t}` / `Pong{t}` (RTT for the UI and prediction gating)
- `Goodbye{reason}` · `Error{code, msg, ref}`

**Document**
- `DocSubscribe{}` · `DocSnapshot{epoch, rev, doc}` · `DocDiff{epoch, base, rev, changes[]}` · `DocAck{rev}`
- `Intent{intent_id, ops[]}` → `IntentResult{intent_id, applied|rejected(reason)}`
- Ops:
  - `CreateWorkspace{id,name,cwd}` · `UpdateWorkspace{id, fields}` · `CloseWorkspace{id}`
  - `CreatePane{id, workspace, at{split_of, dir, ratio}|root, recipe{argv?, cwd, env+, kind: shell|agent(claude|codex|…)}}`
  - `ClosePane{id}` · `RestartPane{id}` · `MovePane{id, to}` · `SetRatio{split, ratio}` · `SetZoom{pane, bool}` · `RenamePane{id, title}`
  - `TakeSize{pane}` · `SetSizePolicy{pane|server, driver|smallest|largest}`
- `Presence{viewing[], driving[]}` (client → server, throttled) · `PresenceSet{clients[]}` (server → client)

**Panes**
- `PaneAttach{chan, pane, mode: interactive|view, have?, viewport, history}` → `PaneAttached{chan, session_id, journal_id, start: snapshot|resume}` (then data frames)
- `PaneDetach{chan}` · `PaneClosed{chan, reason, exit?}`
- `Viewport{chan, cols, rows, cell_px}` (a size contribution)
- `SetAppearance{fg, bg, cursor, palette[16..256], scheme}`
- `Key` / `Text` / `Mouse` / `Wheel` / `Paste{chunk, last}` / `Focus` / `Signal` (§5.5)
- `PasteHeld{chan, id}` → `PasteConfirm{id, ok}`
- `ClipboardWrite{chan, kind, data}` · `ClipboardReadRequest{chan, id}` → `ClipboardReadReply{id, data|denied}`
- `Notification{pane, epoch, title, body, kind}` (also reflected in the document) · `Bell{pane}`
- `Resync{chan}` (client-requested, e.g. after a digest mismatch)

**Local-only** (UDS, owner): `StatusReport{pane, state, …}` (hooks/CLI) · `Pairing{begin|list|revoke}` · `ServerAdmin{restart, upgrade, settings}`

### 7.3 Resume
A client keeps per server `{epoch, doc rev}` and per attached pane `{journal_id, offset}`. On reconnect:
- **Document**: same epoch → diff from the client's acked rev; new epoch → snapshot.
- **Panes**: `PaneAttach{have}` → byte-exact replay when the offset is still in the ring, otherwise a snapshot.

Because journal offsets live in ptyd's ring, **even a server restart doesn't force snapshots** for clients whose offset is still buffered.

---

## 8. Transport and security

### 8.1 Local (phase 1)
- **Socket path**: `~/Library/Application Support/Axolotty/run/d.sock` in a `0700` directory.
  - `sun_path` is 104 bytes and Network framework "inherits that artificial limit" (Quinn, forums 756756). Check the length at startup; if it's too long, fall back to `$TMPDIR/axolotty/` and publish the path in `~/.axolotty/socket`.
  - Unix sockets don't trigger local network privacy (Quinn, forums 784301).
- **Peer check**: `LOCAL_PEERCRED` / `getpeereid` uid == our uid. Optionally, `LOCAL_PEERTOKEN` + `SecCode` to require an Axolotty-signed peer for admin verbs.
- **Why a socket and not XPC**: XPC with `MachServices` + `XPCSession` (macOS 14) would work, but a socket carries the same bytes as remote. That means one code path, testable with `nc`, and usable from the CLI, hooks, `--stdio` and Linux.
  - Clients use `NetworkConnection` over `.unix(path:)` (the iOS/macOS 26 structured-concurrency API, WWDC25-250).
  - ptyd's custody socket is plain BSD sockets + `SCM_RIGHTS` (`unix(4)`: "as if it were created with a call to dup(2)").

### 8.2 Remote (phase 2)
- **Base transport**: TCP + TLS 1.3 using the 26 API:
  - `NetworkConnection(to:) { Framer<AxEnvelope> { TLS().peerAuthentication(.required).localIdentity(id).certificateValidator{…} } }`
  - `NWProtocolFramer` on the older API.
  - The built-in `Coder` only does JSON or plist, so it isn't used for the data plane.
  - Set `TCP_NODELAY` and turn TCP keepalive **on** (it is off by default, per TN3213), e.g. 10/5/3. App `Ping` every 15 s.
- **Identities**:
  - Each server and each client device has a long-term P-256 key; its self-signed certificate is created with **swift-certificates** ("Apple platforms have no API to do that", TN3213).
  - Store it as a Keychain `SecIdentity`. The Secure Enclave can't export to a TLS identity cleanly, so use it only if `SecIdentity` from an SE key proves workable (spike).
  - Both sides pin the peer's **SPKI SHA-256** in `certificateValidator`.
  - `server_id` = SPKI hash.
- **Pairing**: CryptoKit has **no PAKE**. Network framework's TLS-PSK "doesn't work with QUIC, it doesn't support TLS 1.3" (TN3213). So neither of those is used.
  - **QR (default, iOS)**: the Mac shows `axolotty://pair?h=<addrs>&p=<port>&fp=<spki>&t=<128-bit token>&exp=…` (5 min, single use). The client dials pinning `fp` and sends `Pair{token, device_name}` inside TLS. The server checks the token in constant time and stores the client's SPKI.
  - **Mac ↔ Mac**: the same link, carried by Universal Clipboard, AirDrop or a paste. Fallback: TOFU plus a **6-digit SAS** (HKDF over both SPKIs + TLS exporter) shown on both screens and confirmed by the user.
  - SPAKE2+ (RFC 9383) is a possible later addition: it is not in CryptoKit, so we would have to implement it on P256+HKDF ourselves, and the QR/link path doesn't need it.
- **Revocation**: a device list in the server's settings. A revoked SPKI fails the TLS handshake.
- **Discovery**: Bonjour `_axolotty._tcp` with TXT `{id=<fp prefix>, v=<proto>}`, `_udp` once QUIC lands.
  - **macOS 15+ local network privacy applies to LaunchAgents** ("the exception for launchd daemons doesn't apply to launchd agents", TN3179). Advertising Bonjour prompts the user; accepting inbound TCP doesn't. So advertising starts only when the user turns on "Allow connections from other devices", and the agent is registered via `SMAppService` so the prompt is attributed to the app.
  - iOS needs `NSLocalNetworkUsageDescription` + `NSBonjourServices`; without them Bonjour "fails silently" (`sd:06`).
  - Manual `host:port` entry is always available. Tailscale/MagicDNS names are just hostnames, and app TLS still applies.
- **Phase 3 transports**:
  - **QUIC** (`QUIC(alpn:)`, `openStream()`/`inboundStreams`; or `NWMultiplexGroup` on the old API): one bidirectional control stream + one unidirectional stream per pane subscription, which gives head-of-line isolation. The QUIC idle timeout defaults to 30 s (TN3213). Interface migration is claimed (WWDC21) but undocumented for Network framework; until a spike proves it, use `betterPathUpdateHandler` and reconnect + resume.
  - **SSH stdio**: `ssh host axolottyd --stdio` (Zed/cmux style) bridges to the UDS; auth is then SSH's. iOS can use swift-nio-ssh `directTCPIP`.
  - **NAT traversal**: Tailscale needs nothing from us. iroh has official Swift bindings (`iroh-ffi` 1.2, iroh 1.x) if a built-in P2P path is ever wanted; it is not planned for v1.

### 8.3 iOS lifecycle
- **Background**: the app is suspended within seconds and the sockets die. Treat a cold reconnect as *the* main path (`sd:52-screen-engine.md:19-32`).
- **Foreground**: `NWPathMonitor` triggers a reconnect. The document arrives as a diff or snapshot (O(tree)), and the *visible* pane attaches (resume if buffered, otherwise snapshot with `history: pages(k)`). This is a target, not a measurement; budget < 300 ms on LAN to first frame.
- **Attention while backgrounded** (phase 3):
  - **(a)** a push relay with an end-to-end encrypted payload, decrypted in a Notification Service Extension;
  - **(b)** a user-supplied ntfy or Pushover endpoint;
  - **(c)** none.

  Live Activities for "agent working/blocked" ride the same relay.
  - A Live Activity lasts at most 8 h active and 12 h on the Lock Screen.
  - `apns-priority: 5` updates don't count against the budget.
  - Silent pushes are limited to "two or three per hour", so they are useless for status.

  The daemon can't hold the developer's APNs key, which is why a relay is needed.

---

## 9. Module boundaries (SwiftPM)

| Target | Lang | Used by | Contents |
|---|---|---|---|
| `GhosttyVT` (binary) | Zig→C | all | pinned xcframework (macOS, iOS, iOS sim slices already present) |
| `AxCore` | C | all | async-signal-safe spawn (`setsid`, `TIOCSCTTY`, `execve`), SCM_RIGHTS helpers, ring/journal reader-writer, vendored zstd |
| `AxVT` | Swift | all | thin Swift face over terminal/snapshot/formatter/key/mouse/paste encoders; `Mirror` (callbacks off) vs `Authority` (callbacks on) configurations |
| `AxProto` | Swift (+ .proto) | all | envelope codec, generated messages, version and caps negotiation, fixtures. **No I/O.** |
| `AxModel` | Swift | all | document types, ids, diff/apply, intent validation (pure, shared by server and client overlay) |
| `AxNet` | Swift | all | Network.framework connections (UDS/TLS/QUIC), framer, reconnect/backoff, identity and pinning, pairing crypto |
| `AxNetListen` | Swift | macOS | listeners, Bonjour advertising (kept out of the iOS binary, cf. `sd:63:66-76`) |
| `AxServer` | Swift | axolottyd | PaneActor, DocumentActor, ClientSession, scheduler, checkpointer, status detectors, custody client |
| `axolotty-ptyd` | C | ptyd | holder executable; links only `AxCore` |
| `axolottyd` | Swift | — | `main` + LaunchAgent glue (`--stdio` mode) |
| `AxClient` | Swift | mac, iOS | ServerDirectory, ServerLink actor, mirror management, sync engine, optimistic overlay, input event building |
| `AxRender` | Swift + Metal | mac, iOS | renderer over `ghostty_render_state`, CoreText glyph atlas |
| `AxAppKit` / `AxUIKit` | Swift | apps | views, windows, gestures, IME |
| `axolotty` (CLI) | Swift | users, hooks | `status`, `notify`, `open`, `pair`; speaks `AxProto` over UDS |

Rule: anything both a client and the server need lives in `AxModel`, `AxProto` or `AxVT`, never copied. `AxServer` never imports AppKit.

---

## 10. Phased plan

**Phase 0 (spikes, ~1 week; each yields a number):**
- **S1**: `ghostty_snapshot_encode` time and size for 0, 10k and 100k scrollback lines at 200 cols; decode READY latency; compressed size (zstd).
- **S2**: relay determinism. Feed a recorded Claude Code session into two terminals with resizes at the same offsets, compare formatter output and snapshot bytes.
- **S3**: steady-state bandwidth of claude, codex and `cargo build` output, raw vs zstd.
- **S4**: the C ptyd spawn path. TIOCSCTTY, SIGINT to the foreground pgrp, reaping of adopted children.
- **S5**: does a setsid ptyd survive Sparkle replacing the app, `SMAppService` unregister/re-register and `launchctl kickstart -k` of `axolottyd`? Which process do TCC prompts for a shell's file access name?

**Phase 1 (local daemon + macOS client over UDS):**
- `axolotty-ptyd` (spawn/attach/release/adopt, journal ring, drain).
- `axolottyd` with PaneActor and checkpoints, DocumentActor, the UDS listener, and SMAppService registration of both agents.
- The mac client uses a mirror + `AxRender`, hybrid attach, and semantic input.
- Status: OSC 7501 + 133 + hooks via the CLI.
- **Exit gates** (real processes, not loopback, per `sd:45:1709`):
  - **G1**: `kill -9 axolottyd` mid-`claude`; the screen comes back identical (digest equal) and the child pid is unchanged.
  - **G2**: app update during a flood; zero lost bytes.
  - **G3**: two mac client instances on one pane; typing interleaves, one replier, sizes follow the driver.
  - **G4**: `kill -9 ptyd`; sessions survive via Adopt.
  - **G5**: a laggard client (SIGSTOP for 10 s) never slows the other client, and resyncs with one snapshot.

**Phase 2 (remote + iOS):**
- TLS listener, identities, QR pairing, Bonjour.
- iOS client: pager presentation, passive sizing + Fit, history `pages(k)`, foreground resume.
- Multi-server `ServerDirectory` on both clients.
- **Exit gates**:
  - the iPhone foreground → first frame budget on LAN;
  - Mac A + Mac B + iPhone on one server with converging documents (observed on each client, per `sd:decisions/vol-04.md` "two clients, watched");
  - a pairing that is revoked fails closed.

**Phase 3 (wide area and polish):** QUIC streams + migration; `--stdio` over SSH; predictive echo for iOS on WAN; push relay and Live Activities; ptyd `Succeed`; formatter-mode skew fallback hardening; Linux `axolottyd`/ptyd (the protocol is already OS-neutral).

---

## 11. Risks and open questions

| # | Risk | Mitigation |
|---|---|---|
| R1 | **Snapshot format v1 is WIP, "no binary-compatibility guarantee"** (`vt:snapshot.h`). iOS and Mac builds will run different commits. | Negotiate the commit and format; fall back to formatter mode (§5.7); checkpoints written at planned shutdown also carry a formatter copy; pin libghostty bumps to releases of both apps. |
| R2 | Mirror ≠ server (reflow, width tables, options differing between builds). | Same `AxVT` configuration code on both sides; the `Digest` check plus auto-resync; S2 spike. |
| R3 | Snapshot always includes *all* scrollback, which is heavy for iOS on cellular and for resync. | Truncate at a record boundary (§5.2); upstream request for a history-limit option; zstd. |
| R4 | Memory: every pane is held twice on a Mac (server + local mirror). | Mirror only visible panes; `ghostty_terminal_compress` on idle; ring pages are touched lazily. |
| R5 | ptyd bugs are the one thing that kills sessions. | C, single thread, about 1.5k LOC, fuzzed custody codec, never parses output, fingerprinted protocol, dual custody. |
| R6 | Agent TUIs repaint heavily (Claude Code sync frames), so relay bandwidth on cellular could be high. | zstd; status-only subscriptions for hidden panes; laggard → snapshot; S3 measures it. |
| R7 | Checkpoint I/O while agents stream. | Rate limits (≥ 2 s apart); history compression; it lives in the user's runtime directory; measure in S1. |
| R8 | Kitty file-medium images and OSC 52 have cross-host semantics. | §5.6 rules (server reads files; resync with pixels; clipboard to the last-input client). |
| R9 | Remote auth UX on Mac↔Mac without a camera. | Code + SAS now; adopt a platform PAKE if one is available. |
| R10 | iOS can't keep a socket in the background. | Treat cold resume as the main path; push relay is phase 3. |
| R11 | Distribution: a sandboxed app can't host shells. | Developer ID (notarised, Sparkle) for macOS. The iOS client goes through the App Store. The protocol skew is designed for (D9). |
| R12 | TCC attribution: shells spawned by a daemon-launched orphan may raise prompts that name `axolotty-ptyd`, or be denied silently. | S5; sign ptyd with the app's team id; document it; consider `AssociatedBundleIdentifiers`. |
| R13 | The snapshot format is not stable across libghostty bumps ("Version 1 has no compatibility promise", ghostty PR #13534), so **disk checkpoints don't survive a server upgrade**. | A planned shutdown writes formatter-VT as well; a crash recovery right after an upgrade falls back to formatter or ring-only replay. |

---

## 12. Why not the alternatives (one line each)

- **In-app server**: an app update or crash kills every agent. slop-desk deleted its in-app host (`sd:60:1338`).
- **A single daemon with exec-restart and no holder**: "cannot survive a new binary that fails to boot" (`sd:51:163`), and a VT-parser crash takes the PTYs with it.
- **Holder relays bytes (dtach-style)**: an extra hop and copy on every byte and every keystroke; slopty ruled it out (`workers.md:104`).
- **Server-side cell diffs (slopty)**: a large bespoke protocol to recreate fidelity that libghostty already gives a client mirror for free.
- **CRDT for layouts**: one serialisation point means there is nothing to merge (Zed uses a CRDT for text, RPC for the project tree; `sd:decisions/vol-04.md`).
- **Input-keyed or presence-keyed resize**: flaps; a jittery phone heartbeat SIGWINCHes a desktop nvim (`sd:45:1164`).

---

## 13. Sources (retrieved 2026-11-02)

**Local (primary):**
- `vt:snapshot.h`, `vt:terminal.h` (options `2199–2783`, OSC 7501 `1419–1530`, `vt_write_until` `3342–3467`, continuation `3499–3560`), `vt:formatter.h`, `vt:render.h`, `vt:key/`, `vt:mouse/`, `vt:paste.h`.
- slop-desk:
  - `sd:20-wire-protocol.md`, `sd:13-network-transport.md`, `sd:45-multi-client-state-sync.md`, `sd:51-process-supervision.md`, `sd:52-screen-engine.md`, `sd:59`, `sd:60`, `sd:63`, `sd:72`, `sd:06`;
  - `sd:decisions/vol-01.md` (replay hygiene), `vol-03.md` (state transfer), `vol-04.md` (multi-client), `vol-07.md`, `vol-14.md`;
  - `slopdesk-wire/src/mux/flow.rs`.
- slopty:
  - `sl:docs/ARCHITECTURE.md` (§1 shape, §2 terminal, "PTY custody", "After a reboot");
  - `sl:docs/decisions/workers.md:101-160, 931-960`, `sl:docs/decisions/multi-client.md`;
  - `sl:crates/slopty-pty/src/protocol.rs`, `sl:apps/slopty-ptyd/src/{daemon,session,succeed,custody}.rs`.

**Multiplexers and terminals:**
- tmux: `tmux.1` (window-size, aggressive-resize, control mode); `tmux-protocol.h` (`PROTOCOL_VERSION 8`); `client.c:473,664`; `tty.c` `tty_write`; `screen-redraw.c`; Control-Mode wiki — https://github.com/tmux/tmux (a73616d), https://github.com/tmux/tmux/wiki/Control-Mode
- iTerm2 tmux integration: https://iterm2.com/documentation-tmux-integration.html
- iTerm2 server:
  - code: `sources/Tasks/iTermFileDescriptorMultiServer.c`, `iTermMultiServerProtocol.h`, `iTermFileDescriptorMultiClient(.m,+MRR.m)`, `iTermServerDeleter.swift`, `iTermMultiServerConnection.m` — https://github.com/gnachman/iTerm2 (095beb45)
  - docs and release notes: https://iterm2.com/downloads.html (3.4 notes), https://iterm2.com/3.4/documentation-restoration.html
- zellij: `zellij-utils/src/ipc.rs`, `consts.rs`, `zellij-server/src/screen.rs`; https://zellij.dev/documentation/options.html, https://zellij.dev/documentation/session-resurrection.html
- mosh: https://mosh.org/mosh-paper.pdf; `src/network/transportsender{.h,-impl.h}` (decd9b7)
- Eternal Terminal: `docs/protocol.md`, `src/base/BackedWriter.hpp`; https://eternalterminal.dev/howitworks/
- WezTerm: `codec/src/lib.rs` (`CODEC_VERSION 46`), `wezterm-client/src/{client.rs,pane/renderable.rs}`, `wezterm-mux-server-impl/src/sessionhandler.rs`; https://wezterm.org/multiplexing.html
- Zed: https://zed.dev/docs/remote-development; `crates/remote/src/protocol.rs`, `crates/remote_server/src/server.rs`
- VS Code: https://code.visualstudio.com/docs/remote/faq · tmate, upterm, sshx, Wave (https://docs.waveterm.dev/durable-sessions), Warp: READMEs and docs
- cmux: `README.md`, `docs/remote-daemon-spec.md`, `docs/shared-terminal-sizing.md`, `docs/cloud-cmux-tui-daemon.md`, `docs/notifications.md` — https://github.com/manaflow-ai/cmux (e31f3aa8)
- herdr: `README.md`, `docs/next/website/src/content/docs/{agents,concepts,persistence-remote}.mdx`, `src/protocol/wire.rs` — https://github.com/herdrdev/herdr (ee5bfb5)
- dtach / abduco / zmx / shpool:
  - https://github.com/crigler/dtach (`master.c`, README)
  - https://github.com/martanne/abduco (`server.c`, `abduco.1`)
  - https://github.com/neurosnap/zmx (`docs/posts/architecture.md`, `src/ipc.zig`)
  - https://github.com/shell-pool/shpool (README, CONFIG.md, issue #377)
- Ghostty / Superlogical:
  - https://mitchellh.com/writing/libghostty-is-coming, /writing/superlogical, /writing/program-status-osc7501
  - https://superlogical.com/updates/public-testing-beginning
  - ghostty PR #13534 (snapshot: "Version 1 has no compatibility promise"), discussion #11998, issue #1935

**Apple platform:**
- WWDC25-250, "Use structured concurrency with Network framework" (`NetworkConnection`, `NetworkListener`, `NetworkBrowser`, `TLV`, `Coder`, `Framer`): https://developer.apple.com/videos/play/wwdc2025/250/
- TN3213 (TLS-PSK limits, swift-certificates, QUIC idle timeout 30 s, TCP keepalive off): https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
- TN3179, local network privacy (LaunchAgents not exempt; Bonjour registration needs it, inbound TCP doesn't): https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Developer forums:
  - 784301 (unix sockets exempt from local network privacy)
  - 756756 (`sun_path` 104)
  - 685525 (iOS background limits)
  - 85066 (≈30 s background task)
- SMAppService: https://developer.apple.com/documentation/servicemanagement/smappservice/agent(plistname:) · App Sandbox helper inheritance: https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox
- "Updating Mac Software" (replace by rename): https://developer.apple.com/documentation/security/updating-mac-software
- Man pages: `launchd.plist(5)` (AbandonProcessGroup), `unix(4)` (SCM_RIGHTS, LOCAL_PEERCRED), `execve(2)`
- POSIX `close()` (last close of a PTY manager → SIGHUP): https://pubs.opengroup.org/onlinepubs/9799919799/functions/close.html
- CryptoKit index (no PAKE; HPKE iOS 17; ML-KEM/ML-DSA, SE): https://developer.apple.com/documentation/cryptokit · RFC 9383 SPAKE2+
- ActivityKit push: https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
- Libraries: swift-protobuf 1.39.0; apple/swift-certificates; apple/swift-nio-ssh 0.15.1; n0-computer/iroh-ffi 1.2.0; apple/swift-binary-parsing 0.0.4
