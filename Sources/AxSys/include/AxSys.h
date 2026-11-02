// AxSys — macOS-only C: PTY spawn and process inspection.
//
// Only code that must be C lives here: the fork/exec path (only async-signal-safe
// calls are allowed between fork and exec, which Swift cannot promise), process
// inspection through libproc, and measured hot paths. Everything is plain C23,
// allocation-free unless noted, and has no global state.
#ifndef AXSYS_H
#define AXSYS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#include "AxCustody.h"

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - PTY

/// A child process attached to the slave side of a fresh pseudo-terminal.
typedef struct {
  int master_fd; ///< Non-blocking, close-on-exec. Owned by the caller.
  pid_t pid;     ///< The child's pid; it is also its session and process-group id.
} ax_pty_child;

/// Window size in cells and pixels, as TIOCSWINSZ wants it.
typedef struct {
  uint16_t cols;
  uint16_t rows;
  uint16_t width_px;
  uint16_t height_px;
} ax_winsize;

/// Opens a pty pair and starts `path` on its slave side as a session leader with
/// the slave as controlling terminal.
///
/// - `argv` and `envp` are NULL-terminated, like execve(2). argv[0] may start
///   with '-' to ask for a login shell.
/// - `cwd` may be NULL; when chdir fails the child falls back to $HOME, then "/".
/// - Signal dispositions and the signal mask are reset to defaults in the child,
///   and every descriptor above 2 is closed.
///
/// Returns 0, or an errno value. On failure nothing is left open.
int ax_pty_spawn(const char *path, char *const argv[], char *const envp[],
                 const char *cwd, ax_winsize size, ax_pty_child *out);

/// Applies a new window size (TIOCSWINSZ); the kernel sends SIGWINCH to the
/// foreground process group. Returns 0 or errno.
int ax_pty_resize(int master_fd, ax_winsize size);

/// The foreground process group of the terminal, or -1.
pid_t ax_pty_foreground_pgid(int master_fd);

/// 1 when the terminal reads a hidden line: canonical input with echo off,
/// what sudo, ssh and `read -s` set for a password. Raw-mode programs (editors,
/// agent TUIs) turn canonical input off too, so they are not counted. 0 otherwise.
int ax_pty_reads_secret(int master_fd);

/// Writes as much of `buf` as the non-blocking fd accepts, retrying EINTR.
/// Returns bytes written (possibly short), or -errno.
ssize_t ax_write_some(int fd, const void *buf, size_t len);

/// Non-blocking reap. Returns 1 and fills `status` (a wait(2) status) if the
/// child exited, 0 if it is still running, -errno on error.
int ax_reap(pid_t pid, int *status);

#pragma mark - Process inspection (libproc)

/// Short process name (p_comm, at most 16 bytes + NUL). Returns length or -1.
int ax_proc_name(pid_t pid, char *buf, size_t cap);

/// Absolute executable path. Returns length or -1.
int ax_proc_path(pid_t pid, char *buf, size_t cap);

/// Current working directory. Returns length or -1.
int ax_proc_cwd(pid_t pid, char *buf, size_t cap);

/// Direct children of `pid`. Returns how many were written (≤ cap), or -1.
int ax_proc_children(pid_t pid, pid_t *out, int cap);

/// Process group id of `pid`, or -1.
pid_t ax_proc_pgid(pid_t pid);

/// Parent process id of `pid`, or -1.
pid_t ax_proc_ppid(pid_t pid);

/// Full argv of `pid` joined by single spaces into `buf` (truncated to fit,
/// always NUL-terminated). Returns length or -1. Uses KERN_PROCARGS2.
int ax_proc_cmdline(pid_t pid, char *buf, size_t cap);


#pragma mark - Descriptor passing (SCM_RIGHTS)

/// Sends `len` bytes plus up to 4 descriptors in one message. Returns 0 or errno.
int ax_send_fds(int sock, const void *buf, size_t len, const int *fds, int nfds);

/// Receives one message (≤ cap bytes) and any descriptors (≤ max_fds, the rest
/// are closed). Returns bytes received (0 = peer closed) or -errno.
ssize_t ax_recv_fds(int sock, void *buf, size_t cap, int *fds, int max_fds, int *nfds);

#pragma mark - Journal ring (shared memory, absolute offsets)

/// A byte journal shared between the holder and the server: one writer at a
/// time appends program output; offsets are absolute for the life of the
/// session, so they survive server restarts and are the stream's sequence
/// numbers.
typedef struct {
  uint32_t magic;     ///< AX_RING_MAGIC
  uint32_t version;   ///< 1
  uint64_t capacity;  ///< data bytes after the header
  uint64_t head;      ///< absolute offset of the next byte (atomic)
  uint64_t reserved[5];
} ax_ring_header;

#define AX_RING_MAGIC 0x47525841u /* "AXRG" */

/// Creates an unlinked ring file of `capacity` data bytes in directory `dir`.
/// Returns the fd (close-on-exec) or -errno.
int ax_ring_create(const char *dir, uint64_t capacity);

/// Maps a ring fd. Returns the base address or NULL; `*size` gets the mapping size.
void *ax_ring_map(int fd, size_t *size);

/// Appends bytes (single writer). Returns the new head.
uint64_t ax_ring_append(void *ring, const void *bytes, size_t len);

/// The current head (acquire).
uint64_t ax_ring_head(const void *ring);

/// Oldest offset still readable.
uint64_t ax_ring_tail(const void *ring);

/// Copies bytes [from, min(head, from+cap)) into out. Returns the count, or -1 if
/// `from` has already been overwritten (or lies past the head).
ssize_t ax_ring_read(const void *ring, uint64_t from, void *out, size_t cap);

#ifdef __cplusplus
}
#endif

#endif // AXSYS_H
