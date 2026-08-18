//
//  SoapFilmFragment.metal
//  ios-lab
//
//  皂膜的 UIKit 入口。和 SwiftUI 那边（SoapFilmStitchable.metal）唯一的区别是
//  **内容从哪儿来**：那边由 `SwiftUI::Layer` 提供，这边是宿主视图的一张快照纹理。
//  形态与配色仍然走同目录的 SoapFilmCore.h，两条路线不会各自漂移。
//

#include <metal_stdlib>
#include "../../UIKit/ShatterQuad.h"
#include "SoapFilmCore.h"
using namespace metal;

fragment half4 shatterFilmFragment(ShatterQuadOut in [[stage_in]],
                                   texture2d<half> src [[texture(0)]],
                                   constant shatter::FilmUniforms& u [[buffer(0)]],
                                   constant float2& viewSize [[buffer(1)]])
{
    shatter::FilmShade s = shatter::filmShade(in.pt, u);
    if (s.dead) { return half4(0.0h); }
    // 皂膜要按 samplePos 采样：边缘那圈曲面把内容往里压
    half4 c = src.sample(kShatterSrcSampler, s.samplePos / viewSize);
    return shatter::filmComposite(c, s);
}
