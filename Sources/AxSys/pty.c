// PTY spawn. Between fork() and execve() the child may only make
// async-signal-safe calls: no malloc, no locks, no Swift. Everything the child
// needs is prepared by the parent before fork.
#include "AxSys.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

static int set_cloexec_nonblock(int fd, bool nonblock) {
  int flags = fcntl(fd, F_GETFD);
  if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) return errno;
  if (nonblock) {
    int fl = fcntl(fd, F_GETFL);
    if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) return errno;
  }
  return 0;
}

// Descriptors open in this process right now, so the child can close exactly
// those instead of looping to RLIMIT_NOFILE (which may be huge).
static int open_fds(int **out) {
  int bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, NULL, 0);
  if (bytes <= 0) return -1;
  bytes += 64 * (int)sizeof(struct proc_fdinfo); // room for fds opened meanwhile
  struct proc_fdinfo *info = malloc((size_t)bytes);
  if (!info) return -1;
  bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, info, bytes);
  if (bytes <= 0) {
    free(info);
    return -1;
  }
  int n = bytes / (int)sizeof(struct proc_fdinfo);
  int *fds = malloc(sizeof(int) * (size_t)(n > 0 ? n : 1));
  if (!fds) {
    free(info);
    return -1;
  }
  for (int i = 0; i < n; i++) fds[i] = info[i].proc_fd;
  free(info);
  *out = fds;
  return n;
}

static const char *env_lookup(char *const envp[], const char *key, size_t key_len) {
  for (char *const *e = envp; e && *e; e++) {
    if (strncmp(*e, key, key_len) == 0 && (*e)[key_len] == '=') return *e + key_len + 1;
  }
  return NULL;
}

int ax_pty_spawn(const char *path, char *const argv[], char *const envp[],
                 const char *cwd, ax_winsize size, ax_pty_child *out) {
  if (!path || !argv || !argv[0] || !out) return EINVAL;

  struct winsize ws = {
      .ws_row = size.rows ? size.rows : 24,
      .ws_col = size.cols ? size.cols : 80,
      .ws_xpixel = size.width_px,
      .ws_ypixel = size.height_px,
  };

  int master = -1, slave = -1;
  if (openpty(&master, &slave, NULL, NULL, &ws) != 0) return errno;

  // Start from sane line discipline settings: UTF-8 input, erase = DEL.
  struct termios tio;
  if (tcgetattr(slave, &tio) == 0) {
    tio.c_iflag |= IUTF8;
    tio.c_cc[VERASE] = 0x7f;
    tcsetattr(slave, TCSANOW, &tio);
  }

  int err = set_cloexec_nonblock(master, true);
  if (err == 0) err = set_cloexec_nonblock(slave, false);
  int errpipe[2] = {-1, -1};
  if (err == 0 && pipe(errpipe) != 0) err = errno;
  if (err == 0) err = set_cloexec_nonblock(errpipe[0], false);
  if (err == 0) err = set_cloexec_nonblock(errpipe[1], false);

  int *fds = NULL;
  int nfds = err == 0 ? open_fds(&fds) : -1;
  const char *home = env_lookup(envp, "HOME", 4);

  pid_t pid = -1;
  if (err == 0) {
    pid = fork();
    if (pid < 0) err = errno;
  }

  if (pid == 0) {
    // ---- child: async-signal-safe only ----
    sigset_t none;
    sigemptyset(&none);
    sigprocmask(SIG_SETMASK, &none, NULL);
    struct sigaction dfl = {.sa_handler = SIG_DFL};
    sigemptyset(&dfl.sa_mask);
    for (int s = 1; s < NSIG; s++) {
      if (s != SIGKILL && s != SIGSTOP) sigaction(s, &dfl, NULL);
    }

    int child_err = 0;
    if (setsid() < 0) child_err = errno;
    if (!child_err && ioctl(slave, TIOCSCTTY, 0) < 0) child_err = errno;
    if (!child_err && (dup2(slave, 0) < 0 || dup2(slave, 1) < 0 || dup2(slave, 2) < 0))
      child_err = errno;

    if (!child_err) {
      if (nfds > 0) {
        for (int i = 0; i < nfds; i++) {
          if (fds[i] > 2 && fds[i] != errpipe[1]) close(fds[i]);
        }
      } else {
        for (int fd = 3; fd < 4096; fd++) {
          if (fd != errpipe[1]) close(fd);
        }
      }
      if (slave > 2) close(slave);

      if (!cwd || chdir(cwd) != 0) {
        if (!home || chdir(home) != 0) (void)chdir("/");
      }
      execve(path, argv, envp);
      child_err = errno;
    }
    // Report why we failed; the pipe is close-on-exec so success sends nothing.
    ssize_t ignored = write(errpipe[1], &child_err, sizeof(child_err));
    (void)ignored;
    _exit(127);
  }

  free(fds);
  if (slave >= 0) close(slave);

  if (err == 0) {
    close(errpipe[1]);
    errpipe[1] = -1;
    int child_err = 0;
    ssize_t n;
    do {
      n = read(errpipe[0], &child_err, sizeof(child_err));
    } while (n < 0 && errno == EINTR);
    if (n == (ssize_t)sizeof(child_err)) {
      int status;
      while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
      }
      err = child_err ? child_err : ECHILD;
    }
  }

  if (errpipe[0] >= 0) close(errpipe[0]);
  if (errpipe[1] >= 0) close(errpipe[1]);

  if (err != 0) {
    close(master);
    return err;
  }
  out->master_fd = master;
  out->pid = pid;
  return 0;
}

int ax_pty_resize(int master_fd, ax_winsize size) {
  struct winsize ws = {
      .ws_row = size.rows,
      .ws_col = size.cols,
      .ws_xpixel = size.width_px,
      .ws_ypixel = size.height_px,
  };
  return ioctl(master_fd, TIOCSWINSZ, &ws) == 0 ? 0 : errno;
}

pid_t ax_pty_foreground_pgid(int master_fd) { return tcgetpgrp(master_fd); }

int ax_pty_reads_secret(int master_fd) {
  struct termios t;
  if (tcgetattr(master_fd, &t) != 0) return 0;
  return (t.c_lflag & ICANON) && !(t.c_lflag & ECHO);
}

ssize_t ax_write_some(int fd, const void *buf, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = write(fd, (const uint8_t *)buf + done, len - done);
    if (n > 0) {
      done += (size_t)n;
      continue;
    }
    if (n < 0 && errno == EINTR) continue;
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
    return done > 0 ? (ssize_t)done : -(ssize_t)errno;
  }
  return (ssize_t)done;
}
