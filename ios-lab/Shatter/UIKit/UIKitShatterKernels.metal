//
//  UIKitShatterKernels.metal
//  ios-lab
//
//  UIKit 路线的渲染管线。和 SwiftUI 路线唯一的区别是**内容从哪儿来**：
//  那边由 `SwiftUI::Layer` 提供，这边是宿主视图的一张快照纹理。
//  每像素的形态与配色仍然走 Shared/ShatterCore.h，两条路线不会各自漂移。
//
//  液滴这边也不一样：SwiftUI 那边用 Canvas 逐帧在 CPU 上画，这边直接做成
//  实例化的四边形 —— 每颗液滴的参数一次性传上去，之后每帧只变一个时间标量，
//  位置在顶点着色器里算，CPU 全程不参与。
//

#include <metal_stdlib>
#include "../Shared/ShatterCore.h"
using namespace metal;

constexpr sampler kSrcSampler(filter::linear, address::clamp_to_zero);

// MARK: - 全屏三角形

struct QuadOut {
    float4 position [[position]];
    float2 pt;              // 视图坐标（pt，y 向下，和 UIKit 一致）
};

/// 一个盖住全屏的大三角形，比四边形少一次顶点调用，也没有对角线接缝
vertex QuadOut shatterQuadVertex(uint vid [[vertex_id]],
                                 constant float2& viewSize [[buffer(0)]])
{
    float2 uv = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    QuadOut o;
    // uv.y = 0 要落在屏幕**上**边，所以 y 取负 —— 这样 pt 就是 y 向下的 UIKit 坐标
    o.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.pt = uv * viewSize;
    return o;
}

fragment half4 shatterFilmFragment(QuadOut in [[stage_in]],
                                   texture2d<half> src [[texture(0)]],
                                   constant shatter::FilmUniforms& u [[buffer(0)]],
                                   constant float2& viewSize [[buffer(1)]])
{
    shatter::FilmShade s = shatter::filmShade(in.pt, u);
    if (s.dead) { return half4(0.0h); }
    half4 c = src.sample(kSrcSampler, s.samplePos / viewSize);
    return shatter::filmComposite(c, s);
}

fragment half4 shatterInkFragment(QuadOut in [[stage_in]],
                                  texture2d<half> src [[texture(0)]],
                                  constant shatter::InkUniforms& u [[buffer(0)]],
                                  constant float2& viewSize [[buffer(1)]])
{
    shatter::InkShade s = shatter::inkShade(in.pt, u);
    if (s.dead) { return half4(0.0h); }
    half4 c = src.sample(kSrcSampler, in.pt / viewSize);
    return shatter::inkComposite(c, s);
}

// MARK: - 液滴

/// 布局要和 UIKitShatter.swift 里的 `DropletGPU` 严格对上：
/// 显式补到 64 字节，不依赖编译器的补位规则
struct DropletGPU {
    float4 color;     // 未预乘
    float2 origin;    // 出生点（视图坐标 pt）
    float  angle;     // 飞行方向
    float  speed;     // 初速 pt/s
    float  radius;    // 核半径 pt
    float  birth;     // 出生时刻（秒，相对前沿开始）
    float  life;      // 寿命（秒）
    float  drag;      // 线性阻力系数
    float  spread;    // 四边形要比核半径胖多少倍（皂膜有光晕，要留出来）
    float  trail;     // 拖尾时长（秒）
    float  pad0, pad1;
};

struct DropUniforms {
    float2 viewSize;
    float  t;         // 距前沿开始的秒数
    float  gravity;
    float  style;     // 0 皂膜 / 1 墨水
    float  pad0, pad1, pad2;
};

struct DropOut {
    float4 position [[position]];
    float2 cap;       // 胶囊局部坐标（pt）：x 沿运动方向，y 垂直
    float  halfSeg;   // 线段半长
    float  radius;
    float  alpha;
    float  style;
    half3  rgb;
};

