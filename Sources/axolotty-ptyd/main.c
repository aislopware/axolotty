// axolotty-ptyd — holds every pseudo-terminal and child process so that
// restarting or updating the server or the app never kills a running program.
//
// It never parses terminal output and knows nothing about clients. It spawns,
// passes master descriptors to the server (SCM_RIGHTS), drains output into each
// session's journal ring while no server is attached, and reports exits.
// One process, one kqueue loop, no threads.
//
// Usage: axolotty-ptyd --socket PATH --lock PATH --ring-dir DIR [--ring-bytes N] [--watch-pid PID]
//
// --watch-pid ties the holder's life to another process (tests: a crashed test
// run must not leave holders behind). Production never passes it.
#include "AxCustody.h"
#include "AxSys.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>

typedef struct {
  uint8_t id[16];
  pid_t pid;
  int master;
  int ring_fd;
  void *ring;
  size_t ring_size;
  int attached; ///< connection fd holding the reader role, or -1
  bool draining;
  bool eof;
  int32_t status; ///< AXC_ALIVE while running
  bool adopted;
} session;

typedef struct {
  int fd;
  uint8_t *buf;
  size_t len, cap;
  int fdq[16];
  int nfdq;
} conn;

static int kq = -1;
static session *sessions;
static size_t nsessions, capsessions;
static conn *conns;
static size_t nconns, capconns;
static const char *ring_dir;
static uint64_t ring_bytes = 8u << 20;
static int listen_fd = -1;
static pid_t watch_pid = 0;

// ---------------------------------------------------------------- utilities

static void put_u32(uint8_t **p, uint32_t v) { memcpy(*p, &v, 4); *p += 4; }
static void put_i32(uint8_t **p, int32_t v) { memcpy(*p, &v, 4); *p += 4; }
static void put_id(uint8_t **p, const uint8_t id[16]) { memcpy(*p, id, 16); *p += 16; }

static bool take(const uint8_t **p, const uint8_t *end, void *out, size_t n) {
  if ((size_t)(end - *p) < n) return false;
  memcpy(out, *p, n);
  *p += n;
  return true;
}

static void send_msg(int fd, uint8_t op, const uint8_t *payload, size_t len, const int *fds, int nfds) {
  uint8_t *m = malloc(6 + len);
  if (!m) return;
  uint32_t l = (uint32_t)(2 + len);
  memcpy(m, &l, 4);
  m[4] = op;
  m[5] = (uint8_t)nfds;
  if (len) memcpy(m + 6, payload, len);
  if (ax_send_fds(fd, m, 6 + len, fds, nfds) != 0) syslog(LOG_WARNING, "ptyd: send failed: %m");
  free(m);
}

static void result(int fd, const uint8_t id[16], int32_t err) {
  uint8_t b[20], *p = b;
  put_id(&p, id);
  put_i32(&p, err);
  send_msg(fd, AXC_RESULT, b, sizeof(b), NULL, 0);
}

static session *find(const uint8_t id[16]) {
  for (size_t i = 0; i < nsessions; i++)
    if (memcmp(sessions[i].id, id, 16) == 0) return &sessions[i];
  return NULL;
}

static void watch_read(session *s, bool on) {
  if (s->eof || s->master < 0 || s->draining == on) return;
  struct kevent ev;
  EV_SET(&ev, s->master, EVFILT_READ, on ? EV_ADD : EV_DELETE, 0, 0, NULL);
  kevent(kq, &ev, 1, NULL, 0, NULL);
  s->draining = on;
}

// Children that exited before kqueue could watch them; reaped after the
// current event batch so the EXITED event always follows the SPAWN reply.
static pid_t pending_exits[64];
static int npending_exits;

static void watch_exit(pid_t pid) {
  struct kevent ev;
  EV_SET(&ev, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT | NOTE_EXITSTATUS, 0, NULL);
  if (kevent(kq, &ev, 1, NULL, 0, NULL) != 0 && errno == ESRCH &&
      npending_exits < (int)(sizeof(pending_exits) / sizeof(pending_exits[0])))
    pending_exits[npending_exits++] = pid;
}

static void broadcast_exit(const uint8_t id[16], int32_t status) {
  uint8_t b[20], *p = b;
  put_id(&p, id);
  put_i32(&p, status);
  for (size_t i = 0; i < nconns; i++) send_msg(conns[i].fd, AXC_EXITED, b, sizeof(b), NULL, 0);
}

