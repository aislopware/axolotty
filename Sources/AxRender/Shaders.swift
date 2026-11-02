/// Metal Shading Language source, compiled at runtime (`makeLibrary(source:)`)
/// so builds need no Metal toolchain. The instance structs mirror AxFrame.h
/// byte for byte; `RenderLayoutTests` checks the sizes.
enum Shaders {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewport;      // drawable size, px
        float2 origin;        // grid origin, px
        float2 cell;          // cell size, px
        uint cols;
        uint rows;
        int cursorCol;        // -1: no block cursor recolouring
        int cursorRow;
        uint cursorText;      // RGBA8 colour of text under a block cursor
        float blinkVisible;   // 0 or 1 for SGR 5 cells
        float faintAlpha;
        float pad0;
    };

    struct GlyphInstance {
        ushort col; ushort row;
        short bx; short by;
        ushort ax; ushort ay; ushort w; ushort h;
        uint color;
        uchar atlas; uchar flags; ushort reserved;
    };

    struct RectInstance {
        float x; float y; float w; float h;
        uint color;
        uchar kind; uchar p0; uchar p1; uchar p2;
    };

    static float4 unpack(uint c) {
        return float4(float(c & 0xFF), float((c >> 8) & 0xFF), float((c >> 16) & 0xFF), float((c >> 24) & 0xFF)) / 255.0;
    }

    static float4 ndc(float2 px, float2 vp) {
        return float4(px.x / vp.x * 2.0 - 1.0, 1.0 - px.y / vp.y * 2.0, 0.0, 1.0);
    }

    constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

    // ---- Backgrounds: one quad over the grid; each fragment looks up its cell.

    struct BgOut { float4 pos [[position]]; float2 local; };

    vertex BgOut bg_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
        float2 size = u.cell * float2(u.cols, u.rows);
        BgOut o;
        o.local = corners[vid] * size;
        o.pos = ndc(u.origin + o.local, u.viewport);
        return o;
    }

    fragment float4 bg_fragment(BgOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                device const uint* cells [[buffer(1)]]) {
        uint col = min(uint(in.local.x / u.cell.x), u.cols - 1);
        uint row = min(uint(in.local.y / u.cell.y), u.rows - 1);
        uint c = cells[row * u.cols + col];
        if (c == 0) discard_fragment();
        float4 color = unpack(c);
        return float4(color.rgb * color.a, color.a);
    }

    // ---- Rectangles: decorations and the cursor.

    struct RectOut { float4 pos [[position]]; float2 local; float2 size; float4 color; uint kind [[flat]]; };

    vertex RectOut rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]],
                               device const RectInstance* rects [[buffer(1)]]) {
        RectInstance r = rects[iid];
        RectOut o;
        o.size = float2(r.w, r.h);
        o.local = corners[vid] * o.size;
        o.pos = ndc(u.origin + float2(r.x, r.y) + o.local, u.viewport);
        o.color = unpack(r.color);
        o.kind = r.kind;
        return o;
    }

    fragment float4 rect_fragment(RectOut in [[stage_in]]) {
        float a = in.color.a;
        if (in.kind == 1) {            // curly: a sine of one-third the rect's height
            float t = in.size.y / 3.0;
            float amp = (in.size.y - t) * 0.5;
            float period = max(in.size.y * 2.0, 4.0);
            float y = in.size.y * 0.5 + amp * sin(in.local.x * 6.2831853 / period);
            a *= saturate(t * 0.5 + 0.5 - abs(in.local.y - y));
        } else if (in.kind == 2) {     // dotted
            float t = max(in.size.y, 1.0);
            if (fmod(in.local.x, t * 2.0) >= t) discard_fragment();
        } else if (in.kind == 3) {     // dashed
            float t = max(in.size.y, 1.0) * 3.0;
            if (fmod(in.local.x, t * 2.0) >= t * 1.4) discard_fragment();
        }
        return float4(in.color.rgb * a, a);
    }

    // ---- Glyphs: atlas quads tinted by the cell foreground.

    struct GlyphOut { float4 pos [[position]]; float2 uv; float4 color; uint atlas [[flat]]; };

    vertex GlyphOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]],
                                 device const GlyphInstance* glyphs [[buffer(1)]]) {
        GlyphInstance g = glyphs[iid];
        float2 corner = corners[vid];
        float2 size = float2(g.w, g.h);
        float2 cellOrigin = u.origin + float2(g.col, g.row) * u.cell;
        GlyphOut o;
        o.pos = ndc(cellOrigin + float2(g.bx, g.by) + corner * size, u.viewport);
        o.uv = float2(g.ax, g.ay) + corner * size;
        float4 c = unpack(g.color);
        if (int(g.col) == u.cursorCol && int(g.row) == u.cursorRow) c = unpack(u.cursorText);
        if (g.flags & 1) c.a *= u.faintAlpha;
        if (g.flags & 2) c.a *= u.blinkVisible;
        o.color = c;
        o.atlas = g.atlas;
        return o;
    }

    fragment float4 glyph_fragment(GlyphOut in [[stage_in]], texture2d<float> gray [[texture(0)]],
                                   texture2d<float> color [[texture(1)]]) {
        constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
        if (in.atlas == 0) {
            float a = gray.sample(s, in.uv).r * in.color.a;
            return float4(in.color.rgb * a, a);
        }
        return color.sample(s, in.uv) * in.color.a;   // premultiplied BGRA
    }
    """#
}