/// 线性阻力 + 重力下的解析解，和 Swift 端 `advance` 是同一个式子
static inline float2 dropAdvance(float2 p, float2 v0, float t, float k, float g) {
    float ek = (1.0 - exp(-k * t)) / k;
    return float2(p.x + v0.x * ek, p.y + v0.y * ek + g * (t - ek) / k);
}

vertex DropOut shatterDropletVertex(uint vid [[vertex_id]],
                                    uint iid [[instance_id]],
                                    const device DropletGPU* drops [[buffer(0)]],
                                    constant DropUniforms& u [[buffer(1)]])
{
    DropletGPU d = drops[iid];
    DropOut o;
    o.cap = float2(0.0); o.halfSeg = 0.0; o.radius = 0.0;
    o.alpha = 0.0; o.style = u.style; o.rgb = half3(0.0h);

    float age = u.t - d.birth;
    if (age <= 0.0 || age >= d.life) {
        o.position = float4(-4.0, -4.0, 0.0, 1.0);   // 退化到裁剪空间外，直接被剔掉
        return o;
    }

    float2 v0 = float2(cos(d.angle), sin(d.angle)) * d.speed;
    float2 now = dropAdvance(d.origin, v0, age, d.drag, u.gravity);
    float2 was = dropAdvance(d.origin, v0, max(0.0, age - d.trail), d.drag, u.gravity);

    float k = age / d.life;
    float radius = d.radius;
    float alpha;
    if (u.style > 0.5) {
        // 墨：始终不透明，快到寿命尽头才收缩。渐隐会让它从墨变成水花。
        float sh = 1.0 - clamp((k - 0.62) / 0.38, 0.0, 1.0);
        radius *= sh;
        alpha = 1.0;
    } else {
        // 水光：一直亮着，然后突然没了
        alpha = min(1.0, age / 0.012) * pow(1.0 - k, 0.7);
    }
    alpha *= d.color.a;      // 每颗的固有不透明度（皂膜细雾压到 0.7）
    if (radius <= 0.3 || alpha <= 0.002) {
        o.position = float4(-4.0, -4.0, 0.0, 1.0);
        return o;
    }

    float2 mid = (now + was) * 0.5;
    float2 seg = now - was;
    float  len = length(seg);
    float2 ax = (len > 1e-4) ? seg / len : float2(1.0, 0.0);
    float2 ay = float2(-ax.y, ax.x);

    float expand  = radius * d.spread;
    float halfSeg = len * 0.5;
    float halfLen = halfSeg + expand;

    // 两个三角形拼一个矩形，刚好套住这条胶囊
    const float2 corner[6] = { float2(-1, -1), float2( 1, -1), float2(-1,  1),
                               float2( 1, -1), float2( 1,  1), float2(-1,  1) };
    float2 c = corner[vid];
    float2 local = float2(c.x * halfLen, c.y * expand);
    float2 pt = mid + ax * local.x + ay * local.y;

    o.position = float4(pt / u.viewSize * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    o.cap     = local;
    o.halfSeg = halfSeg;
    o.radius  = radius;
    o.alpha   = alpha;
    o.rgb     = half3(d.color.rgb);
    return o;
}

fragment half4 shatterDropletFragment(DropOut in [[stage_in]])
{
    // 到线段的距离 = 胶囊 SDF
    float dx = max(abs(in.cap.x) - in.halfSeg, 0.0);
    float dist = length(float2(dx, in.cap.y));

    float core = 1.0 - smoothstep(in.radius - 0.7, in.radius + 0.3, dist);
    float a;
    if (in.style > 0.5) {
        a = core * in.alpha;                       // 墨：干脆的实心边
    } else {
        // 水光：一道很淡的光晕托底，再压一道实心的
        float halo = 1.0 - smoothstep(in.radius * 1.5 - 0.8, in.radius * 1.5 + 0.4, dist);
        a = (core + halo * 0.18) * in.alpha;
    }
    if (a <= 0.002) { return half4(0.0h); }
    a = min(a, 1.0);
    return half4(in.rgb * half(a), half(a));       // 预乘
}