static void drop_session(session *s) {
  watch_read(s, false);
  if (s->status == AXC_ALIVE && s->pid > 0) kill(-s->pid, SIGHUP);
  if (s->master >= 0) close(s->master);
  if (s->ring) munmap(s->ring, s->ring_size);
  if (s->ring_fd >= 0) close(s->ring_fd);
  size_t i = (size_t)(s - sessions);
  sessions[i] = sessions[--nsessions];
}

static session *add_session(void) {
  if (nsessions == capsessions) {
    size_t cap = capsessions ? capsessions * 2 : 16;
    session *n = realloc(sessions, cap * sizeof(session));
    if (!n) return NULL;
    sessions = n;
    capsessions = cap;
  }
  session *s = &sessions[nsessions++];
  memset(s, 0, sizeof(*s));
  s->master = s->ring_fd = s->attached = -1;
  s->status = AXC_ALIVE;
  return s;
}

// ---------------------------------------------------------------- verbs

static void on_spawn(conn *c, const uint8_t *p, const uint8_t *end) {
  uint8_t id[16];
  uint16_t cols, rows, wpx, hpx;
  uint32_t argc, envc;
  if (!take(&p, end, id, 16) || !take(&p, end, &cols, 2) || !take(&p, end, &rows, 2) ||
      !take(&p, end, &wpx, 2) || !take(&p, end, &hpx, 2) || !take(&p, end, &argc, 4) ||
      !take(&p, end, &envc, 4) || argc == 0 || argc > 4096 || envc > 4096) {
    uint8_t zero[16] = {0};
    result(c->fd, zero, EINVAL);
    return;
  }
  // Strings: path, cwd, argv…, env… — point into the payload (NUL-terminated).
  size_t want = 2 + argc + envc;
  const char **strs = calloc(want, sizeof(char *));
  char **argv = calloc(argc + 1, sizeof(char *));
  char **envp = calloc(envc + 1, sizeof(char *));
  int32_t err = (!strs || !argv || !envp) ? ENOMEM : 0;
  for (size_t i = 0; !err && i < want; i++) {
    const uint8_t *nul = memchr(p, 0, (size_t)(end - p));
    if (!nul) {
      err = EINVAL;
      break;
    }
    strs[i] = (const char *)p;
    p = nul + 1;
  }
  int32_t pid = 0;
  int fds[2] = {-1, -1};
  if (!err && find(id)) err = EEXIST;
  if (!err) {
    for (uint32_t i = 0; i < argc; i++) argv[i] = (char *)strs[2 + i];
    for (uint32_t i = 0; i < envc; i++) envp[i] = (char *)strs[2 + argc + i];
    int ring_fd = ax_ring_create(ring_dir, ring_bytes);
    if (ring_fd < 0) err = -ring_fd;
    ax_pty_child child = {0};
    if (!err) {
      ax_winsize ws = {.cols = cols, .rows = rows, .width_px = wpx, .height_px = hpx};
      err = ax_pty_spawn(strs[0], argv, envp, strs[1][0] ? strs[1] : NULL, ws, &child);
      if (err) close(ring_fd);
    }
    session *s = err ? NULL : add_session();
    if (!err && !s) err = ENOMEM;
    if (!err) {
      memcpy(s->id, id, 16);
      s->pid = child.pid;
      s->master = child.master_fd;
      s->ring_fd = ring_fd;
      s->ring = ax_ring_map(ring_fd, &s->ring_size);
      pid = child.pid;
      watch_exit(child.pid);
      // The spawner takes the reader role straight away.
      s->attached = c->fd;
      fds[0] = s->master;
      fds[1] = s->ring_fd;
    }
  }
  uint8_t b[24], *q = b;
  put_id(&q, id);
  put_i32(&q, err);
  put_i32(&q, pid);
  send_msg(c->fd, AXC_SPAWN, b, sizeof(b), err ? NULL : fds, err ? 0 : 2);
  free(strs);
  free(argv);
  free(envp);
}

