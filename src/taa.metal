// Shaders used by the injector. Compiled at runtime with newLibraryWithSource:
// (embedded into the dylib by the Makefile), so no offline Metal toolchain is needed.
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// Fullscreen triangle, uv origin top-left (Metal texture convention).
vertex VOut taa_fullscreen_vs(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.uv = uv;
    return o;
}

// Final copy / bilinear resample into the real drawable (any size, any format).
fragment float4 taa_copy_fs(VOut in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            sampler smp [[sampler(0)]]) {
    return src.sample(smp, in.uv);
}

struct TAAParams {
    float blend;       // weight of the current frame (0.1 = 90% history)
    float clampGamma;  // variance clip box size, in standard deviations
    uint  reset;       // 1 = history invalid, output current frame
    uint  pad;
};

static float3 rgb2ycocg(float3 c) {
    return float3(dot(c, float3( 0.25, 0.5,  0.25)),
                  dot(c, float3( 0.5,  0.0, -0.5 )),
                  dot(c, float3(-0.25, 0.5, -0.25)));
}

static float3 ycocg2rgb(float3 c) {
    return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
}

// "TAA-lite": temporal accumulation with variance clipping in YCoCg.
// No motion vectors and no projection jitter are available from outside the
// engine, so this is temporal *stabilization* (less shimmer/flicker), not
// real supersampling TAA. Moving content falls back to the current frame via
// the clip box, which limits (but does not eliminate) ghosting.
fragment float4 taa_resolve_fs(VOut in [[stage_in]],
                               texture2d<float> cur  [[texture(0)]],
                               texture2d<float> hist [[texture(1)]],
                               constant TAAParams &p [[buffer(0)]]) {
    int2 size = int2(cur.get_width(), cur.get_height());
    int2 c = int2(in.pos.xy);
    float4 center = cur.read(uint2(c));
    if (p.reset != 0) {
        return center;
    }

    float3 m1 = 0.0, m2 = 0.0;
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            int2 q = clamp(c + int2(dx, dy), int2(0), size - 1);
            float3 s = rgb2ycocg(cur.read(uint2(q)).rgb);
            m1 += s;
            m2 += s * s;
        }
    }
    float3 mean  = m1 / 9.0;
    float3 sigma = sqrt(max(m2 / 9.0 - mean * mean, 0.0));

    float3 h = rgb2ycocg(hist.read(uint2(c)).rgb);
    h = clamp(h, mean - p.clampGamma * sigma, mean + p.clampGamma * sigma);

    float3 res = mix(h, rgb2ycocg(center.rgb), p.blend);
    return float4(ycocg2rgb(res), center.a);
}
