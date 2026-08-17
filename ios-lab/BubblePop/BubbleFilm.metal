//
//  BubbleFilm.metal
//  ios-lab
//
//  肥皂泡膜着色器：把宿主视图本身当成一层绷在圆角矩形上的皂膜，并负责“破裂”本身。
//  视图不会先鼓成球 —— 它保持自己的形状，直接从被点到的那一点破开。
//
//  物理依据（都做了适度简化，但形态是照着真实现象来的）：
//  1. 薄膜干涉：膜的上下表面反射光程差 Δ = 2·n·d·cosθt，前表面反射额外有 π 相移，
//     所以反射强度 ∝ sin²(π·Δ/λ)。d→0 时全波长相消 —— 这就是泡泡破裂前
//     出现的“黑膜”。三个波长采样 (680/545/445 nm) 就能得到很接近实拍的皂膜色。
//  2. 重力排液：膜顶薄底厚，颜色带因此是横向分层的，并随时间整体变薄。
//  3. Taylor–Culick：膜一旦穿孔，孔洞沿膜面以恒定速度扩张（半径随时间线性增长），
//     被“吃掉”的膜液全部聚集在孔缘形成一圈增厚的卷边 —— 视觉上是一道亮环。
//
//  膜不是平板：由圆角矩形的 SDF 生成一圈球冠状的高度场，所以边缘有真实的曲面带，
//  掠射角在那里迅速抬高，菲涅尔和高光才有地方落。中间保持全平，内容不失真。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

/// 皂液折射率
constant float kIOR = 1.34;

// MARK: - 基础工具

