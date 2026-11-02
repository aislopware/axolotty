// Descriptor passing and the shared journal ring.
#include "AxSys.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

int ax_send_fds(int sock, const void *buf, size_t len, const int *fds, int nfds) {
  if (nfds < 0 || nfds > 4) return EINVAL;
  struct iovec iov = {.iov_base = (void *)buf, .iov_len = len};
  union {
    struct cmsghdr h;
    char space[CMSG_SPACE(sizeof(int) * 4)];
  } ctl;
  memset(&ctl, 0, sizeof(ctl));
  struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1};
  if (nfds > 0) {
    msg.msg_control = ctl.space;
    msg.msg_controllen = (socklen_t)CMSG_SPACE(sizeof(int) * (size_t)nfds);
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET;
    c->cmsg_type = SCM_RIGHTS;
    c->cmsg_len = (socklen_t)CMSG_LEN(sizeof(int) * (size_t)nfds);
    memcpy(CMSG_DATA(c), fds, sizeof(int) * (size_t)nfds);
  }
  size_t sent = 0;
  while (sent < len) {
    ssize_t n = sendmsg(sock, &msg, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      return errno;
    }
    sent += (size_t)n;
    // Descriptors travel with the first byte only.
    iov.iov_base = (char *)buf + sent;
    iov.iov_len = len - sent;
    msg.msg_control = NULL;
    msg.msg_controllen = 0;
  }
  return 0;
}

ssize_t ax_recv_fds(int sock, void *buf, size_t cap, int *fds, int max_fds, int *nfds) {
  struct iovec iov = {.iov_base = buf, .iov_len = cap};
  union {
    struct cmsghdr h;
    char space[CMSG_SPACE(sizeof(int) * 8)];
  } ctl;
  struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctl.space,
                       .msg_controllen = sizeof(ctl.space)};
  ssize_t n;
  do {
    n = recvmsg(sock, &msg, 0);
  } while (n < 0 && errno == EINTR);
  if (nfds) *nfds = 0;
  if (n < 0) return -errno;
  for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c; c = CMSG_NXTHDR(&msg, c)) {
    if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS) continue;
    int count = (int)((c->cmsg_len - CMSG_LEN(0)) / sizeof(int));
    int *got = (int *)(void *)CMSG_DATA(c);
    for (int i = 0; i < count; i++) {
      int fd = got[i];
      fcntl(fd, F_SETFD, FD_CLOEXEC);
      if (fds && nfds && *nfds < max_fds) fds[(*nfds)++] = fd;
      else close(fd);
    }
  }
  return n;
}

int ax_ring_create(const char *dir, uint64_t capacity) {
  char path[1024];
  for (int attempt = 0; attempt < 16; attempt++) {
    snprintf(path, sizeof(path), "%s/.ring-%d-%u", dir, getpid(), arc4random());
    int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) {
      if (errno == EEXIST) continue;
      return -errno;
    }
    unlink(path);
    if (ftruncate(fd, (off_t)(sizeof(ax_ring_header) + capacity)) != 0) {
      int e = errno;
      close(fd);
      return -e;
    }
    ax_ring_header h = {.magic = AX_RING_MAGIC, .version = 1, .capacity = capacity, .head = 0};
    if (pwrite(fd, &h, sizeof(h), 0) != (ssize_t)sizeof(h)) {
      int e = errno;
      close(fd);
      return -e;
    }
    return fd;
  }
  return -EEXIST;
}

void *ax_ring_map(int fd, size_t *size) {
  struct stat st;
  if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(ax_ring_header)) return NULL;
  void *p = mmap(NULL, (size_t)st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (p == MAP_FAILED) return NULL;
  const ax_ring_header *h = p;
  if (h->magic != AX_RING_MAGIC || h->version != 1 ||
      h->capacity + sizeof(ax_ring_header) != (uint64_t)st.st_size) {
    munmap(p, (size_t)st.st_size);
    return NULL;
  }
  if (size) *size = (size_t)st.st_size;
  return p;
}

static inline _Atomic uint64_t *head_ptr(const void *ring) {
  return (_Atomic uint64_t *)(void *)&((ax_ring_header *)(uintptr_t)ring)->head;
}

uint64_t ax_ring_head(const void *ring) {
  return atomic_load_explicit(head_ptr(ring), memory_order_acquire);
}

uint64_t ax_ring_tail(const void *ring) {
  const ax_ring_header *h = ring;
  uint64_t head = ax_ring_head(ring);
  return head > h->capacity ? head - h->capacity : 0;
}

uint64_t ax_ring_append(void *ring, const void *bytes, size_t len) {
  ax_ring_header *h = ring;
  uint8_t *data = (uint8_t *)ring + sizeof(ax_ring_header);
  uint64_t head = atomic_load_explicit(head_ptr(ring), memory_order_relaxed);
  const uint8_t *src = bytes;
  // Only the newest `capacity` bytes can survive anyway.
  if (len > h->capacity) {
    src += len - h->capacity;
    head += len - h->capacity;
    len = (size_t)h->capacity;
  }
  size_t at = (size_t)(head % h->capacity);
  size_t first = len < h->capacity - at ? len : (size_t)(h->capacity - at);
  memcpy(data + at, src, first);
  if (first < len) memcpy(data, src + first, len - first);
  atomic_store_explicit(head_ptr(ring), head + len, memory_order_release);
  return head + len;
}

ssize_t ax_ring_read(const void *ring, uint64_t from, void *out, size_t cap) {
  const ax_ring_header *h = ring;
  const uint8_t *data = (const uint8_t *)ring + sizeof(ax_ring_header);
  uint64_t head = ax_ring_head(ring);
  if (from > head || head - from > h->capacity) return -1;
  size_t len = (size_t)(head - from);
  if (len > cap) len = cap;
  size_t at = (size_t)(from % h->capacity);
  size_t first = len < h->capacity - at ? len : (size_t)(h->capacity - at);
  memcpy(out, data + at, first);
  if (first < len) memcpy((uint8_t *)out + first, data, len - first);
  // A concurrent writer may have lapped us while copying.
  if (ax_ring_head(ring) - from > h->capacity) return -1;
  return (ssize_t)len;
}
