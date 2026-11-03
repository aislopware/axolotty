//! A real link over loopback UDP: both roles, every lane, in order, then a clean close.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use axquic::link::{Link, Sink};
use bytes::Bytes;
use tokio::sync::mpsc;

#[derive(Default)]
struct Got {
    lanes: Mutex<HashMap<u32, Vec<u8>>>,
    closed: Mutex<Option<Option<String>>>,
}

struct Collect(Arc<Got>, mpsc::UnboundedSender<()>);

impl Sink for Collect {
    fn data(&self, lane: u32, bytes: &[u8]) {
        self.0.lanes.lock().unwrap().entry(lane).or_default().extend_from_slice(bytes);
        let _ = self.1.send(());
    }
    fn closed(&self, reason: Option<String>) {
        *self.0.closed.lock().unwrap() = Some(reason);
        let _ = self.1.send(());
    }
}

async fn until(rx: &mut mpsc::UnboundedReceiver<()>, mut done: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while !done() {
            rx.recv().await;
        }
    })
    .await
    .expect("in time");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn lanes_cross_in_order_and_the_link_closes_cleanly() {
    let any = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), 0);
    let server = axquic::transport::bind(any, true).unwrap();
    let client = axquic::transport::bind(any, false).unwrap();
    let port = server.local_addr().unwrap().port();
    let rt = tokio::runtime::Handle::current();

    let accept = tokio::spawn({
        let server = server.clone();
        let rt = rt.clone();
        async move { Link::server(server.accept().await.unwrap().await.unwrap(), rt) }
    });
    let conn = client
        .connect(SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), port), "axolotty")
        .unwrap()
        .await
        .unwrap();
    let c = Link::client(conn, rt.clone()).await.unwrap();
    // The client speaks first, as Axolotty's hello does; the server sees lane 0 with it.
    c.send(0, 0, Bytes::from_static(b"hello"));
    let s = accept.await.unwrap();

    let (ctx, mut crx) = mpsc::unbounded_channel();
    let (stx, mut srx) = mpsc::unbounded_channel();
    let cgot = Arc::new(Got::default());
    let sgot = Arc::new(Got::default());
    c.start(Arc::new(Collect(Arc::clone(&cgot), ctx)));
    s.start(Arc::new(Collect(Arc::clone(&sgot), stx)));

    // Server → client on lane 0 and three pane lanes, interleaved; one lane far larger.
    s.send(0, 0, Bytes::from_static(b"welcome"));
    let big: Vec<u8> = (0..2_000_000_u32).map(|i| (i % 251) as u8).collect();
    for chunk in big.chunks(50_000) {
        s.send(7, 0, Bytes::copy_from_slice(chunk));
        s.send(9, 1, Bytes::from_static(b"k"));
    }
    s.send(11, 0, Bytes::from_static(b"last"));
    until(&mut crx, || {
        let l = cgot.lanes.lock().unwrap();
        l.get(&7).map_or(0, Vec::len) == big.len() && l.get(&11).is_some() && l.get(&9).map_or(0, Vec::len) == 40
    })
    .await;
    {
        let l = cgot.lanes.lock().unwrap();
        assert_eq!(l[&0], b"welcome");
        assert_eq!(l[&7], big, "a lane's bytes arrive whole and in order");
        assert_eq!(l[&9], vec![b'k'; 40]);
        assert_eq!(l[&11], b"last");
    }
    until(&mut srx, || sgot.lanes.lock().unwrap().get(&0).is_some()).await;
    assert_eq!(sgot.lanes.lock().unwrap()[&0], b"hello");
    assert_eq!(s.pending_total(), 0);
    assert!(c.rtt().is_some());

    c.close(0);
    until(&mut srx, || sgot.closed.lock().unwrap().is_some()).await;
    until(&mut crx, || cgot.closed.lock().unwrap().is_some()).await;
    assert_eq!(*sgot.closed.lock().unwrap(), Some(None), "closed on purpose is no error");
    assert_eq!(*cgot.closed.lock().unwrap(), Some(None));
}
