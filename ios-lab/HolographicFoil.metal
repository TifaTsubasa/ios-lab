//
//  HolographicFoil.metal
//  ios-lab
//
//  镭射全息箔面着色器：彩虹条纹 + 竖向箔纹 + 闪粉星光 + 高光扫过。
//  tilt 随陀螺仪/拖拽变化，驱动整个箔面的光泽流动。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

static inline float3 hsv2rgb(float3 c) {
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(float3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

/// 一层随机分布的星光。cell 控制密度，threshold 控制出现概率。
static inline float sparkleLayer(float2 p, float cell, float shift, float time, float threshold) {
    float2 id = floor(p / cell);
    float2 f = fract(p / cell);
    float rnd = hash21(id);
    if (rnd < threshold) { return 0.0; }
    float2 sp = float2(hash21(id + 17.1), hash21(id + 31.7)) * 0.6 + 0.2;
    float2 d = (f - sp) * cell;
    // 闪烁相位由随机数 + 倾斜量 + 时间共同驱动，倾斜时星光成片翻涌
    float tw = 0.5 + 0.5 * sin(6.28318 * (rnd * 4.0 + shift * (2.0 + rnd * 2.0)) + time * (0.8 + rnd * 1.5));
    tw = pow(tw, 18.0);
    float core = exp(-dot(d, d) * 0.30);
    float arms = exp(-fabs(d.x) * 1.2) * exp(-fabs(d.y) * 0.30)
               + exp(-fabs(d.y) * 1.2) * exp(-fabs(d.x) * 0.30);
    return (core * 1.5 + arms * 0.45) * tw;
}

/// mode: 0 极光 / 1 银彩 / 2 虹箔
[[ stitchable ]] half4 holographicFoil(float2 position, half4 color,
                                       float2 size, float2 tilt,
                                       float time, float mode) {
    float2 uv = position / size;
    float shift = tilt.x * 1.2 + tilt.y * 0.45;

    // ---- 宽幅斜向彩虹色带，随倾斜整体流动 ----
    float band = fract(uv.x * 1.05 - uv.y * 0.28 + shift);

    float hue; float sat; float bright; float whiteMix;
    if (mode > 1.5) {            // 虹箔：全饱和彩虹
        hue = band;       sat = 0.92; bright = 1.00; whiteMix = 0.02;
    } else if (mode > 0.5) {     // 银彩：低饱和淡彩 + 银白
        hue = band;       sat = 0.32; bright = 1.00; whiteMix = 0.30;
    } else {                     // 极光：绿→蓝→紫区间（三角波往返，避免回绕接缝）
        float tri = 1.0 - fabs(2.0 * band - 1.0);
        hue = 0.30 + tri * 0.55; sat = 0.78; bright = 0.96; whiteMix = 0.05;
    }
    float3 base = hsv2rgb(float3(hue, sat, bright));
    base = mix(base, float3(1.0), whiteMix);

    // ---- 细密竖向箔纹（不随倾斜移动，模拟拉丝箔材质）----
    float stripe = sin(position.x * 1.9) * 0.5 + sin(position.x * 0.83 + 1.7) * 0.5;
    base *= 0.90 + 0.10 * stripe;

    // ---- 随倾斜快速扫动的亮柱 ----
    float colShine = pow(0.5 + 0.5 * sin(position.x * 0.16 - shift * 9.0), 5.0);
    base += colShine * 0.16;

    // ---- 斜向镜面高光带 ----
    float sd = uv.x * 0.8 + uv.y * 0.45 - 0.62 - shift * 1.1;
    base += exp(-sd * sd * 22.0) * 0.32;

    // ---- 隐约的菱形织纹 ----
    float weave = sin(position.x * 0.7 + position.y * 0.7) * sin(position.x * 0.7 - position.y * 0.7);
    base *= 0.97 + 0.03 * weave;

    // ---- 闪粉星光：一层大星 + 一层碎钻 ----
    float sparkle = sparkleLayer(position, 24.0, shift, time, 0.42)
                  + sparkleLayer(position + 7.3, 9.0, shift * 1.4, time * 1.3, 0.62) * 0.8;
    base += sparkle * 1.25;

    return half4(half3(clamp(base, 0.0, 1.6)), 1.0h) * color.a;
}
