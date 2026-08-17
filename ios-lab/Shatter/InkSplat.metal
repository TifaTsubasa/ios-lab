//
//  InkSplat.metal
//  ios-lab
//
//  斯普拉遁式的墨水喷射：一道有机的墨线从被点到的那一点扫过视图，
//  扫过的地方先被糊上一层不透明的墨，紧接着整块消失。
//
//  抓形的关键全在「边界不能是圆」：
//  1. 角向瓣。斯普拉遁的墨迹是几团圆疙瘩粘在一起，轮廓上有 3/5/7 次的低频起伏，
//     不是光滑的圆。用几个不同频率的正弦叠在极角上就够像。
//  2. 噪声扰动。再叠一层低频 fbm，让瓣与瓣之间的过渡不规整。
//  3. 提前甩出去的墨点。真正的喷射是先落下几点散墨，主体才跟上来 ——
//     没有这一步，边界再有机也像是「擦除」而不是「喷射」。
//  4. 边缘必须**硬**。皂膜那套靠柔和渐变出效果，墨正相反：卡通渲染的墨迹是
//     实心色块 + 干脆的轮廓，边缘一软立刻变成烟雾。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// MARK: - 基础工具

static inline float sdRoundBox(float2 p, float2 b, float r) {
    r = min(r, min(b.x, b.y));
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

/// 解相关够好的格点散列（同 SoapFilm.metal，理由见那边的注释）
static inline float inkHash21(float2 p) {
    p = fmod(p, 256.0);
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, float3(p3.y, p3.z, p3.x) + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float2 inkHash22(float2 p) {
    return float2(inkHash21(p), inkHash21(p + float2(37.2, 11.7)));
}

static inline float inkNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = inkHash21(i);
    float b = inkHash21(i + float2(1.0, 0.0));
    float c = inkHash21(i + float2(0.0, 1.0));
    float d = inkHash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static inline float inkFbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; ++i) { v += a * inkNoise(p); p *= 2.07; a *= 0.5; }
    return v / 0.875;
}

/// 墨线前沿到某点的“有效距离”。比真实距离小，说明这个方向的墨冲得更远。
static inline float inkFrontDistance(float2 rel, float lobe, float warp, float seed, float scale) {
    float dist = length(rel);
    float ang = atan2(rel.y, rel.x);
    // 3/5/7 次瓣：几团圆疙瘩粘在一起的轮廓
    float lobes = 0.55 * sin(3.0 * ang + seed * 6.283)
                + 0.30 * sin(5.0 * ang - seed * 4.11 + 1.7)
                + 0.15 * sin(7.0 * ang + seed * 2.71);
    float n = (inkFbm(rel * 0.016 + seed * 17.0) - 0.5) * 2.0;
    return dist * (1.0 - lobe * lobes) - warp * scale * n;
}

// MARK: - 主着色器

/// center    视图中心（视图坐标 pt）
/// halfSize  视图半宽高
/// shape     x = 圆角半径, y = 墨带宽度（前沿后面那圈墨有多宽）
/// anim      x = frontT(0...1 喷射进度), y = 瓣状强度,
///           z = 噪声扰动强度,          w = 随机相位
/// speckle   x = 散墨格子边长, y = 散墨比前沿提前多少 pt
/// nucleus   喷射起点（视图坐标 pt），跟手时就是手指点到的位置
/// inkColor  墨色
[[ stitchable ]] half4 inkSplat(float2 pos,
                                SwiftUI::Layer layer,
                                float2 center,
                                float2 halfSize,
                                float2 shape,
                                float4 anim,
                                float2 speckle,
                                float2 nucleus,
                                half4 inkColor)
{
    float corner = shape.x;
    float band   = max(shape.y, 1.0);
    float frontT = anim.x;
    float lobe   = anim.y;
    float warp   = anim.z;
    float seed   = anim.w;

    float2 v = pos - center;
    float d = sdRoundBox(v, halfSize, corner);
    if (d > 1.5) { return half4(0.0h); }
    float mask = 1.0 - smoothstep(-0.6, 1.0, d);

    float2 vn = nucleus - center;

    // 行程 = 喷射点到最远那个角。瓣可以把墨甩得更远，所以留出余量，
    // 保证 frontT=1 时整块一定被吃干净。
    float2 far = float2(vn.x > 0.0 ? -halfSize.x : halfSize.x,
                        vn.y > 0.0 ? -halfSize.y : halfSize.y);
    float scale = length(halfSize);
    float reach = (length(far - vn) + corner) * (1.0 + lobe) + warp * scale;
    float front = frontT * reach;

    float sd = inkFrontDistance(v - vn, lobe, warp, seed, scale) - front;

    // ---- 前沿之前先甩几点散墨 ----
    // 抖动网格：每格藏一颗墨点，前沿逼近到 lead 以内时“啪”地出现。
    float splat = 0.0;
    float cell = max(speckle.x, 4.0);
    float2 gid = floor(v / cell);
    for (int oy = -1; oy <= 1; ++oy) {
        for (int ox = -1; ox <= 1; ++ox) {
            float2 g = gid + float2(ox, oy);
            float2 rnd = inkHash22(g + seed * 31.7);
            float2 cpos = (g + 0.15 + 0.7 * rnd) * cell;
            float crad = cell * (0.10 + 0.26 * inkHash21(g + 3.31));
            float lead = speckle.y * (0.35 + 1.3 * inkHash21(g + 9.13));
            // 这颗墨点什么时候被喷到
            float cd = inkFrontDistance(cpos - vn, lobe, warp, seed, scale) - front;
            float appear = step(cd, lead);
            // 边缘要硬：1px 过渡就够，再宽就成雾了
            float dot_ = 1.0 - smoothstep(crad - 1.0, crad, length(v - cpos));
            splat = max(splat, appear * dot_);
        }
    }

    // ---- 上墨 + 消失 ----
    // sd < 0：已经被喷掉。sd ∈ [0, band]：糊着墨。更远：还是原视图（可能有散墨）。
    float alive = smoothstep(-0.7, 0.7, sd);
    float bandInk = 1.0 - smoothstep(band - 1.0, band, sd);
    float inkAmt = clamp(max(bandInk, splat), 0.0, 1.0);

    half4 src = layer.sample(pos);

    // 墨带靠近破口的一侧压深一点，卡通墨迹那种描边感
    float deep = 1.0 - smoothstep(0.0, band * 0.55, sd);
    half3 ink = mix(inkColor.rgb, inkColor.rgb * 0.62h, half(deep * bandInk));
    // 墨面上一点高光，避免大色块死板
    float gloss = smoothstep(0.55, 1.0, inkFbm(v * 0.05 + seed * 7.0)) * bandInk;
    ink = clamp(ink + half3(half(gloss * 0.22)), 0.0h, 1.0h);

    half3 rgb = src.rgb * half(1.0 - inkAmt) + ink * half(inkAmt);
    half a    = src.a   * half(1.0 - inkAmt) + half(inkAmt);
    return half4(rgb, a) * half(mask * alive);
}
