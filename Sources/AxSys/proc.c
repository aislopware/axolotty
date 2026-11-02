// Process inspection through libproc and sysctl. Used to tell which program
// (shell, editor, coding agent) owns a pane's foreground process group.
#include "AxSys.h"

#include <errno.h>
#include <arpa/inet.h>
#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <unistd.h>

static int copy_out(const char *src, size_t len, char *buf, size_t cap) {
  if (!buf || cap == 0) return -1;
  if (len >= cap) len = cap - 1;
  memcpy(buf, src, len);
  buf[len] = '\0';
  return (int)len;
}

int ax_proc_name(pid_t pid, char *buf, size_t cap) {
  char tmp[2 * MAXCOMLEN + 1];
  int n = proc_name(pid, tmp, sizeof(tmp));
  if (n <= 0) return -1;
  return copy_out(tmp, (size_t)n, buf, cap);
}

int ax_proc_path(pid_t pid, char *buf, size_t cap) {
  char tmp[PROC_PIDPATHINFO_MAXSIZE];
  int n = proc_pidpath(pid, tmp, sizeof(tmp));
  if (n <= 0) return -1;
  return copy_out(tmp, (size_t)n, buf, cap);
}

int ax_proc_cwd(pid_t pid, char *buf, size_t cap) {
  struct proc_vnodepathinfo info;
  int n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sizeof(info));
  if (n != (int)sizeof(info)) return -1;
  return copy_out(info.pvi_cdir.vip_path, strnlen(info.pvi_cdir.vip_path, MAXPATHLEN), buf,
                  cap);
}

int ax_proc_children(pid_t pid, pid_t *out, int cap) {
  if (!out || cap <= 0) return -1;
  int n = proc_listchildpids(pid, out, cap * (int)sizeof(pid_t));
  if (n < 0) return -1;
  // proc_listchildpids returns a count on current kernels; older ones returned bytes.
  if (n > cap) n /= (int)sizeof(pid_t);
  return n > cap ? cap : n;
}

pid_t ax_proc_pgid(pid_t pid) {
  struct proc_bsdshortinfo info;
  int n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info));
  if (n != (int)sizeof(info)) return -1;
  return (pid_t)info.pbsi_pgid;
}

pid_t ax_proc_ppid(pid_t pid) {
  struct proc_bsdshortinfo info;
  int n = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, sizeof(info));
  if (n != (int)sizeof(info)) return -1;
  return (pid_t)info.pbsi_ppid;
}

int ax_proc_cmdline(pid_t pid, char *buf, size_t cap) {
  if (!buf || cap == 0) return -1;
  int mib[3] = {CTL_KERN, KERN_ARGMAX, 0};
  int argmax = 0;
  size_t sz = sizeof(argmax);
  if (sysctl(mib, 2, &argmax, &sz, NULL, 0) != 0 || argmax <= 0) return -1;

  char *raw = malloc((size_t)argmax);
  if (!raw) return -1;
  int mib2[3] = {CTL_KERN, KERN_PROCARGS2, pid};
  size_t len = (size_t)argmax;
  if (sysctl(mib2, 3, raw, &len, NULL, 0) != 0 || len < sizeof(int)) {
    free(raw);
    return -1;
  }

  // Layout: int argc, exec path, NULs, argv[0..argc), envp…
  int argc;
  memcpy(&argc, raw, sizeof(argc));
  char *p = raw + sizeof(int);
  char *end = raw + len;
  while (p < end && *p) p++; // exec path
  while (p < end && !*p) p++; // padding

  size_t w = 0;
  for (int i = 0; i < argc && p < end; i++) {
    size_t alen = strnlen(p, (size_t)(end - p));
    if (w > 0 && w + 1 < cap) buf[w++] = ' ';
    size_t take = alen;
    if (w + take >= cap) take = cap - 1 - w;
    memcpy(buf + w, p, take);
    w += take;
    p += alen + 1;
    if (w + 1 >= cap) break;
  }
  buf[w] = '\0';
  free(raw);
  return (int)w;
}

static void add_port(uint16_t port, uint16_t *out, int *n, int cap) {
  for (int i = 0; i < *n; i++)
    if (out[i] == port) return;
  if (*n >= cap) return;
  int i = *n;
  while (i > 0 && out[i - 1] > port) {
    out[i] = out[i - 1];
    i--;
  }
  out[i] = port;
  (*n)++;
}

static void scan_fds(pid_t pid, uint16_t *out, int *n, int cap) {
  int bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
  if (bytes <= 0) return;
  struct proc_fdinfo *fds = malloc((size_t)bytes);
  if (!fds) return;
  bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bytes);
  int count = bytes > 0 ? bytes / (int)sizeof(struct proc_fdinfo) : 0;
  for (int i = 0; i < count; i++) {
    if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
    struct socket_fdinfo si;
    int r = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof(si));
    if (r != (int)sizeof(si)) continue;
    if (si.psi.soi_kind != SOCKINFO_TCP) continue;
    if (si.psi.soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) continue;
    uint16_t port = ntohs((uint16_t)si.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport);
    if (port) add_port(port, out, n, cap);
  }
  free(fds);
}

int ax_proc_listening_ports(pid_t root, uint16_t *out, int cap) {
  if (!out || cap <= 0 || root <= 0) return 0;
  enum { MAX_PROCS = 256 };
  pid_t stack[MAX_PROCS];
  int top = 0, seen = 0, n = 0;
  stack[top++] = root;
  while (top > 0 && seen < MAX_PROCS) {
    pid_t p = stack[--top];
    seen++;
    scan_fds(p, out, &n, cap);
    pid_t kids[64];
    int k = ax_proc_children(p, kids, 64);
    for (int i = 0; i < k && top < MAX_PROCS; i++) stack[top++] = kids[i];
  }
  return n;
}
