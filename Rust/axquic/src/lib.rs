//! Axolotty's link to a host: plaintext QUIC over a tailnet, for Swift through a C ABI
//! (`include/axquic.h`).
//!
//! Tailscale (or slopscale's tailnet) already finds the path, crosses NATs, encrypts and
//! authenticates; this layer only carries Axolotty's lanes with the least delay a key's echo
//! can have. The QUIC stack and its tuning are Slopty's (`crypto`, `transport`, `congestion`).

pub mod congestion;
pub mod crypto;
pub mod link;
pub mod transport;

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use bytes::Bytes;
use link::{Link, Sink};
use tokio::runtime::Runtime;

/// The process's QUIC runtime: two threads at user-interactive QoS, so a keystroke is never
/// queued behind a background thread on a busy Mac (Slopty: worker p90 5–6 → 0.2–0.5 ms under an
/// all-core spin).
fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("axquic")
            .on_thread_start(interactive)
            .enable_all()
            .build()
            .expect("the QUIC runtime starts")
    })
}

#[cfg(target_vendor = "apple")]
fn interactive() {
    // SAFETY: sets the calling thread's own QoS class.
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
}

#[cfg(not(target_vendor = "apple"))]
fn interactive() {}

// MARK: - C ABI

/// A bound UDP socket speaking Axolotty's QUIC.
pub struct AxqEndpoint {
    endpoint: noq::Endpoint,
}

/// One link (connection) to a peer.
pub struct AxqLink {
    link: Link,
}

/// A raw context pointer the Swift side owns; it outlives every call made with it.
#[derive(Clone, Copy)]
struct Ctx(*mut c_void);
// SAFETY: the Swift side guarantees the object behind it is thread-safe and alive while used.
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

pub type AxqDataFn = extern "C" fn(ctx: *mut c_void, lane: u32, bytes: *const u8, len: usize);
pub type AxqClosedFn = extern "C" fn(ctx: *mut c_void, reason: *const c_char);
pub type AxqLinkFn = extern "C" fn(ctx: *mut c_void, link: *mut AxqLink, text: *const c_char);

fn write_err(out: *mut c_char, cap: usize, msg: &str) {
    if out.is_null() || cap == 0 {
        return;
    }
    let bytes = msg.as_bytes();
    let n = bytes.len().min(cap - 1);
    // SAFETY: the caller gave `cap` writable bytes at `out`.
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out.cast::<u8>(), n);
        *out.add(n) = 0;
    }
}

fn c_text(s: &str) -> CString {
    CString::new(s.replace('\0', " ")).unwrap_or_default()
}

/// Binds `address:port` (an IP; "::" for every address). With `server`, the endpoint also
/// accepts. NULL on failure, with the reason in `err`.
///
/// # Safety
/// `address` is a NUL-terminated string; `err` has `err_cap` writable bytes or is NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_endpoint_bind(
    address: *const c_char,
    port: u16,
    server: bool,
    err: *mut c_char,
    err_cap: usize,
) -> *mut AxqEndpoint {
    // SAFETY: per the contract above.
    let text = unsafe { CStr::from_ptr(address) }.to_string_lossy().into_owned();
    let Ok(ip) = text.parse::<IpAddr>() else {
        write_err(err, err_cap, &format!("not an address: {text}"));
        return std::ptr::null_mut();
    };
    let _guard = runtime().enter();
    match transport::bind(SocketAddr::new(ip, port), server) {
        Ok(endpoint) => Box::into_raw(Box::new(AxqEndpoint { endpoint })),
        Err(e) => {
            write_err(err, err_cap, &e.to_string());
            std::ptr::null_mut()
        }
    }
}

/// The port the endpoint is bound to (useful after binding port 0).
///
/// # Safety
/// `ep` came from `axq_endpoint_bind` and is not yet closed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_endpoint_port(ep: *const AxqEndpoint) -> u16 {
    // SAFETY: per the contract above.
    unsafe { &*ep }.endpoint.local_addr().map_or(0, |a| a.port())
}

