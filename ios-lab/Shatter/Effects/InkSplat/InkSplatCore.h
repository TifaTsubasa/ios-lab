//
//  InkSplatCore.h
//  ios-lab
//
//  斯普拉遁式墨水喷射的着色核心：逐像素的形态与配色。两条渲染路线共用这一份。
//
//  拆成「算形态」和「合成」两步，和皂膜同构：`inkShade` 只依赖坐标，
//  `inkComposite` 拿到采样结果再出最终颜色。详见 Shared/ShatterEffect.swift。
//

#pragma once
#include "../../Shared/ShatterShading.h"

namespace shatter {

/// 布局要和 InkSplat.swift 里的 `InkUniformsGPU` 严格对上
struct InkUniforms {
    float4 color;       // 放最前面：float4 要 16 字节对齐，摆后面会插一堆 padding
    float2 center;
    float2 halfSize;
    float2 nucleus;
    float  corner;
    float  band;
    float  frontT;
    float  lobe;
    float  warp;
    float  phase;
    float  speckleCell;
    float  speckleLead;
};

struct InkShade {
    float  mask;
    float  inkAmt;
    float3 ink;
    bool   dead;
};

/// 墨线前沿到某点的“有效距离”。比真实距离小，说明这个方向的墨冲得更远。
inline float inkFrontDistance(float2 rel, float lobe, float warp, float phase, float scale) {
    float dist = length(rel);
    float ang = atan2(rel.y, rel.x);
    // 3/5/7 次瓣：几团圆疙瘩粘在一起的轮廓
    float lobes = 0.55 * sin(3.0 * ang + phase * 6.283)
                + 0.30 * sin(5.0 * ang - phase * 4.11 + 1.7)
                + 0.15 * sin(7.0 * ang + phase * 2.71);
    float n = (fbm3(rel * 0.016 + phase * 17.0) - 0.5) * 2.0;
    return dist * (1.0 - lobe * lobes) - warp * scale * n;
}

inline InkShade inkShade(float2 pos, InkUniforms u) {
    InkShade o;
    o.dead = true; o.mask = 0.0; o.inkAmt = 0.0; o.ink = float3(0.0);

    float band = max(u.band, 1.0);
    float2 v = pos - u.center;
    float d = sdRoundBox(v, u.halfSize, u.corner);
    if (d > 1.5) { return o; }
    float mask = 1.0 - smoothstep(-0.6, 1.0, d);

    float2 vn = u.nucleus - u.center;

    // 行程 = 喷射点到最远那个角。瓣可以把墨甩得更远，所以留出余量，
    // 保证 frontT=1 时整块一定被吃干净。
    // Swift 侧的 `InkSplatEffect.frontReach` 必须算出同一个数。
    float2 far = float2(vn.x > 0.0 ? -u.halfSize.x : u.halfSize.x,
                        vn.y > 0.0 ? -u.halfSize.y : u.halfSize.y);
    float scale = length(u.halfSize);
    float reach = (length(far - vn) + u.corner) * (1.0 + u.lobe) + u.warp * scale;
    float front = u.frontT * reach;

    float sd = inkFrontDistance(v - vn, u.lobe, u.warp, u.phase, scale) - front;

    // ---- 前沿之前先甩几点散墨 ----
    // 抖动网格：每格藏一颗墨点，前沿逼近到 lead 以内时“啪”地出现。
    // 少了这一步，边界再有机也只像是「擦除」，不像「喷射」。
    float splat = 0.0;
    float cell = max(u.speckleCell, 4.0);
    float2 gid = floor(v / cell);
    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            float2 g = gid + float2(ox, oy);
            float2 rnd = hash22(g + u.phase * 31.7);
            float2 cpos = (g + 0.15 + 0.7 * rnd) * cell;
            float crad = cell * (0.10 + 0.26 * hash21(g + 3.31));
            float lead = u.speckleLead * (0.35 + 1.3 * hash21(g + 9.13));
            float cd = inkFrontDistance(cpos - vn, u.lobe, u.warp, u.phase, scale) - front;
            float appear = step(cd, lead);
            // 边缘要硬：1px 过渡就够，再宽就成雾了
            float dot_ = 1.0 - smoothstep(crad - 1.0, crad, length(v - cpos));
            splat = max(splat, appear * dot_);
        }
    }

    // sd < 0：已经被喷掉。sd ∈ [0, band]：糊着墨。更远：还是原视图（可能有散墨）。
    float alive = smoothstep(-0.7, 0.7, sd);
    float bandInk = 1.0 - smoothstep(band - 1.0, band, sd);

    // 墨带靠近破口的一侧压深一点，卡通墨迹那种描边感
    float deep = 1.0 - smoothstep(0.0, band * 0.55, sd);
    float3 ink = mix(u.color.rgb, u.color.rgb * 0.62, deep * bandInk);
    // 墨面上一点高光，避免大色块死板
    float gloss = smoothstep(0.55, 1.0, fbm3(v * 0.05 + u.phase * 7.0)) * bandInk;

    o.ink = clamp(ink + float3(gloss * 0.22), 0.0, 1.0);
    o.inkAmt = clamp(max(bandInk, splat), 0.0, 1.0);
    o.mask = mask * alive;
    o.dead = o.mask <= 0.002;
    return o;
}

inline half4 inkComposite(half4 src, InkShade s) {
    if (s.dead) { return half4(0.0h); }
    half3 rgb = src.rgb * half(1.0 - s.inkAmt) + half3(s.ink) * half(s.inkAmt);
    half  a   = src.a   * half(1.0 - s.inkAmt) + half(s.inkAmt);
    return half4(rgb, a) * half(s.mask);
}

} // namespace shatter
