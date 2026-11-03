//! One QUIC connection as Axolotty's link: numbered lanes of bytes, each in order, none waiting
//! on another.
//!
//! A lane is a stream. Lane 0 (control: hellos, requests, typed input) is the bidirectional
//! stream the client opens; every other lane is a unidirectional stream its sender opens on the
//! lane's first bytes. A stream's opener writes the lane number (4 bytes, big-endian) before
//! anything else, so the acceptor knows which lane it is; the server's half of lane 0 needs none.
//!
//! A pane's output lost in one packet holds back that pane alone, never another pane's echo
//! (TCP held every lane behind it). Priorities come with each send: a lane carrying an echo is
//! raised to `transport::ECHO_PRIORITY` and leaves in the next packet, unpaced, and is never
//! held for send-buffer room a flood has taken (noq-proto patch 23).
//!
//! QUIC's send buffer is held to twice the congestion window ([`SendWindow`]): what a flood
//! queues past that waits here, where `pending` counts it, so the app sees a pane fall behind
//! and skips ahead (a snapshot) rather than streaming seconds of stale output after Ctrl-C.

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use bytes::Bytes;
use noq::{Connection, ConnectionError, PathId, RecvStream, SendStream, VarInt};
use tokio::runtime::Handle;
use tokio::sync::{mpsc, oneshot};
use tokio::time::Instant;

/// Where a link's bytes and its end go. Called on the runtime's threads; `data` for one lane in
/// order, never after `closed`.
pub trait Sink: Send + Sync + 'static {
    fn data(&self, lane: u32, bytes: &[u8]);
    /// `None`: closed by either side on purpose; else what broke it.
    fn closed(&self, reason: Option<String>);
}

/// The largest read handed to the sink at once.
const READ_CHUNK: usize = 64 << 10;

/// The send buffer never shrinks below this: a few round trips of a fast tailnet path.
pub const SEND_WINDOW_FLOOR: u64 = 256 << 10;
/// How often a writing link fits its send buffer to the congestion window.
const SEND_WINDOW_EVERY: Duration = Duration::from_millis(20);

/// QUIC's send buffer, fitted to twice the congestion window while the link writes. noq's
/// default is 10 MB, eight round trips of a 100 Mbit/s path: on a 5 MB/s Wi-Fi link a flood of
/// panes kept 2.7 s of output in it after the program stopped (`tests/sim.rs`). Twice the
/// window never holds back a byte the congestion controller would send.
struct SendWindow {
    conn: Connection,
    /// When it was last fitted; `None` once tuning is off.
    at: Mutex<Option<Option<Instant>>>,
}

impl SendWindow {
    fn new(conn: Connection) -> Self {
        conn.set_send_window(SEND_WINDOW_FLOOR);
        Self { conn, at: Mutex::new(Some(None)) }
    }

    /// Called as a lane writes; fits the buffer at most every [`SEND_WINDOW_EVERY`], so an idle
    /// link wakes for nothing.
    fn fit(&self) {
        let now = Instant::now();
        let mut at = lock(&self.at);
        let Some(last) = at.as_mut() else { return };
        if last.is_some_and(|t| now.duration_since(t) < SEND_WINDOW_EVERY) {
            return;
        }
        *last = Some(now);
        drop(at);
        let cwnd = self.conn.congestion_state(PathId::ZERO).map_or(0, |c| c.window());
        self.conn.set_send_window(cwnd.saturating_mul(2).max(SEND_WINDOW_FLOOR));
    }
}

enum Out {
    Data(Bytes),
    Priority(i32),
}

struct Lane {
    tx: mpsc::UnboundedSender<Out>,
    pending: Arc<AtomicUsize>,
    priority: i32,
}

struct Inner {
    conn: Connection,
    window: Arc<SendWindow>,
    server: bool,
    runtime: Handle,
    lanes: Mutex<HashMap<u32, Lane>>,
    total: Arc<AtomicUsize>,
    sink: Mutex<Option<Arc<dyn Sink>>>,
    /// The client's half of lane 0 to read, until `start`.
    control_recv: Mutex<Option<RecvStream>>,
    /// The server's half of lane 0 to write, once the client's stream is accepted.
    control_send: Mutex<Option<oneshot::Sender<SendStream>>>,
}

/// One connection's lanes. Cheap to clone; every clone is the same link.
#[derive(Clone)]
pub struct Link(Arc<Inner>);

impl Link {
    /// The client's side of a connection just made: opens lane 0 at once (no round trip; the
    /// server sees it with its first bytes, the lane header).
    pub async fn client(conn: Connection, runtime: Handle) -> Result<Self, ConnectionError> {
        let (send, recv) = conn.open_bi().await?;
        let link = Self::new(conn, false, runtime);
        *lock(&link.0.control_recv) = Some(recv);
        link.add_lane(0, async move { Some(send) }, true);
        Ok(link)
    }

    /// The server's side of a connection just accepted. Lane 0's write half comes with the
    /// client's stream, accepted in `start`.
    pub fn server(conn: Connection, runtime: Handle) -> Self {
        let link = Self::new(conn, true, runtime);
        let (tx, rx) = oneshot::channel();
        *lock(&link.0.control_send) = Some(tx);
        link.add_lane(0, async move { rx.await.ok() }, false);
        link
    }

    fn new(conn: Connection, server: bool, runtime: Handle) -> Self {
        Self(Arc::new(Inner {
            window: Arc::new(SendWindow::new(conn.clone())),
            conn,
            server,
            runtime,
            lanes: Mutex::new(HashMap::new()),
            total: Arc::new(AtomicUsize::new(0)),
            sink: Mutex::new(None),
            control_recv: Mutex::new(None),
            control_send: Mutex::new(None),
        }))
    }

