//! The link on a simulated network, in virtual time (`shape::sim`, Slopty's): a key's echo
//! beside a flood, loss and reordering, a Wi-Fi blackout ridden out and one that ends the link,
//! and a seed that repeats its run to the packet. Nothing reads a real clock, so a minute's
//! outage takes milliseconds and every number here is the same on every run.

mod shape;

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axquic::link::{Link, Sink};
use axquic::transport::{ECHO_PRIORITY, endpoint_on};
use bytes::Bytes;
use shape::sim::{Faults, Net};
use tokio::sync::mpsc;
use tokio::time::Instant;

const KEYS: u32 = 120;
const KEY_EVERY: Duration = Duration::from_millis(30);
/// Flood lanes are this and up; a pane's lanes are below.
const FLOOD_BASE: u32 = 100;
const ECHO_LANE: u32 = 9;

fn at(host: u8) -> SocketAddr {
    SocketAddr::from(([100, 64, 0, host], 7518))
}

/// The person's Wi-Fi to the far Mac: 6 ms there and back, a few ms of jitter, 5 MB/s with
/// 50 ms of buffer at the bottleneck.
fn wifi() -> shape::Link {
    shape::Link {
        delay: Duration::from_millis(3),
        jitter: Duration::from_millis(3),
        loss: 0.0,
        rate: 5_000_000,
        queue: 250_000,
    }
}

#[derive(Default)]
struct Got {
    lanes: Mutex<HashMap<u32, Vec<u8>>>,
    /// When each 4-byte unit on a lane arrived, in order.
    times: Mutex<HashMap<u32, Vec<Instant>>>,
    closed: Mutex<Option<Option<String>>>,
}

struct Collect(Arc<Got>, mpsc::UnboundedSender<u32>);

impl Sink for Collect {
    fn data(&self, lane: u32, bytes: &[u8]) {
        let mut lanes = self.0.lanes.lock().unwrap();
        let buf = lanes.entry(lane).or_default();
        let before = buf.len() / 4;
        buf.extend_from_slice(bytes);
        let after = buf.len() / 4;
        if lane < FLOOD_BASE {
            let now = Instant::now();
            self.0.times.lock().unwrap().entry(lane).or_default().extend((before..after).map(|_| now));
        }
        drop(lanes);
        let _ = self.1.send(lane);
    }
    fn closed(&self, reason: Option<String>) {
        *self.0.closed.lock().unwrap() = Some(reason);
        let _ = self.1.send(u32::MAX);
    }
}

struct Pair {
    net: Net,
    client: Link,
    server: Link,
    c: Arc<Got>,
    s: Arc<Got>,
    s_rx: mpsc::UnboundedReceiver<u32>,
    c_rx: mpsc::UnboundedReceiver<u32>,
}

async fn pair(faults: Faults, seed: u64) -> Pair {
    let net = Net::new(faults, seed);
    let rt = tokio::runtime::Handle::current();
    let server = endpoint_on(Box::new(net.bind(at(2)).unwrap()), true, Some(seed)).unwrap();
    let client = endpoint_on(Box::new(net.bind(at(3)).unwrap()), false, Some(seed ^ 1)).unwrap();
    let accept = tokio::spawn({
        let rt = rt.clone();
        async move { Link::server(server.accept().await.unwrap().await.unwrap(), rt) }
    });
    let conn = client.connect(at(2), "axolotty").unwrap().await.unwrap();
    let client = Link::client(conn, rt).await.unwrap();
    client.send(0, 0, Bytes::from_static(b"helo"));
    let server = accept.await.unwrap();
    let (c, s) = (Arc::new(Got::default()), Arc::new(Got::default()));
    let (ctx, c_rx) = mpsc::unbounded_channel();
    let (stx, s_rx) = mpsc::unbounded_channel();
    client.start(Arc::new(Collect(Arc::clone(&c), ctx)));
    server.start(Arc::new(Collect(Arc::clone(&s), stx)));
    Pair { net, client, server, c, s, s_rx, c_rx }
}

