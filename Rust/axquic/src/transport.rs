//! The transport config every link runs and the UDP socket it runs on, after Slopty's
//! `slopty-net::endpoint` (MIT), where each value was measured (Slopty's MEASUREMENTS.md).

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use noq::{AckFrequencyConfig, Endpoint, IdleTimeout, Runtime as _, TransportConfig, VarInt};

/// Keep-alive: an idle link still carries a ping and its ACK each second, so a peer that stops
/// answering is noticed in seconds, NAT bindings live and the round trip stays measured.
pub const KEEP_ALIVE: Duration = Duration::from_secs(1);
/// Silence after which a link is dropped. Generous: a laptop's radio gap or a sleep is ridden
/// out by QUIC migration and Axolotty's own redial.
const IDLE_TIMEOUT: Duration = Duration::from_secs(45);
/// Longest the peer may sit on an ACK (QUIC's default is 25 ms): the window turns at the
/// path's round trip, and a lone echo is acknowledged before the next key.
const MAX_ACK_DELAY: Duration = Duration::from_millis(2);
/// The round trip assumed before the first sample: every path here is a LAN or a tailnet a few
/// milliseconds long, not RFC 9002's unknown Internet path of 333 ms.
const INITIAL_RTT: Duration = Duration::from_millis(5);
/// Every packet's UDP payload: 1280, Tailscale's TUN MTU and the least IPv6 carries, less 48
/// bytes of IPv6 and UDP header. Nothing to discover on a tailnet.
pub const PATH_MTU: u16 = 1232;
/// What every QUIC path must carry, where black-hole detection falls back to.
const MIN_MTU: u16 = 1200;
/// The socket's receive buffer; macOS's default (768 KiB) overflows when a burst lands while
/// the endpoint's task is late.
const RECEIVE_BUFFER: usize = 4 << 20;
/// Datagram buffers (the echo copies are small; this bounds a burst of them).
const DATAGRAM_BUFFER: usize = 1 << 20;
/// Initial congestion window in packets: a LAN or a tailnet affords Chromium's burst, and the
/// first screenful of a pane is tens of kilobytes.
const INITIAL_WINDOW_PACKETS: u64 = 32;
/// Streams each way at once: a pane's output, a tunnel's connections (a browser opens six per
/// origin), a file each.
pub const MAX_STREAMS: u32 = 1024;

/// Lowest send priority that goes ahead of queued datagrams: control and pane streams.
pub const AHEAD_OF_DATAGRAMS: i32 = 0;
/// A stream while it carries an echo: it leaves in the next packet, ahead of every other
/// stream and unpaced (Slopty: p99 beside six flooding sessions 30–73 → 11–25 ms).
pub const ECHO_PRIORITY: i32 = 1;

/// The transport config shared by both roles. Congestion control is BBR3 held to twice the
/// measured bandwidth-delay product (`congestion`): Cubic cut its window to a few packets on
/// Wi-Fi's real losses, and unbounded BBR3 filled the bottleneck's queue ahead of an echo.
pub fn transport_config(seed: Option<u64>) -> TransportConfig {
    let mut acks = AckFrequencyConfig::default();
    acks.max_ack_delay(Some(MAX_ACK_DELAY));
    let mut bbr = noq::congestion::Bbr3Config::default();
    bbr.initial_window(INITIAL_WINDOW_PACKETS * 1200);
    bbr.probe_rng_seed(seed.map(spread_seed));
    let mut config = TransportConfig::default();
    config
        .congestion_controller_factory(Arc::new(crate::congestion::BoundedFactory::new(
            Arc::new(bbr),
            Some(crate::congestion::CEILING_BDPS),
        )))
        .ack_frequency_config(Some(acks))
        .initial_rtt(INITIAL_RTT)
        .initial_mtu(PATH_MTU)
        .min_mtu(MIN_MTU)
        .mtu_discovery_config(None)
        .max_idle_timeout(IdleTimeout::try_from(IDLE_TIMEOUT).ok())
        .keep_alive_interval(Some(KEEP_ALIVE))
        .datagram_receive_buffer_size(Some(DATAGRAM_BUFFER))
        .datagram_send_buffer_size(DATAGRAM_BUFFER)
        .max_concurrent_bidi_streams(VarInt::from_u32(MAX_STREAMS))
        .max_concurrent_uni_streams(VarInt::from_u32(MAX_STREAMS))
        .stream_priority_before_datagrams(Some(AHEAD_OF_DATAGRAMS))
        .stream_priority_unpaced(Some(ECHO_PRIORITY));
    config
}

/// Seeds noq's own draws from one number, so a seeded run repeats.
pub fn spread_seed<const N: usize>(seed: u64) -> [u8; N] {
    let mut bytes = [0_u8; N];
    for (chunk, word) in bytes.chunks_mut(8).zip(0_u64..) {
        let mixed = seed ^ word.wrapping_mul(0x9e37_79b9_7f4a_7c15);
        for (byte, from) in chunk.iter_mut().zip(mixed.to_le_bytes()) {
            *byte = from;
        }
    }
    bytes
}

/// A QUIC endpoint on `local`; with `server` it also accepts. Must run inside the runtime.
pub fn bind(local: SocketAddr, server: bool) -> std::io::Result<Endpoint> {
    let socket = bind_udp(local)?;
    let socket = noq::TokioRuntime.wrap_udp_socket(socket.into())?;
    endpoint_on(socket, server, None)
}

/// An endpoint on any socket noq can drive: the OS's, or a simulated network's in tests.
pub fn endpoint_on(
    socket: Box<dyn noq::AsyncUdpSocket>,
    server: bool,
    seed: Option<u64>,
) -> std::io::Result<Endpoint> {
    let transport = Arc::new(transport_config(seed));
    let mut endpoint_config = crate::crypto::endpoint_config();
    endpoint_config.rng_seed(seed.map(spread_seed));
    let server_config = server.then(|| {
        let mut config = crate::crypto::server_config();
        config.transport_config(Arc::clone(&transport));
        config
    });
    let endpoint = Endpoint::new_with_abstract_socket(
        endpoint_config,
        server_config,
        socket,
        Arc::new(noq::TokioRuntime),
    )?;
    let mut client = crate::crypto::client_config();
    client.transport_config(transport);
    endpoint.set_default_client_config(client);
    Ok(endpoint)
}

/// A UDP socket on `local`, dual-stack when it is IPv6, with a 4 MiB receive buffer. An address
/// in use is an error: a client knows the server by its port.
fn bind_udp(local: SocketAddr) -> std::io::Result<socket2::Socket> {
    let socket = socket2::Socket::new(
        socket2::Domain::for_address(local),
        socket2::Type::DGRAM,
        Some(socket2::Protocol::UDP),
    )?;
    if local.is_ipv6() {
        socket.set_only_v6(false)?;
    }
    // The OS clamps what it grants to kern.ipc.maxsockbuf and says nothing; less is still a link.
    let _ = socket.set_recv_buffer_size(RECEIVE_BUFFER);
    socket.bind(&local.into())?;
    Ok(socket)
}