static void on_attach(conn *c, const uint8_t *p, const uint8_t *end) {
  uint8_t id[16];
  if (!take(&p, end, id, 16)) return;
  session *s = find(id);
  uint8_t b[28], *q = b;
  put_id(&q, id);
  if (!s) {
    put_i32(&q, ENOENT);
    put_i32(&q, 0);
    put_i32(&q, 0);
    send_msg(c->fd, AXC_ATTACH, b, sizeof(b), NULL, 0);
    return;
  }
  watch_read(s, false); // stop draining before the new reader starts
  s->attached = c->fd;
  put_i32(&q, 0);
  put_i32(&q, s->pid);
  put_i32(&q, s->status);
  int fds[2] = {s->master, s->ring_fd};
  send_msg(c->fd, AXC_ATTACH, b, sizeof(b), fds, 2);
}

static void release(session *s) {
  s->attached = -1;
  watch_read(s, true);
}

static void on_release(conn *c, const uint8_t *p, const uint8_t *end) {
  uint8_t id[16];
  if (!take(&p, end, id, 16)) return;
  session *s = find(id);
  if (s && s->attached == c->fd) release(s);
}

static void on_signal(conn *c, const uint8_t *p, const uint8_t *end) {
  uint8_t id[16];
  int32_t sig;
  uint8_t fg;
  if (!take(&p, end, id, 16) || !take(&p, end, &sig, 4) || !take(&p, end, &fg, 1)) return;
  session *s = find(id);
  int32_t err = 0;
  if (!s || s->status != AXC_ALIVE) err = ESRCH;
  else {
    pid_t target = fg ? ax_pty_foreground_pgid(s->master) : s->pid;
    if (target <= 0) target = s->pid;
    if (kill(fg ? -target : target, sig) != 0) err = errno;
  }
  result(c->fd, id, err);
}

static void on_close(conn *c, const uint8_t *p, const uint8_t *end) {
  uint8_t id[16];
  if (!take(&p, end, id, 16)) return;
  session *s = find(id);
  if (s) drop_session(s);
  result(c->fd, id, s ? 0 : ENOENT);
}

static void on_list(conn *c) {
  size_t len = 4 + nsessions * 25;
  uint8_t *b = malloc(len), *q = b;
  if (!b) return;
  put_u32(&q, (uint32_t)nsessions);
  for (size_t i = 0; i < nsessions; i++) {
    put_id(&q, sessions[i].id);
    put_i32(&q, sessions[i].pid);
    put_i32(&q, sessions[i].status);
    *q++ = sessions[i].attached >= 0;
  }
  send_msg(c->fd, AXC_LIST, b, len, NULL, 0);
  free(b);
}

static void on_adopt(conn *c, const uint8_t *p, const uint8_t *end, int *fds, int nfds) {
  uint8_t id[16];
  int32_t pid;
  if (!take(&p, end, id, 16) || !take(&p, end, &pid, 4) || nfds != 2) {
    for (int i = 0; i < nfds; i++) close(fds[i]);
    uint8_t zero[16] = {0};
    result(c->fd, zero, EINVAL);
    return;
  }
  if (find(id)) {
    close(fds[0]);
    close(fds[1]);
    result(c->fd, id, EEXIST);
    return;
  }
  session *s = add_session();
  if (!s) {
    close(fds[0]);
    close(fds[1]);
    result(c->fd, id, ENOMEM);
    return;
  }
  memcpy(s->id, id, 16);
  s->pid = pid;
  s->master = fds[0];
  s->ring_fd = fds[1];
  s->ring = ax_ring_map(fds[1], &s->ring_size);
  s->attached = c->fd;
  s->adopted = true;
  watch_exit(pid);
  result(c->fd, id, 0);
}

static void shutdown_all(void) {
  while (nsessions) drop_session(&sessions[0]);
  exit(0);
}

// ---------------------------------------------------------------- connections

static void close_conn(size_t i) {
  int fd = conns[i].fd;
  for (size_t k = 0; k < nsessions; k++)
    if (sessions[k].attached == fd) release(&sessions[k]);
  for (int k = 0; k < conns[i].nfdq; k++) close(conns[i].fdq[k]);
  close(fd);
  free(conns[i].buf);
  conns[i] = conns[--nconns];
}

