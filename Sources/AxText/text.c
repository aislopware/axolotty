// Byte-level text scanning used on the PTY read path (agent heuristics read the
// visible text of what programs print, not the escape sequences around it).
#include "AxText.h"

#include <string.h>

enum {
  S_GROUND = 0,
  S_ESC,          // after ESC
  S_ESC_INTER,    // ESC + intermediates, waiting for final
  S_CSI,          // ESC [ … final
  S_STRING,       // OSC / DCS / APC / PM / SOS body, until BEL or ST
  S_STRING_ESC,   // ESC inside a string (maybe ST)
};

size_t ax_strip_ansi(ax_strip_state *st, const uint8_t *in, size_t in_len, uint8_t *out,
                     size_t out_cap) {
  size_t w = 0;
  uint8_t mode = st->mode;
  for (size_t i = 0; i < in_len; i++) {
    uint8_t c = in[i];
    switch (mode) {
    case S_GROUND:
      if (c == 0x1b) {
        mode = S_ESC;
      } else if (c == '\n' || c == '\t') {
        if (w < out_cap) out[w++] = c;
      } else if (c < 0x20 || c == 0x7f) {
        // other C0 controls carry no visible text
      } else if (w < out_cap) {
        out[w++] = c; // printable ASCII and every UTF-8 byte
      }
      break;
    case S_ESC:
      if (c == '[') {
        mode = S_CSI;
      } else if (c == ']' || c == 'P' || c == '_' || c == '^' || c == 'X') {
        mode = S_STRING;
      } else if (c >= 0x20 && c <= 0x2f) {
        mode = S_ESC_INTER;
      } else if (c == 0x1b) {
        mode = S_ESC;
      } else {
        mode = S_GROUND; // two-byte sequence (ESC 7, ESC =, SS2/SS3 lead, …)
      }
      break;
    case S_ESC_INTER:
      if (c >= 0x30 && c <= 0x7e) mode = S_GROUND;
      else if (c == 0x1b) mode = S_ESC;
      break;
    case S_CSI:
      if (c >= 0x40 && c <= 0x7e) mode = S_GROUND;
      else if (c == 0x1b) mode = S_ESC; // aborted sequence
      break;
    case S_STRING:
      if (c == 0x07) mode = S_GROUND;
      else if (c == 0x1b) mode = S_STRING_ESC;
      break;
    case S_STRING_ESC:
      mode = (c == '\\') ? S_GROUND : (c == 0x1b ? S_STRING_ESC : S_STRING);
      break;
    default:
      mode = S_GROUND;
    }
  }
  st->mode = mode;
  return w;
}

ptrdiff_t ax_find(const uint8_t *hay, size_t hay_len, const uint8_t *needle, size_t needle_len) {
  if (needle_len == 0) return 0;
  if (!hay || needle_len > hay_len) return -1;
  const void *p = memmem(hay, hay_len, needle, needle_len);
  return p ? (const uint8_t *)p - hay : -1;
}
