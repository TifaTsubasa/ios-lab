//
//  InkSplatFragment.metal
//  ios-lab
//
//  墨水喷射的 UIKit 入口。和 SwiftUI 那边（InkSplatStitchable.metal）唯一的区别是
//  **内容从哪儿来**：那边由 `SwiftUI::Layer` 提供，这边是宿主视图的一张快照纹理。
//  形态与配色仍然走同目录的 InkSplatCore.h，两条路线不会各自漂移。
//

#include <metal_stdlib>
#include "../../UIKit/ShatterQuad.h"
#include "InkSplatCore.h"
using namespace metal;

fragment half4 shatterInkFragment(ShatterQuadOut in [[stage_in]],
                                  texture2d<half> src [[texture(0)]],
                                  constant shatter::InkUniforms& u [[buffer(0)]],
                                  constant float2& viewSize [[buffer(1)]])
{
    shatter::InkShade s = shatter::inkShade(in.pt, u);
    if (s.dead) { return half4(0.0h); }
    // 墨不折射内容，原位采样就行
    half4 c = src.sample(kShatterSrcSampler, in.pt / viewSize);
    return shatter::inkComposite(c, s);
}
