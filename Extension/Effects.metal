// Core Image kernels for the vanish effects.
// Compiled with -fcikernel / -cikernel (see project.yml) into default.metallib.
// Coordinates are pixels in a 1280x720 space, origin bottom-left.

#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

extern "C" { namespace coreimage {

// Builds a clean background plate. Pixels that were seen without a person come straight
// from `plate`; holes (where you have always been sitting) are filled by normalized
// convolution: blur(plate * coverage) / blur(coverage), at two radii.
float4 vanishFill(sampler plate, sampler cov,
                  sampler blurPremul, sampler blurCov,
                  sampler blurPremul2, sampler blurCov2,
                  destination dest) {
    float2 p = dest.coord();
    float3 P = plate.sample(plate.transform(p)).rgb;
    float c = cov.sample(cov.transform(p)).r;
    float3 a = blurPremul.sample(blurPremul.transform(p)).rgb;
    float ca = blurCov.sample(blurCov.transform(p)).r;
    float3 b = blurPremul2.sample(blurPremul2.transform(p)).rgb;
    float cb = blurCov2.sample(blurCov2.transform(p)).r;

    float3 fillA = a / max(ca, 1e-4);
    float3 fillB = b / max(cb, 1e-4);
    float3 fill = mix(fillB, fillA, smoothstep(0.02, 0.25, ca));
    if (cb < 0.002) fill = float3(0.18);           // nothing seen yet anywhere near
    return float4(mix(fill, P, smoothstep(0.3, 0.9, c)), 1.0);
}

// Normal Vanish: noisy dissolve with a glowing edge. progress 0 = visible, 1 = gone.
float4 vanishDissolve(sampler live, sampler bg, sampler mask, sampler noise,
                      float progress, destination dest) {
    float2 p = dest.coord();
    float3 L = live.sample(live.transform(p)).rgb;
    float3 B = bg.sample(bg.transform(p)).rgb;
    float m = mask.sample(mask.transform(p)).r;
    float n = noise.sample(noise.transform(p)).r;

    const float edge = 0.06;
    float t = progress * (1.0 + 2.0 * edge) - edge;
    float remain = smoothstep(t - edge * 0.5, t + edge * 0.5, n);
    float active = step(0.001, progress) * step(progress, 0.999);
    float glow = (1.0 - smoothstep(0.0, edge, abs(n - t))) * m * active;

    float3 rgb = mix(L, B, m * (1.0 - remain));
    rgb += glow * float3(0.55, 0.85, 1.0) * 0.9;
    return float4(min(rgb, float3(1.0)), 1.0);
}

// Goku: comic-style vertical streaks over the silhouette, the body collapses into
// thin columns and is gone. t 0 = visible, 1 = gone.
float4 vanishGoku(sampler live, sampler bg, sampler mask, sampler tallMask,
                  float t, float height, destination dest) {
    float2 p = dest.coord();
    float3 L = live.sample(live.transform(p)).rgb;
    float3 B = bg.sample(bg.transform(p)).rgb;
    float m = mask.sample(mask.transform(p)).r;
    float tm = tallMask.sample(tallMask.transform(p)).r;

    float col = floor(p.x / 5.0);
    float h = hash21(float2(col, 7.0));
    float isLine = step(0.55, h);

    float gone = mix(smoothstep(0.15, 0.45, t), smoothstep(0.40, 0.70, t), isLine);
    float3 rgb = mix(L, B, m * gone);

    float speed = 1.5 + 2.0 * hash21(float2(col, 3.0));
    float phase = fract(p.y / height * 1.3 - t * speed + h);
    float streak = smoothstep(0.0, 0.25, phase) * (1.0 - smoothstep(0.25, 0.6, phase));
    float env = smoothstep(0.05, 0.3, t) * (1.0 - smoothstep(0.75, 1.0, t));
    float lineA = isLine * streak * env * clamp(tm * 1.6, 0.0, 1.0);

    rgb = mix(rgb, mix(float3(0.80, 0.93, 1.0), float3(1.0), streak), lineA * 0.9);
    return float4(rgb, 1.0);
}

// Particles: the silhouette (frozen at effect start) breaks into square fragments that
// drift right and slightly up. For every output pixel we search the source cells to the
// left that could have flown here. t 0 = whole, 1 = scattered and faded.
float4 vanishParticles(sampler base, sampler snap, sampler snapMask,
                       float t, float cell, float width, destination dest) {
    float2 p = dest.coord();
    float4 outc = base.sample(base.transform(p));
    float2 cellIdx = floor(p / cell);
    const float slope = 0.22;

    for (int k = 0; k < 72; k++) {
        float ci = cellIdx.x - float(k);
        float baseRow = floor((p.y - float(k) * cell * slope) / cell);
        for (int r = -1; r <= 1; r++) {
            float2 c = float2(ci, baseRow + float(r));
            float2 center = (c + 0.5) * cell;
            if (snapMask.sample(snapMask.transform(center)).r < 0.5) continue;

            float h1 = hash21(c);
            float h2 = hash21(c + 17.0);
            float delay = 0.05 + 0.35 * h1 + 0.30 * (1.0 - center.x / width);
            float lt = clamp((t - delay) / 0.3, 0.0, 1.0);

            float dx = lt * lt * width * (0.15 + 0.27 * h2);
            float dy = dx * slope + sin(h1 * 6.2831 + lt * 6.0) * 5.0 * lt;
            float size = cell * (1.0 - 0.6 * lt);
            float2 moved = c * cell + float2(dx, dy) + (cell - size) * 0.5;

            if (p.x >= moved.x && p.x < moved.x + size && p.y >= moved.y && p.y < moved.y + size) {
                float2 src = c * cell + (p - moved) * (cell / size);
                float3 col = snap.sample(snap.transform(src)).rgb;
                float alpha = 1.0 - smoothstep(0.55, 1.0, lt);
                col = mix(col, col * float3(1.15, 0.95, 0.8), lt);   // warm ember tint as they drift
                outc.rgb = mix(outc.rgb, col, alpha);
                return outc;
            }
        }
    }
    return outc;
}

// Naruto: a burst of cartoon smoke puffs around `center`. t runs 0 -> 1 over the effect.
float4 narutoSmoke(sampler base, float2 center, float radius, float t, float seed,
                   destination dest) {
    float2 p = dest.coord();
    float3 B = base.sample(base.transform(p)).rgb;

    float grow = 1.0 - pow(1.0 - clamp(t / 0.35, 0.0, 1.0), 3.0);
    float fade = 1.0 - smoothstep(0.45, 1.0, t);

    float density = 0.0;
    float rim = 0.0;
    for (int i = 0; i < 18; i++) {
        float fi = float(i);
        float a = hash21(float2(fi, seed)) * 6.2831;
        float d = (0.25 + 0.75 * hash21(float2(seed, fi))) * radius * 0.85 * grow;
        float2 c = center + float2(cos(a), sin(a) * 0.8) * d + float2(0.0, t * radius * 0.25);
        float r = radius * (0.25 + 0.25 * hash21(float2(fi * 3.1, seed + 1.0))) * (0.4 + 0.8 * grow);
        float q = length(p - c) / r;
        float puff = 1.0 - smoothstep(0.55, 1.0, q);
        density = 1.0 - (1.0 - density) * (1.0 - puff);
        rim = max(rim, puff * smoothstep(0.6, 0.95, q));
    }

    float light = 0.80 + 0.15 * clamp((p.y - center.y) / radius, -1.0, 1.0);
    float3 smoke = float3(light) * float3(0.97, 0.97, 1.0) - rim * 0.25;
    float alpha = clamp(density, 0.0, 1.0) * fade * 0.97;
    return float4(mix(B, smoke, alpha), 1.0);
}

}}
