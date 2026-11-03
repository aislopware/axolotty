// Axolotty's link: plaintext QUIC over a tailnet (Rust/axquic). Every call is non-blocking and
// thread-safe; callbacks run on the library's own threads.
#ifndef AXQUIC_H
#define AXQUIC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct AxqEndpoint AxqEndpoint;
typedef struct AxqLink AxqLink;

/// A lane's bytes, in order within the lane.
typedef void (*AxqDataFn)(void *ctx, uint32_t lane, const uint8_t *bytes, size_t len);
/// The link's end, once and last: `reason` NULL when either side closed it on purpose.
typedef void (*AxqClosedFn)(void *ctx, const char *reason);
/// A link accepted or dialled (`text` the peer's address), or NULL with `text` the reason.
typedef void (*AxqLinkFn)(void *ctx, AxqLink *link, const char *text);

/// Binds `address` ("::" for all) and `port` (0 for any); NULL with `err` filled on failure.
AxqEndpoint *axq_endpoint_bind(const char *address, uint16_t port, bool server, char *err, size_t err_cap);
uint16_t axq_endpoint_port(const AxqEndpoint *ep);
/// Accepts links until closed. `ctx` must outlive the endpoint.
void axq_endpoint_listen(AxqEndpoint *ep, void *ctx, AxqLinkFn on_link);
/// Dials `host` (an address or a name, MagicDNS included); `done` is called exactly once.
void axq_endpoint_connect(AxqEndpoint *ep, const char *host, uint16_t port, uint32_t timeout_ms, void *ctx,
                          AxqLinkFn done);
/// Closes every link on the endpoint and frees it.
void axq_endpoint_close(AxqEndpoint *ep);

/// Starts reading; `ctx` must stay valid until `closed` has been called.
void axq_link_start(AxqLink *link, void *ctx, AxqDataFn data, AxqClosedFn closed);
/// Queues bytes on a lane at a send priority (1 echo, 0 control and panes, below 0 bulk).
void axq_link_send(const AxqLink *link, uint32_t lane, int32_t priority, const uint8_t *bytes, size_t len);
size_t axq_link_pending(const AxqLink *link, uint32_t lane);
size_t axq_link_pending_total(const AxqLink *link);
/// Smoothed round trip in microseconds, 0 before the first sample.
uint32_t axq_link_rtt_us(const AxqLink *link);
void axq_link_close(const AxqLink *link, uint32_t code);
void axq_link_free(AxqLink *link);

#endif
