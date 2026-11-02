// AxText — portable C hot paths for byte/text scanning (macOS + iOS).
#ifndef AXTEXT_H
#define AXTEXT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Text scanning

/// Strips C0/C1 controls and complete CSI/OSC/DCS/APC/SS2/SS3 escape sequences
/// from `in`, appending visible UTF-8 to `out`. Returns bytes written. Output is
/// at most `in_len` bytes, so `out_cap >= in_len` is always enough. `state`
/// carries an unfinished sequence across calls (start it zeroed).
typedef struct {
  uint8_t mode;
  uint8_t reserved;
} ax_strip_state;

size_t ax_strip_ansi(ax_strip_state *state, const uint8_t *in, size_t in_len,
                     uint8_t *out, size_t out_cap);

/// Case-sensitive substring search over raw bytes (memmem with a guard for
/// empty needles). Returns the offset or -1.
ptrdiff_t ax_find(const uint8_t *hay, size_t hay_len, const uint8_t *needle,
                  size_t needle_len);

#ifdef __cplusplus
}
#endif

#endif // AXTEXT_H