static void handle(conn *c, uint8_t op, const uint8_t *p, size_t len, int *fds, int nfds) {
  const uint8_t *end = p + len;
  switch (op) {
  case AXC_HELLO: {
    uint8_t b[8], *q = b;
    put_u32(&q, AXC_VERSION);
    put_i32(&q, getpid());
    send_msg(c->fd, AXC_HELLO, b, sizeof(b), NULL, 0);
    break;
  }
  case AXC_SPAWN: on_spawn(c, p, end); break;
  case AXC_ATTACH: on_attach(c, p, end); break;
  case AXC_RELEASE: on_release(c, p, end); break;
  case AXC_SIGNAL: on_signal(c, p, end); break;
  case AXC_CLOSE: on_close(c, p, end); break;
  case AXC_LIST: on_list(c); break;
  case AXC_ADOPT: on_adopt(c, p, end, fds, nfds); return;
  case AXC_SHUTDOWN: shutdown_all(); break;
  default: {
    uint8_t zero[16] = {0};
    result(c->fd, zero, ENOTSUP);
  }
  }
  for (int i = 0; i < nfds; i++) close(fds[i]);
}

static void on_readable(size_t ci) {
  conn *c = &conns[ci];
  if (c->cap - c->len < 4096) {
    size_t cap = c->cap ? c->cap * 2 : 8192;
    uint8_t *n = realloc(c->buf, cap);
    if (!n) {
      close_conn(ci);
      return;
    }
    c->buf = n;
    c->cap = cap;
  }
  int fds[8], nfds = 0;
  ssize_t n = ax_recv_fds(c->fd, c->buf + c->len, c->cap - c->len, fds, 8, &nfds);
  for (int i = 0; i < nfds; i++) {
    if (c->nfdq < 16) c->fdq[c->nfdq++] = fds[i];
    else close(fds[i]);
  }
  if (n <= 0) {
    close_conn(ci);
    return;
  }
  c->len += (size_t)n;
  size_t off = 0;
  while (c->len - off >= 6) {
    uint32_t l;
    memcpy(&l, c->buf + off, 4);
    if (l < 2 || l > (16u << 20)) {
      close_conn(ci);
      return;
    }
    if (c->len - off < 4 + (size_t)l) break;
    uint8_t op = c->buf[off + 4], want = c->buf[off + 5];
    int mfds[4], mn = 0;
    while (mn < want && mn < 4 && c->nfdq > 0) {
      mfds[mn++] = c->fdq[0];
      memmove(c->fdq, c->fdq + 1, sizeof(int) * (size_t)--c->nfdq);
    }
    handle(c, op, c->buf + off + 6, l - 2, mfds, mn);
    // `handle` may have exited (shutdown) or the array may have moved; re-find.
    if (ci >= nconns || conns[ci].fd != c->fd) return;
    c = &conns[ci];
    off += 4 + l;
  }
  memmove(c->buf, c->buf + off, c->len - off);
  c->len -= off;
}

static void on_accept(void) {
  int fd = accept(listen_fd, NULL, NULL);
  if (fd < 0) return;
  uid_t uid;
  gid_t gid;
  if (getpeereid(fd, &uid, &gid) != 0 || uid != getuid()) {
    close(fd);
    return;
  }
  fcntl(fd, F_SETFD, FD_CLOEXEC);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
  if (nconns == capconns) {
    size_t cap = capconns ? capconns * 2 : 8;
    conn *n = realloc(conns, cap * sizeof(conn));
    if (!n) {
      close(fd);
      return;
    }
    conns = n;
    capconns = cap;
  }
  conns[nconns++] = (conn){.fd = fd};
  struct kevent ev;
  EV_SET(&ev, fd, EVFILT_READ, EV_ADD, 0, 0, (void *)(intptr_t)1);
  kevent(kq, &ev, 1, NULL, 0, NULL);
}

static void on_master(int fd) {
  for (size_t i = 0; i < nsessions; i++) {
    session *s = &sessions[i];
    if (s->master != fd) continue;
    uint8_t buf[65536];
    ssize_t n = read(fd, buf, sizeof(buf));
    if (n > 0) {
      if (s->ring) ax_ring_append(s->ring, buf, (size_t)n);
    } else if (n == 0 || (errno != EAGAIN && errno != EINTR)) {
      watch_read(s, false);
      s->eof = true; // child closed the slave; keep the session until CLOSE
    }
    return;
  }
}

