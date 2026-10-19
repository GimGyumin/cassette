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
                                     constant LyricsColorProfile &profile [[buffer(1)]]) {
    constexpr sampler artworkSampler(filter::linear, address::mirrored_repeat);
    float aspect = parameters.x, time = parameters.y;
    float2 point = float2(in.uv.x, in.uv.y / aspect);
    float2 drift = float2(time * 0.007, time * -0.005);
    float2 first = float2(lyricsNoise(point * 1.6 + drift),
                          lyricsNoise(point * 1.6 + drift + 13.1)) - 0.5;
    float2 warp = float2(lyricsNoise(point * 1.9 + first * 0.7 + drift + 7.3),
                         lyricsNoise(point * 1.9 + first * 0.7 - drift + 31.7)) - 0.5;
    point += warp * 0.22;
    const float scales[4] = { 1.25, 0.80, 0.50, 0.25 };
    const float weights[4] = { 1.0, 0.48, 0.38, 0.25 };
    const float2 centers[4] = { float2(0.48, 0.48), float2(0.66, 0.28),
                               float2(0.70, 0.67), float2(0.27, 0.84) };
    float3 result = float3(0);
    float total = 0;
    for (uint layer = 0; layer < 4; layer++) {
        float phase = float(layer) * 1.73;
        float direction = layer % 2 == 0 ? 1.0 : -1.0;
        float orbit = layer < 2 ? 0.065 : 0.13;
        float2 center = float2(centers[layer].x, centers[layer].y / aspect)
            + float2(cos(time * (0.012 + layer * 0.002) + phase),
                     sin(time * (0.009 + layer * 0.003) + phase)) * orbit;
        float2 local = (point - center) / scales[layer];
        local = lyricsRotate(local, direction * time * (0.006 + layer * 0.002) + phase);
        float2 twistCenter = float2(sin(time * 0.008 + phase), cos(time * 0.007 + phase)) * 0.13;
        float2 delta = local - twistCenter;
        float falloff = max(0.0, 1.0 - length(delta) / 0.95);
        float twist = falloff * falloff * (0.75 + sin(time * 0.01 + phase) * 0.25) * direction;
        float4 sampled = artwork.sample(artworkSampler, lyricsRotate(delta, twist) + twistCenter + 0.5);
        float3 color = mix(profile.average.rgb, sampled.rgb, sampled.a);
        float mask = layer == 0 ? 1.0 : exp(-dot(local, local) * 2.4);
        float weight = weights[layer] * mask;
        result += color * weight;
        total += weight;
    }
    result /= total;
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
