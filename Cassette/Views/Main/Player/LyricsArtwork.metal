// Four-layer artwork compositing adapts AMLL PixiRenderer (AGPL-3.0-only).
// Copyright the AMLL contributors; native adaptation (C) 2026 Cassette contributors.
// Source revision 5fee356362353dbb24ce9bea3a62536478040de7, bg-render/pixi-renderer.ts.
// See Resources/Licenses/AMLL-AGPL-3.0.txt and THIRD_PARTY_NOTICES.md.
#include <metal_stdlib>
using namespace metal;

struct LyricsVertex {
    float4 position [[position]];
    float2 uv;
};

vertex LyricsVertex cassetteLyricsVertex(uint id [[vertex_id]]) {
    const float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    LyricsVertex out;
    out.position = float4(positions[id], 0, 1);
    out.uv = float2((positions[id].x + 1) * 0.5, (1 - positions[id].y) * 0.5);
    return out;
}

float2 lyricsRotate(float2 value, float angle) {
    float c = cos(angle), s = sin(angle);
    return float2(c * value.x - s * value.y, s * value.x + c * value.y);
}

// Smooth value noise is evaluated twice for domain warping, with no CPU/noise texture updates.
float lyricsHash(float2 p) {
    float3 q = fract(float3(p.x, p.y, p.x) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}
float lyricsNoise(float2 p) {
    float2 cell = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(lyricsHash(cell), lyricsHash(cell + float2(1, 0)), f.x),
               mix(lyricsHash(cell + float2(0, 1)), lyricsHash(cell + 1), f.x), f.y);
}
struct LyricsColorProfile { float4 average; float4 distribution; float4 colorAnchor; };
constant float3 lyricsLuma = float3(0.2289746, 0.6917385, 0.0792869);

fragment float4 cassetteLyricsScene(LyricsVertex in [[stage_in]],
                                     texture2d<float> artwork [[texture(0)]],
                                     constant float4 &parameters [[buffer(0)]],
                                     constant LyricsColorProfile &profile [[buffer(1)]],
                                     constant float4 *layers [[buffer(2)]]) {
    constexpr sampler artworkSampler(filter::linear, address::clamp_to_edge);
    float aspect = parameters.x, time = parameters.y;
    // Work in longest-edge units so the four square sleeves retain their shape
    // in both portrait and landscape. Swift supplies AMLL's sprite transforms.
    float2 point = in.uv * float2(min(aspect, 1.0), min(1.0 / aspect, 1.0));
    float2 drift = float2(time * 0.025, time * -0.018);
    float2 warp = float2(lyricsNoise(point * 2.0 + drift),
                         lyricsNoise(point * 2.0 - drift + 13.1)) - 0.5;
    point += warp * 0.035;
    float3 result = profile.average.rgb;
    for (uint layer = 0; layer < 4; layer++) {
        float4 transform = layers[layer];
        float2 local = lyricsRotate(point - transform.xy, -transform.w) / transform.z;
        float edge = max(abs(local.x), abs(local.y));
        float coverage = 1.0 - smoothstep(0.48, 0.5, edge);
        float4 sampled = artwork.sample(artworkSampler, local + 0.5);
        // Source-over ordering matches AMLL's four opaque sprites. The following
        // Gaussian pass dissolves their boundaries into large flowing color fields.
        result = mix(result, sampled.rgb, sampled.a * coverage);
    }
    // Spread the artwork's own light/color into subject shadows without adding a new hue.
    float spread = profile.distribution.y - profile.distribution.x;
    float diffusion = mix(0.12, 0.22, smoothstep(0.08, 0.65, spread));
    float3 anchor = profile.colorAnchor.w > 0 ? profile.colorAnchor.rgb : profile.average.rgb;
    return float4(mix(result, anchor, diffusion), 1);
}

fragment float4 cassetteLyricsComposite(LyricsVertex in [[stage_in]],
                                         texture2d<float> blurred [[texture(0)]],
                                         texture2d<float> previous [[texture(1)]],
                                         constant float4 &parameters [[buffer(0)]],
                                         constant LyricsColorProfile &profile [[buffer(1)]]) {
    constexpr sampler imageSampler(filter::linear, address::clamp_to_edge);
    float3 color = blurred.sample(imageSampler, in.uv).rgb;
    float luma = dot(color, lyricsLuma);
    // Color adjustment follows blur, in linear P3, with gentle adaptive saturation.
    float saturation = mix(1.16, 1.04, smoothstep(0.20, 0.80, profile.distribution.z));
    float3 chroma = (color - luma) * saturation;
    // Uniformly limit chroma rather than clipping individual channels and changing hue.
    float low = min(chroma.r, min(chroma.g, chroma.b));
    float chromaScale = low < -luma ? luma / max(-low, 0.00001) : 1.0;
    color = luma + chroma * chromaScale;
    float exposure = mix(0.92, 0.62, smoothstep(0.08, 0.65, profile.average.w));
    // Broad, continuous depth from the reference: color remains golden at the top and
    // becomes richer at the bottom. Adapt to the cover; neutral/very dark art stays neutral.
    float spread = profile.distribution.y - profile.distribution.x;
    float depth = smoothstep(0.02, 0.14, profile.average.w)
        * max(smoothstep(0.08, 0.4, spread), smoothstep(0.15, 0.6, profile.distribution.z));
    float vertical = smoothstep(0.18, 1.0, in.uv.y);
    exposure *= mix(1.0, mix(0.84, 0.26, vertical), depth);
    float mapped = luma * exposure / (1.0 + luma * exposure / 0.19);
    color *= mapped / max(luma, 0.00001);
    // All depth was tone-mapped above; no black overlay or abruptly clipped shadows.
    float vignette = smoothstep(0.25, 0.80, length(in.uv - 0.5));
    float3 incoming = color * (1.0 - vignette * 0.04);
    return float4(mix(previous.sample(imageSampler, in.uv).rgb, incoming, parameters.z), 1);
}

fragment float4 cassetteLyricsPresent(LyricsVertex in [[stage_in]],
                                       texture2d<float> composed [[texture(0)]]) {
    constexpr sampler imageSampler(filter::linear, address::clamp_to_edge);
    // Stationary sub-LSB dither avoids banding without animated grain or another pass.
    float dither = (lyricsHash(floor(in.position.xy)) - 0.5) * 0.0006;
    return float4(max(float3(0), composed.sample(imageSampler, in.uv).rgb + dither), 1);
}
