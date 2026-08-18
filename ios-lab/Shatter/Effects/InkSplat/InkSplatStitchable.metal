//
//  InkSplatStitchable.metal
//  ios-lab
//
//  墨水喷射的 SwiftUI 入口。逐像素的形态与配色全在同目录的 InkSplatCore.h 里，
//  这里只负责把 SwiftUI 传进来的散装参数装进 uniforms，并用 `SwiftUI::Layer` 采样内容。
//  UIKit 那条路线的入口是 InkSplatFragment.metal，调用的是同一套核心。
//
//  参数是怎么打包进来的见 InkSplat.swift 的 `shader(...)`。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
#include "InkSplatCore.h"
using namespace metal;

/// center    视图中心（视图坐标 pt）
/// halfSize  视图半宽高
/// shape     x = 圆角半径, y = 墨带宽度（前沿后面那圈墨有多宽）
/// anim      x = frontT(0...1 喷射进度), y = 瓣状强度,
///           z = 噪声扰动强度,           w = 随机相位
/// speckle   x = 散墨格子边长, y = 散墨比前沿提前多少 pt
/// nucleus   喷射起点（视图坐标 pt），跟手时就是手指点到的位置
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
    shatter::InkUniforms u;
    u.color       = float4(inkColor);
    u.center      = center;
    u.halfSize    = halfSize;
    u.nucleus     = nucleus;
    u.corner      = shape.x;
    u.band        = shape.y;
    u.frontT      = anim.x;
    u.lobe        = anim.y;
    u.warp        = anim.z;
    u.phase       = anim.w;
    u.speckleCell = speckle.x;
    u.speckleLead = speckle.y;

    shatter::InkShade s = shatter::inkShade(pos, u);
    if (s.dead) { return half4(0.0h); }
    return shatter::inkComposite(layer.sample(pos), s);
}
