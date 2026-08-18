//
//  SoapFilmCore.h
//  ios-lab
//
//  皂膜效果的着色核心：逐像素的形态与配色。两条渲染路线共用这一份。
//
//  拆成「算形态」和「合成」两步：`filmShade` 只依赖坐标，顺带给出该去哪儿采样内容；
//  `filmComposite` 拿到采样结果再出最终颜色。谁来采样由各自的入口决定 ——
//  SwiftUI 那边是 `SwiftUI::Layer`，UIKit 那边是快照纹理。详见 Shared/ShatterEffect.swift。
//

#pragma once
#include "../../Shared/ShatterShading.h"

namespace shatter {

/// 皂液折射率
constant float kIOR = 1.34;

/// 薄膜双光束干涉的反射色。thickness 单位 nm，cosT 是膜内折射角余弦。
inline float3 thinFilmColor(float thickness, float cosT) {
    const float3 lambda = float3(680.0, 545.0, 445.0);
    // I ∝ 4·cos²(φ/2)，φ = 2π·Δ/λ + π  ⇒  I ∝ sin²(π·Δ/λ)
    float3 phase = (4.0 * M_PI_F * kIOR * thickness * cosT) / lambda;
    return 0.5 - 0.5 * cos(phase);
}

/// 布局要和 SoapFilm.swift 里的 `FilmUniformsGPU` 严格对上
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
    // Swift 侧的 `SoapFilmEffect.frontReach` 必须算出同一个数。
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

} // namespace shatter
