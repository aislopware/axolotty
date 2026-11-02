// Process inspection through libproc and sysctl. Used to tell which program
// (shell, editor, coding agent) owns a pane's foreground process group.
#include "AxSys.h"

#include <errno.h>
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
