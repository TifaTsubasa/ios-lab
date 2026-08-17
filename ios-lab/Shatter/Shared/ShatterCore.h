//
//  ShatterCore.h
//  ios-lab
//
//  两条渲染路线共用的着色核心。
//
//  - SwiftUI 路线：`SwiftUI/SoapFilm.metal` / `InkSplat.metal` 里的 `[[stitchable]]` 函数，
//    内容通过 `SwiftUI::Layer` 采样。
//  - UIKit 路线：`UIKit/UIKitShatterKernels.metal` 里的普通 `[[fragment]]` 函数，
//    内容通过 `texture2d<half>` 采样（因为 SwiftUI 栅格不到 UIKit 图层，见 AGENTS.md）。
//
//  两边的采样方式不同，但每像素的形态与配色必须完全一致，所以这里把逻辑拆成
//  「算形态」和「合成」两步：算形态只依赖坐标，顺带给出该去哪儿采样内容；
//  合成拿到采样结果再出最终颜色。谁来采样由各自的入口决定。
//

#pragma once
#include <metal_stdlib>
using namespace metal;

namespace shatter {

/// 皂液折射率
constant float kIOR = 1.34;

// MARK: - 基础工具

inline float sdRoundBox(float2 p, float2 b, float r) {
    r = min(r, min(b.x, b.y));
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

/// 格点散列。这里必须用解相关够好的版本：常见的
/// `p = fract(p*float2(127.1,311.7)); p += dot(p,p+34.23); return fract(p.x*p.y);`
/// 在相邻格点上高度相关，噪声里会留下沿坐标轴排列的结构。平时看不出来，
/// 但膜厚要经过干涉相位（~26 rad）放大成颜色，那点结构就显形成一圈
/// **位置几乎不动、轴对齐**的矩形折痕 —— 看起来完全像是渲染 bug。
inline float hash21(float2 p) {
    // 先把格点压回小范围：噪声坐标被 flow 推着随时间长大，到几百以上
    // float32 的 fract() 只剩两三位有效小数，散列会直接塌成阶梯。
    p = fmod(p, 256.0);
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, float3(p3.y, p3.z, p3.x) + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float2 hash22(float2 p) {
    return float2(hash21(p), hash21(p + float2(37.2, 11.7)));
}

inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    // 必须用五次插值（C²），不能用常见的 f²(3-2f)（只有 C¹）。
    // 后者的二阶导在格点上跳变，本来看不出来，但膜厚要经过干涉相位（~26 rad）
    // 放大成颜色，那点跳变就会显形成一圈**轴对齐的矩形折痕**，
    // 网格间距多大，矩形就多大 —— 看起来完全像是渲染 bug。
    f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

inline float fbm4(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; ++i) { v += a * vnoise(p); p *= 2.03; a *= 0.5; }
    return v / 0.9375;
}

inline float fbm3(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; ++i) { v += a * vnoise(p); p *= 2.07; a *= 0.5; }
    return v / 0.875;
}

/// 薄膜双光束干涉的反射色。thickness 单位 nm，cosT 是膜内折射角余弦。
inline float3 thinFilmColor(float thickness, float cosT) {
    const float3 lambda = float3(680.0, 545.0, 445.0);
    // I ∝ 4·cos²(φ/2)，φ = 2π·Δ/λ + π  ⇒  I ∝ sin²(π·Δ/λ)
    float3 phase = (4.0 * M_PI_F * kIOR * thickness * cosT) / lambda;
    return 0.5 - 0.5 * cos(phase);
}

// MARK: - 皂膜

struct FilmUniforms {
    float2 center;
    float2 halfSize;
    float2 nucleus;
    float  corner;
    float  dome;
    float  frontT;
    float  contentAlpha;
    float  filmMix;
    float  thicknessNM;
    float  time;
    float  _pad;
};

struct FilmShade {
    float2 samplePos;   // 该去哪儿采样内容
    float3 refl;        // 膜的反射色（已乘 filmMix）
    float  mask;
    float  keep;        // 内容保留系数
    float  rt;          // 膜的覆盖度
    bool   dead;        // 这个像素已经没了
};

inline FilmShade filmShade(float2 pos, FilmUniforms u) {
    FilmShade o;
    o.dead = true;
    o.samplePos = pos;
    o.refl = float3(0.0);
    o.mask = 0.0; o.keep = 0.0; o.rt = 0.0;

    float dome = max(u.dome, 1.0);
    float2 v = pos - u.center;

    float d = sdRoundBox(v, u.halfSize, u.corner);
    if (d > 1.5) { return o; }

    // 有限差分取 SDF 梯度，得到膜面的“朝外”方向
    const float e = 0.9;
    float2 grad = float2(sdRoundBox(v + float2(e, 0.0), u.halfSize, u.corner)
                       - sdRoundBox(v - float2(e, 0.0), u.halfSize, u.corner),
                         sdRoundBox(v + float2(0.0, e), u.halfSize, u.corner)
                       - sdRoundBox(v - float2(0.0, e), u.halfSize, u.corner));
    grad = (length(grad) > 1e-5) ? normalize(grad) : float2(0.0, -1.0);

    // 由 SDF 生成球冠高度场，只在离边缘 dome 以内的一圈里弯曲，更里面膜是全平的。
    //
    // 曲面带到平面的接缝必须“无限平滑”。直接用 s = 1-u（正球冠）时 s 在 u=1 处
    // 斜率是 -1，掠射角 ang≈s²/2 的二阶导在那里跳变；干涉色对角度极其敏感，
    // 这点跳变会被放大成一条清清楚楚的矩形亮边。换成 smoothstep 后 s≈3(1-u)²，
    // ang 以四次方趋零，接缝彻底看不见了。
    float uu = clamp(-d / dome, 0.0, 1.0);
    float s  = 1.0 - smoothstep(0.0, 1.0, uu);
    float ht = sqrt(max(2e-3, 1.0 - s * s));
    float3 N = normalize(float3(grad * (s / ht), 1.0));

    float mask = 1.0 - smoothstep(-0.6, 1.0, d);

    // ---- 破裂：孔洞从 nucleus 沿膜面扩张 ----
    float3 P = float3(v, ht * dome);
    float2 vn = u.nucleus - u.center;
    float sn = 1.0 - smoothstep(0.0, 1.0,
                                clamp(-sdRoundBox(vn, u.halfSize, u.corner) / dome, 0.0, 1.0));
    float3 P0 = float3(vn, sqrt(max(2e-3, 1.0 - sn * sn)) * dome);

    // 行程 = 破裂点到最远那个角的距离。破裂点越偏，孔洞要跑的路越长，
    // 但 frontT 走完一整趟的时间不变 —— 靠边点会破得更快，跟真实观感一致。
    float2 far = float2(vn.x > 0.0 ? -u.halfSize.x : u.halfSize.x,
                        vn.y > 0.0 ? -u.halfSize.y : u.halfSize.y);
    float reach = length(far - vn) + u.corner + dome;

    float geo   = distance(P, P0);
    float holeR = u.frontT * reach;             // Taylor–Culick：半径随时间线性增长
    float rimW  = max(2.0, min(u.halfSize.x, u.halfSize.y) * 0.055);

    // frontT 为 0 时整块膜都得完好无损。少了这层判断，holeR=0 的 smoothstep
    // 会在破裂点上抠掉一个亚点级的小洞，静止时就是一个莫名其妙的针孔。
    float rim = 0.0;
    if (u.frontT > 0.0) {
        mask *= smoothstep(holeR - 0.8, holeR + 0.8, geo);
        if (mask <= 0.002) { return o; }
        rim = exp(-pow((geo - holeR) / rimW, 2.0));
    }

    // ---- 膜厚 ----
    // 花纹按视图空间位置采样，不能按法线 —— 膜中间是平的，法线在那儿处处相同，
    // 拿法线当坐标的话整片中央会是一个死板的纯色。
    float2 tuv = v / max(u.halfSize.x, u.halfSize.y);
    float2 flow = float2(u.time * 0.05, -u.time * 0.03);
    float turb = fbm4(tuv * 3.2 + flow);
    // 厚度在**空间上**的总跨度必须压在大约一个干涉周期以内（Δd = λ/2n ≈ 166 nm）。
    // 跨度超了，等厚线会密集成干涉条纹；而膜中间是平的、vert 又是 v.y 的线性斜坡，
    // 等厚线于是恰好是**笔直的轴对齐直线**，看起来就像画错了一个矩形。
    float vert = mix(0.88, 1.0, clamp(0.5 + 0.5 * (v.y / u.halfSize.y), 0.0, 1.0));
    float thickness = u.thicknessNM * vert * mix(0.94, 1.07, turb);
    thickness *= 1.0 + 4.5 * rim;               // 卷边聚膜，厚度骤增

    // ---- 反射：干涉 + 菲涅尔 + 高光 ----
    float sin2 = (1.0 - N.z * N.z) / (kIOR * kIOR);
    float cosT = sqrt(max(0.0, 1.0 - sin2));
    float3 irid = thinFilmColor(thickness, cosT);

    float ang  = 1.0 - N.z;                                  // 0 正对 → 1 掠射
    float fres = 0.02 + 0.98 * pow(ang, 5.0);
    float3 refl = irid * clamp(4.0 * fres, 0.0, 1.0);        // 双光束干涉峰值约 4·R_single
    refl += float3(pow(ang, 7.0)) * 0.5;                     // 轮廓上那圈发白的镜面环

    float3 V = float3(0.0, 0.0, 1.0);
    float3 H1 = normalize(normalize(float3(-0.50, -0.68, 0.53)) + V);  // 主光源
    float3 H2 = normalize(normalize(float3( 0.62, -0.20, 0.76)) + V);  // 柔和的“窗户”反光
    float3 H3 = normalize(normalize(float3( 0.10,  0.80, 0.59)) + V);  // 地面弹射的环境光
    float spec = pow(max(0.0, dot(N, H1)), 300.0) * 1.5
               + pow(max(0.0, dot(N, H2)),  26.0) * 0.13
               + pow(max(0.0, dot(N, H3)),  12.0) * 0.06;
    refl += float3(spec);
    refl += float3(1.0, 0.96, 0.90) * rim * 0.85;            // 卷边亮环

    // 边缘那圈曲面把内容往里压，像玻璃倒角一样。中间 N.xy 为零，内容原样透过。
    o.samplePos = pos - N.xy * dome * 0.35 * ang;
    o.refl = refl * u.filmMix;
    o.rt   = clamp(max(max(refl.r, refl.g), refl.b) * u.filmMix, 0.0, 1.0);
    o.keep = (1.0 - o.rt) * u.contentAlpha;
    o.mask = mask;
    o.dead = false;
    return o;
}

/// src 是预乘色。反射掉的部分不再透过内容；膜本身以 rt 的覆盖度叠加。
/// alpha < 1，所以背景会从破口和薄处透出来。
inline half4 filmComposite(half4 src, FilmShade s) {
    if (s.dead) { return half4(0.0h); }
    half3 rgb = clamp(src.rgb * half(s.keep) + half3(s.refl), 0.0h, 1.0h);
    half  a   = clamp(src.a   * half(s.keep) + half(s.rt),    0.0h, 1.0h);
    return half4(rgb, a) * half(s.mask);
}

// MARK: - 墨水

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