static inline float sdRoundBox(float2 p, float2 b, float r) {
    r = min(r, min(b.x, b.y));
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

/// 格点散列。这里必须用解相关够好的版本：常见的
/// `p = fract(p*float2(127.1,311.7)); p += dot(p,p+34.23); return fract(p.x*p.y);`
/// 在相邻格点上高度相关，噪声里会留下沿坐标轴排列的结构。平时看不出来，
/// 但膜厚要经过干涉相位（~26 rad）放大成颜色，那点结构就显形成一圈
/// **位置几乎不动、轴对齐**的矩形折痕 —— 看起来完全像是渲染 bug。
static inline float hash21(float2 p) {
    // 先把格点压回小范围：噪声坐标被 flow 推着随时间长大，到几百以上
    // float32 的 fract() 只剩两三位有效小数，散列会直接塌成阶梯。
    p = fmod(p, 256.0);
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, float3(p3.y, p3.z, p3.x) + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float vnoise(float2 p) {
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

/// 4 阶 fbm，归一化到 0...1，用来做膜厚的湍流花纹
static inline float fbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; ++i) {
        v += a * vnoise(p);
        p *= 2.03;
        a *= 0.5;
    }
    return v / 0.9375;
}

/// 薄膜双光束干涉的反射色。thickness 单位 nm，cosT 是膜内折射角余弦。
static inline float3 thinFilmColor(float thickness, float cosT) {
    const float3 lambda = float3(680.0, 545.0, 445.0);
    // I ∝ 4·cos²(φ/2)，φ = 2π·Δ/λ + π  ⇒  I ∝ sin²(π·Δ/λ)
    float3 phase = (4.0 * M_PI_F * kIOR * thickness * cosT) / lambda;
    return 0.5 - 0.5 * cos(phase);
}

// MARK: - 主着色器

/// center     膜（也就是宿主视图）的中心，视图坐标 pt
/// halfSize   宿主内容的半宽高
/// shape      x = 圆角半径, y = 边缘曲面带的进深
/// anim       x = popT(0...1 破裂进度), y = 内容残留 alpha,
///            z = 膜的整体强度,        w = 膜厚 nm
/// nucleus    破裂起始点（视图坐标 pt），跟手时就是手指点到的位置
[[ stitchable ]] half4 bubbleFilm(float2 pos,
                                  SwiftUI::Layer layer,
                                  float2 center,
                                  float2 halfSize,
                                  float2 shape,
                                  float4 anim,
                                  float2 nucleus,
                                  float time)
{
    float corner  = shape.x;
    float dome    = max(shape.y, 1.0);
    float popT    = anim.x;
    float cAlpha  = anim.y;
    float filmMix = anim.z;
    float baseNM  = anim.w;

    float2 v = pos - center;

    float d = sdRoundBox(v, halfSize, corner);
    if (d > 1.5) { return half4(0.0h); }

    // 有限差分取 SDF 梯度，得到膜面的“朝外”方向
    const float e = 0.9;
    float2 grad = float2(sdRoundBox(v + float2(e, 0.0), halfSize, corner)
                       - sdRoundBox(v - float2(e, 0.0), halfSize, corner),
                         sdRoundBox(v + float2(0.0, e), halfSize, corner)
                       - sdRoundBox(v - float2(0.0, e), halfSize, corner));
    grad = (length(grad) > 1e-5) ? normalize(grad) : float2(0.0, -1.0);

    // 由 SDF 生成球冠高度场，只在离边缘 dome 以内的一圈里弯曲，更里面膜是全平的。
    //
    // 曲面带到平面的接缝必须“无限平滑”。直接用 s = 1-u（正球冠）时 s 在 u=1 处
    // 斜率是 -1，掠射角 ang≈s²/2 的二阶导在那里跳变；干涉色对角度极其敏感，
    // 这点跳变会被放大成一条清清楚楚的矩形亮边 —— 而且因为圆角矩形 SDF 在内部
    // 退化成 max(q.x,q.y)，那条等值线是**尖角**矩形，看起来就更像 bug。
    // 换成 smoothstep 后 s≈3(1-u)²，ang 以四次方趋零，接缝彻底看不见了。
    float u  = clamp(-d / dome, 0.0, 1.0);
    float s  = 1.0 - smoothstep(0.0, 1.0, u);
    float ht = sqrt(max(2e-3, 1.0 - s * s));
    float3 N = normalize(float3(grad * (s / ht), 1.0));

    float mask = 1.0 - smoothstep(-0.6, 1.0, d);

    // ---- 破裂：孔洞从 nucleus 沿膜面扩张 ----
    float3 P = float3(v, ht * dome);
    float2 vn = nucleus - center;
    float sn = 1.0 - smoothstep(0.0, 1.0, clamp(-sdRoundBox(vn, halfSize, corner) / dome, 0.0, 1.0));
    float3 P0 = float3(vn, sqrt(max(2e-3, 1.0 - sn * sn)) * dome);

    // 行程 = 破裂点到最远那个角的距离。破裂点越偏，孔洞要跑的路越长，
    // 但 popT 走完一整趟的时间不变 —— 靠边点会破得更快，跟真实观感一致。
    float2 far = float2(vn.x > 0.0 ? -halfSize.x : halfSize.x,
                        vn.y > 0.0 ? -halfSize.y : halfSize.y);
    float reach = length(far - vn) + corner + dome;

    float geo   = distance(P, P0);
    float holeR = popT * reach;                 // Taylor–Culick：半径随时间线性增长
    float rimW  = max(2.0, min(halfSize.x, halfSize.y) * 0.055);

    // popT 为 0 时整块膜都得完好无损。少了这层判断，holeR=0 的 smoothstep
    // 会在破裂点上抠掉一个亚点级的小洞，静止时就是一个莫名其妙的针孔。
    float rim = 0.0;
    if (popT > 0.0) {
        mask *= smoothstep(holeR - 0.8, holeR + 0.8, geo);
        if (mask <= 0.002) { return half4(0.0h); }
        rim = exp(-pow((geo - holeR) / rimW, 2.0));
    }

    // ---- 膜厚 ----
    // 花纹按视图空间位置采样，不能按法线 —— 膜中间是平的，法线在那儿处处相同，
    // 拿法线当坐标的话整片中央会是一个死板的纯色。
    float2 tuv = v / max(halfSize.x, halfSize.y);
    float2 flow = float2(time * 0.05, -time * 0.03);
    float turb = fbm(tuv * 3.2 + flow);
    // 厚度在**空间上**的总跨度必须压在大约一个干涉周期以内。
    // 一个周期是 Δd = λ/(2n) ≈ 445/2.68 ≈ 166 nm；跨度超了，等厚线就会在膜面上
    // 密集成一圈圈干涉条纹，而膜中间是平的、vert 又是 v.y 的线性斜坡，
    // 等厚线于是恰好是**笔直的轴对齐直线** —— 看起来就像画错了一个矩形。
    // 这不是数值瑕疵，是真实的干涉条纹，只是排得太规整，得靠压缩跨度来化掉。
    float vert = mix(0.88, 1.0, clamp(0.5 + 0.5 * (v.y / halfSize.y), 0.0, 1.0));
    float thickness = baseNM * vert * mix(0.94, 1.07, turb);
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

    // ---- 采样宿主内容 ----
    // 边缘那圈曲面把内容往里压，像玻璃倒角一样。中间 N.xy 为零，内容原样透过。
    half4 src = layer.sample(pos - N.xy * dome * 0.35 * ang);

    // ---- 合成 ----
    // 反射掉的部分不再透过内容；膜本身以 Rt 的覆盖度叠加。alpha < 1，
    // 所以页面背景会从破口和薄处透出来。
    float3 fRGB = refl * filmMix;
    float  Rt   = clamp(max(max(refl.r, refl.g), refl.b) * filmMix, 0.0, 1.0);
    float  keep = (1.0 - Rt) * cAlpha;

    half3 rgb = clamp(src.rgb * half(keep) + half3(fRGB), 0.0h, 1.0h);
    half  a   = clamp(src.a   * half(keep) + half(Rt),    0.0h, 1.0h);
    return half4(rgb, a) * half(mask);
}
