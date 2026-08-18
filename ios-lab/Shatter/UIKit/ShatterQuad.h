//
//  ShatterQuad.h
//  ios-lab
//
//  UIKit 路线的 fragment 契约。每种效果在自己的 Effects/<Name>/<Name>Fragment.metal 里
//  实现一个这样的 fragment 函数，再把函数名报给 Swift 侧的 `fragmentFunctionName`：
//
//      fragment half4 xxxFragment(ShatterQuadOut in [[stage_in]],
//                                 texture2d<half> src [[texture(0)]],
//                                 constant shatter::XxxUniforms& u [[buffer(0)]])
//
//  `src` 只盖住**内容矩形**，不是整张画布（画布被 sprayMargin 撑大 7 倍，
//  全截下来纯浪费）。所以别用 pt/viewSize 采样，用 shatterContentUV()。
//
//  顶点着色器（shatterQuadVertex）是通用的，在 UIKitShatterKernels.metal 里，
//  所有效果共用，不需要各写一份。
//

#pragma once
#include <metal_stdlib>
using namespace metal;

/// 快照纹理的采样器。address::clamp_to_zero：内容之外一律透明，
/// 别用 clamp_to_edge，否则边缘像素会被拉成一条条色带。
constexpr sampler kShatterSrcSampler(filter::linear, address::clamp_to_zero);

struct ShatterQuadOut {
    float4 position [[position]];
    float2 pt;              // 视图坐标（pt，y 向下，和 UIKit 一致）
};

/// 视图坐标 → 快照纹理的 uv。快照只覆盖内容矩形，而 uniforms 里的
/// center/halfSize 正好描述这个矩形，不用另外传。
/// 采样器是 clamp_to_zero，落到矩形外自然透明。
inline float2 shatterContentUV(float2 pt, float2 center, float2 halfSize) {
    return (pt - (center - halfSize)) / (2.0 * halfSize);
}
