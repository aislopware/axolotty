// The custody protocol between axolotty-ptyd (the PTY holder) and axolottyd.
//
// Unix stream socket. Every message: u32 len (LE, bytes after this field),
// u8 op, u8 nfds, payload. Descriptors (SCM_RIGHTS) travel with the first byte
// of their message; the receiver queues them in arrival order and each message
// takes `nfds` from the front. Integers are little-endian. Session ids are the
// pane's 16-byte UUID. Verbs are append-only; unknown ops get AXC_RESULT with
// err = ENOTSUP.
#ifndef AXCUSTODY_H
#define AXCUSTODY_H

#include <stdint.h>

#define AXC_VERSION 1u
#define AXC_ALIVE INT32_MIN /* exit status of a running child */

enum {
  /// C→H: u32 version.  H→C: u32 version, i32 holder pid.
  AXC_HELLO = 1,
  /// C→H: id, u16 cols, rows, width_px, height_px, u32 argc, u32 envc, then
  /// NUL-terminated strings: path, cwd ("" = none), argv[argc], env[envc].
  /// H→C: id, i32 err, i32 pid, fds [master, ring] when err == 0.
  AXC_SPAWN = 2,
  /// C→H: id. Hands the reader role to the caller: the holder stops draining.
  /// H→C: id, i32 err, i32 pid, i32 status, fds [master, ring].
  AXC_ATTACH = 3,
  /// C→H: id. The holder resumes draining into the ring. No reply.
  /// Implicit for every session a connection attached when it disconnects.
  AXC_RELEASE = 4,
  /// C→H: id, i32 signo, u8 foreground (1: the tty's foreground process group).
  /// H→C AXC_RESULT.
  AXC_SIGNAL = 5,
  /// C→H: id. SIGHUP to the process group, close master and ring, forget it.
  /// H→C AXC_RESULT.
  AXC_CLOSE = 6,
  /// C→H: empty. H→C: u32 n, then n × (id, i32 pid, i32 status, u8 attached).
  AXC_LIST = 7,
  /// C→H: id, i32 pid, fds [master, ring]. A restarted holder takes custody of
  /// a session the server kept alive. H→C AXC_RESULT.
  AXC_ADOPT = 8,
  /// C→H: empty. Hang up every session and exit (tests, uninstall). No reply.
  AXC_SHUTDOWN = 9,
  /// H→C: id, i32 err.
  AXC_RESULT = 10,
  /// H→C event: id, i32 wait status (or -1 when unknown, e.g. adopted).
  AXC_EXITED = 20,
};

#endif