/// Keeps a pane's worth of output queued on each of `lanes` flood lanes, as `cat` on a big
/// file does in each.
fn flood(link: &Link, lanes: u32) -> tokio::task::JoinHandle<()> {
    let link = link.clone();
    tokio::spawn(async move {
        let chunk = Bytes::from(vec![b'x'; 16 << 10]);
        loop {
            for lane in FLOOD_BASE..FLOOD_BASE + lanes {
                while link.pending(lane) < 256 << 10 {
                    link.send(lane, 0, chunk.clone());
                }
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
}

/// A key every 30 ms, each echoed by the far side the moment it arrives, at `echo_priority`;
/// returns each key's time to its echo.
async fn type_keys(p: &mut Pair, echo_priority: i32) -> Vec<Duration> {
    let server = p.server.clone();
    let s = Arc::clone(&p.s);
    let mut s_rx = std::mem::replace(&mut p.s_rx, mpsc::unbounded_channel().1);
    // The far side: every whole key after the hello is echoed back on the pane's lane.
    let echoer = tokio::spawn(async move {
        let mut echoed = 1; // the hello
        while s_rx.recv().await.is_some() {
            let lanes = s.lanes.lock().unwrap();
            let got = lanes.get(&0).map_or(&[][..], Vec::as_slice);
            while got.len() >= (echoed + 1) * 4 {
                let key = Bytes::copy_from_slice(&got[echoed * 4..echoed * 4 + 4]);
                server.send(ECHO_LANE, echo_priority, key);
                echoed += 1;
            }
        }
    });
    let mut sent = Vec::new();
    for k in 0..KEYS {
        sent.push(Instant::now());
        p.client.send(0, ECHO_PRIORITY, Bytes::copy_from_slice(&k.to_be_bytes()));
        tokio::time::sleep(KEY_EVERY).await;
    }
    let c = Arc::clone(&p.c);
    tokio::time::timeout(Duration::from_secs(30), async {
        while c.times.lock().unwrap().get(&ECHO_LANE).map_or(0, Vec::len) < KEYS as usize {
            p.c_rx.recv().await;
        }
    })
    .await
    .expect("every echo comes back");
    echoer.abort();
    let times = p.c.times.lock().unwrap()[&ECHO_LANE].clone();
    let echoes = p.c.lanes.lock().unwrap()[&ECHO_LANE].clone();
    let order: Vec<u32> = echoes.chunks(4).map(|b| u32::from_be_bytes(b.try_into().unwrap())).collect();
    assert_eq!(order, (0..KEYS).collect::<Vec<_>>(), "every key's echo, in order");
    sent.iter().zip(times).map(|(s, t)| t - *s).collect()
}

fn quantile(v: &[Duration], q: f64) -> Duration {
    let mut v = v.to_vec();
    v.sort();
    v[((v.len() as f64 * q) as usize).min(v.len() - 1)]
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1e3
}

fn flooded(got: &Got) -> usize {
    got.lanes.lock().unwrap().iter().filter(|(l, _)| **l >= FLOOD_BASE).map(|(_, b)| b.len()).sum()
}

/// The seeds a run sweeps: one in the gate, `AXQSIM_SEEDS=n` for a long run.
fn seeds(gate: u64) -> Vec<u64> {
    match std::env::var("AXQSIM_SEEDS").ok().and_then(|n| n.parse::<u64>().ok()) {
        Some(n) => (1..=n).collect(),
        None => vec![gate],
    }
}

/// Twelve panes stream a build log on the far Mac while the person types in another: the
/// echo leaves ahead of all of them, so it waits on the path's queue, not behind twelve
/// packets of other panes' output per hop. The same echo at the panes' own priority is the
/// canary: it is shown slower in the same run, so the bound can fail.
#[tokio::test(start_paused = true)]
async fn an_echo_beside_a_flood_waits_on_the_path_not_the_flood() {
    const PANES: u32 = 12;
    let mean = |v: &[Duration]| v.iter().sum::<Duration>() / v.len() as u32;
    let mut held = Vec::new();
    for seed in seeds(11) {
        let mut idle = pair(Faults::over(wifi()), seed).await;
        let alone = type_keys(&mut idle, ECHO_PRIORITY).await;
        idle.client.close(0);

        let run = async |priority| {
            let mut p = pair(Faults::over(wifi()), seed).await;
            let f = flood(&p.server, PANES);
            tokio::time::sleep(Duration::from_millis(500)).await; // the flood fills the path first
            let start = Instant::now();
            let echoes = type_keys(&mut p, priority).await;
            let rate = flooded(&p.c) as f64 / 1e6 / (start.elapsed() + Duration::from_millis(500)).as_secs_f64();
            f.abort();
            p.client.close(0);
            (echoes, rate, p.net.counts())
        };
        let (lifted, rate, counts) = run(ECHO_PRIORITY).await;
        let (level, _, _) = run(0).await;

        let q = |v: &[Duration], f| ms(quantile(v, f));
        println!(
            "seed {seed}: echo p50/p99/max ms idle {:.0}/{:.0}/{:.0}, flooded {:.0}/{:.0}/{:.0}, flooded level {:.0}/{:.0}/{:.0}; flood {rate:.2} MB/s, overflowed {} lost {} of {}",
            q(&alone, 0.5),
            q(&alone, 0.99),
            q(&alone, 1.0),
            q(&lifted, 0.5),
            q(&lifted, 0.99),
            q(&lifted, 1.0),
            q(&level, 0.5),
            q(&level, 0.99),
            q(&level, 1.0),
            counts.shaped.overflowed,
            counts.shaped.lost,
            counts.shaped.sent,
        );
        if std::env::var_os("AXQSIM_REPORT").is_some() {
            continue;
        }
        assert!(rate > 4.0, "seed {seed}: the flood still has most of the 5 MB/s link ({rate:.2})");
        // What the flood adds to an echo is the bottleneck's standing queue: BBR's bound on what
        // is in flight, about two round trips at this rate (15–17 ms over 30 seeds; before the
        // send window was fitted and an echo exempt from it, 100–450 ms in half of them).
        let added = quantile(&lifted, 1.0).saturating_sub(quantile(&alone, 1.0));
        assert!(added <= Duration::from_millis(20), "seed {seed}: the flood adds {added:?} to an echo");
        held.push(mean(&level).saturating_sub(mean(&lifted)));
    }
    // The canary: the same echo at the panes' priority waits its turn behind them. By how much
    // varies with the seed (0.3–3 ms on average over 100), so it is held over the whole sweep.
    if !held.is_empty() {
        let held = mean(&held);
        assert!(held >= Duration::from_millis(1), "unlifted, the echo waits its turn ({held:?})");
    }
}

/// Ctrl-C on twelve flooding panes: once the programs stop, what the link still holds drains
/// in the time its queued bytes take at the link's rate, and QUIC's own buffer adds at most a
/// few round trips to that. noq's default buffer, the canary, held seconds more.
#[tokio::test(start_paused = true)]
async fn after_a_flood_stops_the_screen_stops_soon_after() {
    async fn drain(fitted: bool) -> (Duration, f64) {
        let mut p = pair(Faults::over(wifi()), 11).await;
        if !fitted {
            p.server.keep_default_send_window();
        }
        let f = flood(&p.server, 12);
        tokio::time::sleep(Duration::from_secs(2)).await;
        f.abort();
        let stop = Instant::now();
        // What the app still had queued when the programs stopped: it drains at the link's rate.
        let queued = p.server.pending_total();
        let rate = flooded(&p.c) as f64 / 2.0;
        // The link is quiet once nothing has come for 100 ms.
        let mut last = (flooded(&p.c), Instant::now());
        while last.1.elapsed() < Duration::from_millis(100) {
            tokio::select! {
                _ = p.c_rx.recv() => {}
                () = tokio::time::sleep(Duration::from_millis(100)) => {}
            }
            let now = flooded(&p.c);
            if now != last.0 {
                last = (now, Instant::now());
            }
        }
        let extra = (last.1 - stop).saturating_sub(Duration::from_secs_f64(queued as f64 / rate));
        p.client.close(0);
        (extra, rate)
    }
    let (fitted, rate) = drain(true).await;
    let (default, _) = drain(false).await;
    println!("past the app's queue, the link drained {fitted:?} fitted, {default:?} at noq's default; {:.2} MB/s", rate / 1e6);
    assert!(rate > 4.0e6, "fitting the buffer costs no throughput ({:.2} MB/s)", rate / 1e6);
    assert!(fitted <= Duration::from_millis(150), "QUIC's buffer held {fitted:?} of output");
    assert!(default >= Duration::from_secs(1), "the canary: noq's default buffer holds seconds ({default:?})");
}

/// Loss and reordering cost time, never bytes or order: every lane arrives whole.
#[tokio::test(start_paused = true)]
async fn loss_and_reordering_cost_time_not_bytes() {
    let mut faults = Faults::over(shape::Link { loss: 0.03, ..wifi() });
    faults.reorder = 0.02;
    faults.reorder_by = Duration::from_millis(8);
    let mut p = pair(faults, 5).await;
    let lanes: Vec<u32> = vec![0, 3, 7, 1_000_003];
    // A kilobyte per message, so the run is a thousand-odd packets and the faults land.
    let message = |i: u32, l: u32| -> Vec<u8> { (i ^ l).to_be_bytes().repeat(256) };
    for i in 0..400_u32 {
        for &l in &lanes {
            p.server.send(l, 0, Bytes::from(message(i, l)));
        }
        if i % 16 == 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }
    let c = Arc::clone(&p.c);
    tokio::time::timeout(Duration::from_secs(60), async {
        while lanes.iter().any(|l| c.lanes.lock().unwrap().get(l).map_or(0, Vec::len) < 400 * 1024) {
            p.c_rx.recv().await;
        }
    })
    .await
    .expect("everything arrives");
    for &l in &lanes {
        let got = p.c.lanes.lock().unwrap()[&l].clone();
        let want: Vec<u8> = (0..400_u32).flat_map(|i| message(i, l)).collect();
        assert_eq!(got, want, "lane {l}");
    }
    let counts = p.net.counts();
    assert!(counts.shaped.lost > 0 && counts.reordered > 0, "the run had loss and reordering: {counts:?}");
}

/// Wi-Fi drops for ten seconds (a lid half-closed, a lift): the link is still there after,
/// and what was sent meanwhile arrives.
#[tokio::test(start_paused = true)]
async fn a_blackout_shorter_than_the_idle_timeout_is_ridden_out() {
    let mut p = pair(Faults::over(wifi()), 3).await;
    p.net.blackout(Duration::from_secs(10));
    p.server.send(5, 0, Bytes::from_static(b"during"));
    tokio::time::sleep(Duration::from_secs(12)).await;
    p.server.send(5, 0, Bytes::from_static(b"after!"));
    let c = Arc::clone(&p.c);
    tokio::time::timeout(Duration::from_secs(5), async {
        while c.lanes.lock().unwrap().get(&5).map_or(0, Vec::len) < 12 {
            p.c_rx.recv().await;
        }
    })
    .await
    .expect("both arrive once the path is back");
    assert_eq!(p.c.lanes.lock().unwrap()[&5], b"duringafter!");
    assert_eq!(*p.c.closed.lock().unwrap(), None, "still open");
}

/// A Mac gone for good (asleep, off the tailnet) ends the link within the idle timeout, so the
/// app says so and redials instead of waiting for ever.
#[tokio::test(start_paused = true)]
async fn a_peer_gone_for_good_ends_the_link() {
    let mut p = pair(Faults::over(wifi()), 4).await;
    let start = Instant::now();
    p.net.blackout(Duration::from_secs(600));
    let c = Arc::clone(&p.c);
    tokio::time::timeout(Duration::from_secs(120), async {
        while c.closed.lock().unwrap().is_none() {
            p.c_rx.recv().await;
        }
    })
    .await
    .expect("the link ends");
    let reason = p.c.closed.lock().unwrap().clone().unwrap();
    assert!(reason.is_some(), "an end nobody chose is an error");
    assert!(start.elapsed() <= Duration::from_secs(50), "{:?}", start.elapsed());
}

/// The same seed is the same run, packet for packet; another seed is another run.
#[tokio::test(start_paused = true)]
async fn a_seed_repeats_its_run() {
    async fn run(seed: u64) -> (u64, Vec<Duration>) {
        let mut p = pair(Faults::over(shape::Link { loss: 0.01, ..wifi() }), seed).await;
        let f = flood(&p.server, 4);
        let echoes = type_keys(&mut p, ECHO_PRIORITY).await;
        f.abort();
        p.client.close(0);
        (p.net.digest(), echoes)
    }
    let a = run(21).await;
    let b = run(21).await;
    let c = run(22).await;
    assert_eq!(a, b);
    assert_ne!(a.0, c.0);
}

