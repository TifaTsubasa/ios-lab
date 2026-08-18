//
//  SoapFilmStitchable.metal
//  ios-lab
//
//  皂膜的 SwiftUI 入口。逐像素的形态与配色全在同目录的 SoapFilmCore.h 里，
//  这里只负责把 SwiftUI 传进来的散装参数装进 uniforms，并用 `SwiftUI::Layer` 采样内容。
//  UIKit 那条路线的入口是 SoapFilmFragment.metal，调用的是同一套核心。
//
//  参数是怎么打包进来的见 SoapFilm.swift 的 `shader(...)`。
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
#include "SoapFilmCore.h"
using namespace metal;

/// center     膜（也就是宿主视图）的中心，视图坐标 pt
/// halfSize   宿主内容的半宽高
/// shape      x = 圆角半径, y = 边缘曲面带的进深
/// anim       x = frontT(0...1 破裂进度), y = 内容残留 alpha,
///            z = 膜的整体强度,          w = 膜厚 nm
/// nucleus    破裂起始点（视图坐标 pt），跟手时就是手指点到的位置
[[ stitchable ]] half4 soapFilm(float2 pos,
                                SwiftUI::Layer layer,
                                float2 center,
                                float2 halfSize,
                                float2 shape,
                                float4 anim,
                                float2 nucleus,
                                float time)
{
    shatter::FilmUniforms u;
    u.center       = center;
    u.halfSize     = halfSize;
    u.nucleus      = nucleus;
    u.corner       = shape.x;
    u.dome         = shape.y;
    u.frontT       = anim.x;
    u.contentAlpha = anim.y;
    u.filmMix      = anim.z;
    u.thicknessNM  = anim.w;
    u.time         = time;

    shatter::FilmShade s = shatter::filmShade(pos, u);
    if (s.dead) { return half4(0.0h); }
    return shatter::filmComposite(layer.sample(s.samplePos), s);
}
