//
//  ShatterShading.h
//  ios-lab
//
//  和具体效果无关的着色工具：形状 SDF、散列、噪声。
//  各效果的核心（Effects/<Name>/<Name>Core.h）都从这里取料。
//
//  这里的两条注意事项是踩过坑的，新增效果时照抄就行：散列要解相关够好的，
//  噪声插值要 C² 的 —— 只要噪声结果会被非线性放大（干涉相位、位移场之类），
//  这两点里任何一点不到位都会显形成轴对齐的矩形折痕，看起来完全像渲染 bug。
//

#pragma once
#include <metal_stdlib>
using namespace metal;

namespace shatter {

// MARK: - 形状

inline float sdRoundBox(float2 p, float2 b, float r) {
    r = min(r, min(b.x, b.y));
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// MARK: - 散列与噪声

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

} // namespace shatter