/// Accepts links until the endpoint closes: `on_link(ctx, link, peer address)` for each.
///
/// # Safety
/// `ep` is live; `ctx` stays valid until `axq_endpoint_close`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_endpoint_listen(ep: *mut AxqEndpoint, ctx: *mut c_void, on_link: AxqLinkFn) {
    // SAFETY: per the contract above.
    let endpoint = unsafe { &*ep }.endpoint.clone();
    let ctx = Ctx(ctx);
    let rt = runtime().handle().clone();
    runtime().spawn(async move {
        while let Some(incoming) = endpoint.accept().await {
            let rt = rt.clone();
            tokio::spawn(async move {
                let Ok(conn) = incoming.await else { return };
                let link = Link::server(conn, rt);
                let peer = c_text(&link.peer().map(|a| a.to_string()).unwrap_or_default());
                let ctx = ctx;
                on_link(ctx.0, Box::into_raw(Box::new(AxqLink { link })), peer.as_ptr());
            });
        }
    });
}

/// Dials `host:port` (an address or a name the system resolves, MagicDNS included) and calls
/// `done(ctx, link, NULL)`, or `done(ctx, NULL, why)` if it fails or takes past `timeout_ms`.
///
/// # Safety
/// `ep` is live and `host` NUL-terminated; `ctx` stays valid until `done` is called.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_endpoint_connect(
    ep: *mut AxqEndpoint,
    host: *const c_char,
    port: u16,
    timeout_ms: u32,
    ctx: *mut c_void,
    done: AxqLinkFn,
) {
    // SAFETY: per the contract above.
    let endpoint = unsafe { &*ep }.endpoint.clone();
    // SAFETY: per the contract above.
    let host = unsafe { CStr::from_ptr(host) }.to_string_lossy().into_owned();
    let ctx = Ctx(ctx);
    let rt = runtime().handle().clone();
    runtime().spawn(async move {
        let ctx = ctx;
        let dial = async {
            let addrs: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), port))
                .await
                .map_err(|e| format!("can't resolve {host}: {e}"))?
                .collect();
            // A tailnet name resolves to its IPv4 and IPv6; IPv4 first, as ssh would.
            let addr = addrs
                .iter()
                .find(|a| a.is_ipv4())
                .or_else(|| addrs.first())
                .copied()
                .ok_or_else(|| format!("{host} has no address"))?;
            let addr = match (endpoint.local_addr().map(|l| l.is_ipv6()), addr) {
                (Ok(true), SocketAddr::V4(v4)) => SocketAddr::new(IpAddr::V6(v4.ip().to_ipv6_mapped()), v4.port()),
                (_, a) => a,
            };
            let conn = endpoint
                .connect(addr, "axolotty")
                .map_err(|e| e.to_string())?
                .await
                .map_err(|e| e.to_string())?;
            Link::client(conn, rt).await.map_err(|e| e.to_string())
        };
        match tokio::time::timeout(Duration::from_millis(u64::from(timeout_ms)), dial).await {
            Ok(Ok(link)) => done(ctx.0, Box::into_raw(Box::new(AxqLink { link })), std::ptr::null()),
            Ok(Err(why)) => done(ctx.0, std::ptr::null_mut(), c_text(&why).as_ptr()),
            Err(_) => done(ctx.0, std::ptr::null_mut(), c_text("timed out").as_ptr()),
        }
    });
}

/// Closes the endpoint (every link on it) and frees it.
///
/// # Safety
/// `ep` came from `axq_endpoint_bind`; it is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_endpoint_close(ep: *mut AxqEndpoint) {
    // SAFETY: per the contract above.
    let ep = unsafe { Box::from_raw(ep) };
    ep.endpoint.close(noq::VarInt::from_u32(0), b"");
}

struct CSink {
    ctx: Ctx,
    data: AxqDataFn,
    copy: Option<AxqDataFn>,
    closed: AxqClosedFn,
}