static void on_exit_event(pid_t pid, int64_t data, bool known) {
  // XNU can post NOTE_EXIT a moment before the child is waitable (about 1
  // in 2000 exits under load), and WNOHANG then finds nothing: the child
  // would stay a zombie for good. It has exited, so a blocking wait returns
  // at once; for an adopted process (not our child) it fails with ECHILD.
  int st = 0;
  pid_t r;
  while ((r = waitpid(pid, &st, 0)) < 0 && errno == EINTR) {
  }
  bool reaped = r == pid;
  for (size_t i = 0; i < nsessions; i++) {
    if (sessions[i].pid == pid && sessions[i].status == AXC_ALIVE) {
      // NOTE_EXITSTATUS is only delivered for our own children; an adopted
      // child's status is unknowable.
      int32_t status = reaped ? st : (known && !sessions[i].adopted) ? (int32_t)data : -1;
      sessions[i].status = status;
      broadcast_exit(sessions[i].id, status);
    }
  }
}

// ---------------------------------------------------------------- main

int main(int argc, char **argv) {
  const char *sock_path = NULL, *lock_path = NULL;
  for (int i = 1; i + 1 < argc; i += 2) {
    if (!strcmp(argv[i], "--socket")) sock_path = argv[i + 1];
    else if (!strcmp(argv[i], "--lock")) lock_path = argv[i + 1];
    else if (!strcmp(argv[i], "--ring-dir")) ring_dir = argv[i + 1];
    else if (!strcmp(argv[i], "--ring-bytes")) ring_bytes = strtoull(argv[i + 1], NULL, 10);
    else if (!strcmp(argv[i], "--watch-pid")) watch_pid = (pid_t)strtol(argv[i + 1], NULL, 10);
  }
  if (!sock_path || !lock_path || !ring_dir || ring_bytes < 4096) {
    fprintf(stderr, "usage: axolotty-ptyd --socket PATH --lock PATH --ring-dir DIR [--ring-bytes N]\n");
    return 2;
  }
  openlog("axolotty-ptyd", LOG_PID, LOG_USER);
  signal(SIGHUP, SIG_IGN);
  signal(SIGPIPE, SIG_IGN);
  umask(077);

  int lock = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) return 0; // another holder owns the lock

  struct sockaddr_un addr = {.sun_family = AF_UNIX};
  if (strlen(sock_path) >= sizeof(addr.sun_path)) {
    fprintf(stderr, "socket path too long\n");
    return 2;
  }
  strcpy(addr.sun_path, sock_path);
  unlink(sock_path);
  listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (listen_fd < 0 || bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
      listen(listen_fd, 16) != 0) {
    syslog(LOG_ERR, "listen %s: %m", sock_path);
    return 1;
  }
  fcntl(listen_fd, F_SETFD, FD_CLOEXEC);

  kq = kqueue();
  struct kevent ev;
  EV_SET(&ev, listen_fd, EVFILT_READ, EV_ADD, 0, 0, NULL);
  kevent(kq, &ev, 1, NULL, 0, NULL);
  if (watch_pid > 0) {
    EV_SET(&ev, (uintptr_t)watch_pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, (void *)(intptr_t)2);
    if (kevent(kq, &ev, 1, NULL, 0, NULL) != 0) shutdown_all(); // already gone
  }

  for (;;) {
    struct kevent out[64];
    int n = kevent(kq, NULL, 0, out, 64, NULL);
    if (n < 0) {
      if (errno == EINTR) continue;
      syslog(LOG_ERR, "kevent: %m");
      return 1;
    }
    for (int i = 0; i < n; i++) {
      struct kevent *e = &out[i];
      if (e->filter == EVFILT_PROC && e->udata == (void *)(intptr_t)2) {
        shutdown_all();
      } else if (e->filter == EVFILT_PROC) {
        on_exit_event((pid_t)e->ident, e->data, true);
      } else if (e->filter == EVFILT_READ) {
        int fd = (int)e->ident;
        if (fd == listen_fd) on_accept();
        else if (e->udata == (void *)(intptr_t)1) {
          for (size_t k = 0; k < nconns; k++) {
            if (conns[k].fd == fd) {
              on_readable(k);
              break;
            }
          }
        } else on_master(fd);
      }
    }
    while (npending_exits > 0) on_exit_event(pending_exits[--npending_exits], 0, false);
  }
}
