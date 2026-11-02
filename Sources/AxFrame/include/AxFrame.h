// AxFrame — the per-frame hot path: turns a libghostty-vt render state into
// GPU instance arrays. Runs on the render thread, allocation-free in steady
// state, rebuilds only rows the render state marks dirty.
//
// The instance structs below are mirrored byte-for-byte in the Metal shader
// source (AxRender/Shaders.swift); their sizes are checked with static_assert
// here and with MemoryLayout in the tests.
#ifndef AXFRAME_H
#define AXFRAME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <ghostty/vt.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One glyph quad. Positions are in cells; bearings and atlas rects in pixels.
typedef struct {
  uint16_t col, row;
  int16_t bearing_x;   ///< left edge of the bitmap relative to the cell's left
  int16_t bearing_y;   ///< top edge of the bitmap relative to the cell's top
  uint16_t atlas_x, atlas_y, width, height;
  uint32_t color;      ///< RGBA8, R in the lowest byte
  uint8_t atlas;       ///< 0 = grayscale (mask, tinted by color), 1 = color (emoji)
  uint8_t flags;       ///< AX_GLYPH_* bits
  uint16_t reserved;
} ax_glyph_instance;

enum {
  AX_GLYPH_FAINT = 1u << 0,  ///< draw at reduced alpha
  AX_GLYPH_BLINK = 1u << 1,  ///< hidden in the off phase
};

/// A filled or patterned rectangle (underline, strikethrough, overline),
/// in pixels relative to the grid origin.
typedef struct {
  float x, y, w, h;
  uint32_t color;
  uint8_t kind;        ///< AX_RECT_*
  uint8_t reserved[3];
} ax_rect_instance;

enum {
  AX_RECT_SOLID = 0,
  AX_RECT_CURLY = 1,
  AX_RECT_DOTTED = 2,
  AX_RECT_DASHED = 3,
};

/// A rasterized glyph as the cache stores it.
typedef struct {
  uint16_t atlas_x, atlas_y, width, height;
  int16_t bearing_x, bearing_y;
  uint8_t atlas;
  bool empty;  ///< nothing to draw (space, zero-size)
} ax_glyph;

/// Style bits that select a different rasterization of the same text.
enum {
  AX_FONT_BOLD = 1u << 0,
  AX_FONT_ITALIC = 1u << 1,
  AX_FONT_WIDE = 1u << 2,  ///< occupies two cells
};

/// Called on a cache miss. Rasterizes `cps[0..<n]` (one grapheme cluster) and
/// fills `out`. Return false to draw nothing for this text.
typedef bool (*ax_rasterize_fn)(void *ctx, const uint32_t *cps, uint32_t n, uint8_t font_flags,
                                ax_glyph *out);

typedef struct ax_glyph_cache ax_glyph_cache;

ax_glyph_cache *ax_glyph_cache_new(ax_rasterize_fn fn, void *ctx);
void ax_glyph_cache_free(ax_glyph_cache *cache);
/// Drops every entry (after the atlas is reset, or the font changed).
void ax_glyph_cache_clear(ax_glyph_cache *cache);
/// Looks up or rasterizes. Returns NULL when the text draws nothing.
const ax_glyph *ax_glyph_cache_get(ax_glyph_cache *cache, const uint32_t *cps, uint32_t n,
                                   uint8_t font_flags);
size_t ax_glyph_cache_count(const ax_glyph_cache *cache);

/// How to colour things. Colours are RGBA8 with R in the lowest byte.
typedef struct {
  float cell_width, cell_height;   ///< pixels
  float underline_y, underline_thickness;
  float strike_y, strike_thickness;
  uint32_t selection_bg;           ///< 0 = invert fg/bg instead
  uint32_t selection_fg;           ///< 0 = keep the cell's fg
  bool bold_is_bright;             ///< bold palette 0–7 → 8–15
  float faint_alpha;               ///< 0…1
  float min_contrast;              ///< WCAG ratio text keeps over its ground; ≤ 1 = off
} ax_frame_style;

/// Returns `fg` moved toward black or white (whichever the ground allows) by
/// the least amount that reaches `ratio` against `bg`; `fg` itself when it
/// already does. Colours are RGBA8, R in the lowest byte; alpha is kept.
uint32_t ax_min_contrast(uint32_t fg, uint32_t bg, float ratio);

/// Everything the renderer needs for one terminal frame. Owned by the caller,
/// reused across frames (buffers grow, never shrink).
typedef struct ax_frame ax_frame;

ax_frame *ax_frame_new(void);
void ax_frame_free(ax_frame *frame);

typedef struct {
  uint16_t cols, rows;
  bool any_dirty;          ///< false: nothing changed, skip drawing
  bool cursor_visible;     ///< viewport has the cursor and it is visible
  uint16_t cursor_x, cursor_y;
  bool cursor_wide;        ///< the cell under the cursor is wide
  bool cursor_blinking;
  uint8_t cursor_style;    ///< GhosttyRenderStateCursorVisualStyle
  uint32_t cursor_color;   ///< 0 = use the theme's
  uint32_t background;     ///< terminal default bg (OSC 11 aware)
  uint32_t foreground;
  bool has_blink;          ///< some visible cell blinks
} ax_frame_info;

/// Rebuilds the dirty rows of `frame` from `state` (which the caller has
/// already updated from the terminal) and clears the render state's dirty bits.
/// Returns 0 or a GhosttyResult error.
int ax_frame_build(ax_frame *frame, GhosttyRenderState state, ax_glyph_cache *cache,
                   const ax_frame_style *style, ax_frame_info *info);

/// Forces the next build to rebuild every row (style or font changed).
void ax_frame_invalidate(ax_frame *frame);

/// A run of cells on one viewport row painted with `bg` (find matches).
/// Drawn as the cells' ground, under the text; a selection still wins.
typedef struct {
  uint16_t row, x0, x1;  ///< x1 inclusive
  uint32_t bg;
} ax_highlight;

/// Replaces the highlights (copied). Rebuilds every row when they changed.
/// Returns false when out of memory (the old highlights are kept).
bool ax_frame_set_highlights(ax_frame *frame, const ax_highlight *spans, size_t n);

/// Flattened views of the frame for upload. Pointers stay valid until the next
/// build. Row order; `bg` has cols*rows entries (0 = default background).
const uint32_t *ax_frame_bg(const ax_frame *frame, size_t *count);
const ax_glyph_instance *ax_frame_glyphs(ax_frame *frame, size_t *count);
const ax_rect_instance *ax_frame_rects(ax_frame *frame, size_t *count);

/// Packs RGB into RGBA8 with alpha 255.
static inline uint32_t ax_rgba(uint8_t r, uint8_t g, uint8_t b) {
  return (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)b << 16) | (0xFFu << 24);
}

#ifdef __cplusplus
}
#endif

#endif // AXFRAME_H