impl Sink for CSink {
    fn data(&self, lane: u32, bytes: &[u8]) {
        (self.data)(self.ctx.0, lane, bytes.as_ptr(), bytes.len());
    }
    fn copy(&self, lane: u32, bytes: &[u8]) {
        if let Some(copy) = self.copy {
            copy(self.ctx.0, lane, bytes.as_ptr(), bytes.len());
        }
    }
    fn closed(&self, reason: Option<String>) {
        match reason {
            None => (self.closed)(self.ctx.0, std::ptr::null()),
            Some(r) => (self.closed)(self.ctx.0, c_text(&r).as_ptr()),
        }
    }
}

/// Starts reading: `data(ctx, lane, bytes, len)` per chunk (in order within a lane),
/// `copy(ctx, lane, bytes, len)` per datagram copy (if not NULL; whole frames, unordered), then
/// `closed(ctx, reason or NULL)` once; nothing after it.
///
/// # Safety
/// `link` is live; `ctx` stays valid until `closed` is called.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_link_start(
    link: *mut AxqLink,
    ctx: *mut c_void,
    data: AxqDataFn,
    copy: Option<AxqDataFn>,
    closed: AxqClosedFn,
) {
    // SAFETY: per the contract above.
    let link = &unsafe { &*link }.link;
    let _guard = runtime().enter();
    link.start(Arc::new(CSink { ctx: Ctx(ctx), data, copy, closed }));
}

/// Sends `len` bytes, already sent on `lane`, again as a datagram a moment later, when the path
/// takes it and the datagram queue is nearly empty.
///
/// # Safety
/// `link` is live; `bytes` has `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_link_copy(link: *const AxqLink, lane: u32, bytes: *const u8, len: usize) {
    if len == 0 {
        return;
    }
    // SAFETY: per the contract above.
    let data = unsafe { std::slice::from_raw_parts(bytes, len) };
    let _guard = runtime().enter();
    // SAFETY: per the contract above.
    unsafe { &*link }.link.copy(lane, data);
}

/// Queues `len` bytes on `lane` at `priority`; never blocks.
///
/// # Safety
/// `link` is live; `bytes` has `len` readable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_link_send(link: *const AxqLink, lane: u32, priority: i32, bytes: *const u8, len: usize) {
    if len == 0 {
        return;
    }
    // SAFETY: per the contract above.
    let data = Bytes::copy_from_slice(unsafe { std::slice::from_raw_parts(bytes, len) });
    let _guard = runtime().enter();
    // SAFETY: per the contract above.
    unsafe { &*link }.link.send(lane, priority, data);
}

/// Bytes queued on `lane` and not yet in QUIC's send buffer.
///
/// # Safety
/// `link` is live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_link_pending(link: *const AxqLink, lane: u32) -> usize {
    // SAFETY: per the contract above.
    unsafe { &*link }.link.pending(lane)
}

/// Bytes queued on every lane.
///
/// # Safety
/// `link` is live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_link_pending_total(link: *const AxqLink) -> usize {
    // SAFETY: per the contract above.
    unsafe { &*link }.link.pending_total()
}

/// The path's smoothed round trip in microseconds; 0 before the first sample.
///
/// # Safety
/// `link` is live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_link_rtt_us(link: *const AxqLink) -> u32 {
    // SAFETY: per the contract above.
    unsafe { &*link }.link.rtt().map_or(0, |d| u32::try_from(d.as_micros()).unwrap_or(u32::MAX))
}

/// The path's bandwidth as the congestion controller estimates it, bytes per second; 0 until
/// the link has written enough to measure it.
///
/// # Safety
/// `link` is live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_link_bandwidth(link: *const AxqLink) -> u64 {
    // SAFETY: per the contract above.
    unsafe { &*link }.link.bandwidth().unwrap_or(0)
}

/// Ends the link (the sink hears `closed(NULL)`); it may still be freed only by `axq_link_free`.
///
/// # Safety
/// `link` is live.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_link_close(link: *const AxqLink, code: u32) {
    // SAFETY: per the contract above.
    unsafe { &*link }.link.close(code);
}

/// Frees the handle (closing the link if nothing else holds it).
///
/// # Safety
/// `link` came from this library and is not used again.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn axq_link_free(link: *mut AxqLink) {
    // SAFETY: per the contract above.
    drop(unsafe { Box::from_raw(link) });
}