    /// Starts reading into `sink`; it hears every lane's bytes, then the link's end once.
    pub fn start(&self, sink: Arc<dyn Sink>) {
        *lock(&self.0.sink) = Some(sink);
        let inner = Arc::clone(&self.0);
        self.0.runtime.spawn(async move {
            let reason = match inner.conn.closed().await {
                ConnectionError::LocallyClosed => None,
                ConnectionError::ApplicationClosed(c) if c.error_code == VarInt::from_u32(0) => None,
                other => Some(other.to_string()),
            };
            if let Some(sink) = lock(&inner.sink).take() {
                sink.closed(reason);
            }
        });
        if self.0.server {
            let inner = Arc::clone(&self.0);
            self.0.runtime.spawn(async move {
                let Ok((send, mut recv)) = inner.conn.accept_bi().await else { return };
                if let Some(tx) = lock(&inner.control_send).take() {
                    let _ = tx.send(send);
                }
                let mut head = [0_u8; 4];
                if recv.read_exact(&mut head).await.is_ok() {
                    read_lane(&inner, u32::from_be_bytes(head), recv).await;
                }
            });
        } else if let Some(recv) = lock(&self.0.control_recv).take() {
            let inner = Arc::clone(&self.0);
            self.0.runtime.spawn(async move { read_lane(&inner, 0, recv).await });
        }
        let inner = Arc::clone(&self.0);
        self.0.runtime.spawn(async move {
            while let Ok(mut recv) = inner.conn.accept_uni().await {
                let inner = Arc::clone(&inner);
                tokio::spawn(async move {
                    let mut head = [0_u8; 4];
                    if recv.read_exact(&mut head).await.is_ok() {
                        read_lane(&inner, u32::from_be_bytes(head), recv).await;
                    }
                });
            }
        });
    }

    /// Queues `data` on `lane` at `priority`; never blocks. Bytes on one lane leave in order.
    pub fn send(&self, lane: u32, priority: i32, data: Bytes) {
        if data.is_empty() {
            return;
        }
        let mut lanes = lock(&self.0.lanes);
        if !lanes.contains_key(&lane) {
            drop(lanes);
            let conn = self.0.conn.clone();
            self.add_lane(lane, async move { conn.open_uni().await.ok() }, true);
            lanes = lock(&self.0.lanes);
        }
        let Some(l) = lanes.get_mut(&lane) else { return };
        if l.priority != priority {
            l.priority = priority;
            let _ = l.tx.send(Out::Priority(priority));
        }
        let n = data.len();
        if l.tx.send(Out::Data(data)).is_ok() {
            l.pending.fetch_add(n, Ordering::Relaxed);
            self.0.total.fetch_add(n, Ordering::Relaxed);
        }
    }

    /// Bytes queued on `lane` and not yet taken by QUIC's send buffer.
    pub fn pending(&self, lane: u32) -> usize {
        lock(&self.0.lanes).get(&lane).map_or(0, |l| l.pending.load(Ordering::Relaxed))
    }

    /// Bytes queued on every lane.
    pub fn pending_total(&self) -> usize {
        self.0.total.load(Ordering::Relaxed)
    }

    /// The path's smoothed round trip.
    pub fn rtt(&self) -> Option<std::time::Duration> {
        self.0.conn.rtt(noq::PathId::ZERO)
    }

    pub fn peer(&self) -> Option<std::net::SocketAddr> {
        let a = self.0.conn.path(noq::PathId::ZERO)?.remote_address().ok()?;
        Some(std::net::SocketAddr::new(a.ip().to_canonical(), a.port()))
    }

    /// Leaves QUIC's send buffer at noq's default from now on, to measure against the fitted one.
    pub fn keep_default_send_window(&self) {
        // noq's default: eight times a stream's 1.25 MB receive window.
        self.0.conn.set_send_window(10_000_000);
        *lock(&self.0.window.at) = None;
    }

    /// Ends the link; the sink hears `closed(None)`. What is still queued is dropped.
    pub fn close(&self, code: u32) {
        self.0.conn.close(VarInt::from_u32(code), b"");
    }

    fn add_lane(
        &self,
        lane: u32,
        stream: impl Future<Output = Option<SendStream>> + Send + 'static,
        header: bool,
    ) {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let pending = Arc::new(AtomicUsize::new(0));
        lock(&self.0.lanes).insert(lane, Lane { tx, pending: Arc::clone(&pending), priority: 0 });
        let total = Arc::clone(&self.0.total);
        let window = Arc::clone(&self.0.window);
        self.0.runtime.spawn(async move {
            let Some(mut s) = stream.await else { return };
            if header && s.write_all(&lane.to_be_bytes()).await.is_err() {
                return;
            }
            while let Some(out) = rx.recv().await {
                match out {
                    Out::Priority(p) => {
                        let _ = s.set_priority(p);
                    }
                    Out::Data(b) => {
                        let n = b.len();
                        window.fit();
                        let sent = s.write_chunk(b).await;
                        pending.fetch_sub(n, Ordering::Relaxed);
                        total.fetch_sub(n, Ordering::Relaxed);
                        if sent.is_err() {
                            return;
                        }
                    }
                }
            }
        });
    }
}

/// Hands one stream's bytes to the sink as they come, until the stream or the link ends.
async fn read_lane(inner: &Arc<Inner>, lane: u32, mut recv: RecvStream) {
    while let Ok(Some(chunk)) = recv.read_chunk(READ_CHUNK).await {
        let sink = lock(&inner.sink);
        let Some(sink) = sink.as_ref() else { return };
        sink.data(lane, &chunk);
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}
