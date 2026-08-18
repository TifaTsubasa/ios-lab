//
//  InkSplat.swift
//  ios-lab
//
//  斯普拉遁式墨水喷射：参数，以及两条渲染路线的胶水。
//  逐像素的形态与配色在同目录的 InkSplatCore.h，这里只负责把参数喂进去。
//
//  这个效果的关键不在物理而在「卡通味」：前沿要有瓣、边缘要硬、墨点要不透明。
//  任何一处做软了，立刻从「墨」变成「水花」。
//

import SwiftUI
import Metal

// MARK: - 参数

nonisolated struct InkSplatParams {
    /// 墨色。斯普拉遁的团队色都是高饱和荧光色
    var color: Color = Color(red: 0.58, green: 0.95, blue: 0.10)
    /// 前沿后面那圈墨有多宽（pt）
    var bandWidth: CGFloat = 30
    /// 前沿的瓣状强度。0 就是个圆，越大越像几团圆疙瘩粘在一起
    var lobe: Double = 0.20
    /// 前沿的噪声扰动强度（相对视图尺寸）
    var warp: Double = 0.07
    /// 提前甩出去的散墨：格子边长（pt）越小越密
    var speckleCell: CGFloat = 34
    /// 散墨比前沿提前多少 pt 出现
    var speckleLead: CGFloat = 46
}

/// 对应 InkSplatCore.h 的 `shatter::InkUniforms`
private struct InkUniformsGPU {
    var color: SIMD4<Float>
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var nucleus: SIMD2<Float>
    var corner: Float
    var band: Float
    var frontT: Float
    var lobe: Float
    var warp: Float
    var phase: Float
    var speckleCell: Float
    var speckleLead: Float
}

// MARK: - 效果

nonisolated enum InkSplatEffect: ShatterEffect {

    // MARK: 通用

    /// 瓣和噪声会把墨甩得比几何距离更远，所以要留出余量，保证 frontT=1 时
    /// 整块一定被吃干净。和 InkSplatCore.h 里的 `reach` 对应。
    static func frontReach(base: CGFloat, halfSize: CGSize, config c: ShatterConfig) -> CGFloat {
        let scale = hypot(halfSize.width, halfSize.height)
        return base * (1 + c.ink.lobe) + CGFloat(c.ink.warp) * scale
    }

    /// 墨水静止时就是原视图，不用跑 shader
    static func drawsWhenIdle(_ config: ShatterConfig) -> Bool { false }
    static func animatesWhenIdle(_ config: ShatterConfig) -> Bool { false }

    static func makeDroplet(index i: Int, rng: inout SplitMix64) -> ShatterDroplet {
        // 大颗的是少数：尺寸走幂律。“细”颗粒的比例比皂膜低 ——
        // 斯普拉遁的墨点是一颗颗看得清的圆疙瘩，不是水雾，糊成一片就没有那个卡通味了。
        let fine = i % 2 == 0
        let sizeRoll = Float.random(in: 0...1, using: &rng)
        return ShatterDroplet(
            origin: SIMD2(Float.random(in: -1...1, using: &rng),
                          Float.random(in: -1...1, using: &rng)),
            angleJitter: Float.random(in: -0.45...0.45, using: &rng),
            speedFactor: fine ? Float.random(in: 0.50...1.55, using: &rng)
                              : Float.random(in: 0.45...1.10, using: &rng),
            sizeFactor: fine ? 0.26 + pow(sizeRoll, 1.6) * 0.62
                             : 0.85 + pow(sizeRoll, 2.4) * 3.3,
            life: Float.random(in: 0.34...0.80, using: &rng),
            drag: Float.random(in: 1.1...2.6, using: &rng),
            hue: Float.random(in: 0...1, using: &rng),
            isFine: fine)
    }

    // MARK: SwiftUI 路线

    /// 参数顺序要和 InkSplatStitchable.metal 的 `inkSplat(...)` 签名严格对上
    static func shader(geometry g: ShatterGeometry, stage: ShatterStage,
                       config c: ShatterConfig, now: Double) -> Shader {
        ShaderLibrary.inkSplat(
            .float2(Float(g.center.x), Float(g.center.y)),
            .float2(Float(g.halfSize.width), Float(g.halfSize.height)),
            .float2(Float(c.cornerRadius), Float(c.ink.bandWidth)),
            .float4(Float(stage.frontT), Float(c.ink.lobe), Float(c.ink.warp), g.phase),
            .float2(Float(c.ink.speckleCell), Float(c.ink.speckleLead)),
            .float2(Float(g.nucleus.x), Float(g.nucleus.y)),
            .color(c.ink.color)
        )
    }

    /// 墨点是实心色块，叠加会让重叠处发白
    static var dropletBlendMode: GraphicsContext.BlendMode { .normal }

    /// 不透明的圆疙瘩 + 一条短尾巴 + 一两颗卫星小点。
    /// 关键是**不透明、不叠加、几乎不缩**：一旦做成半透明或者让它渐隐，
    /// 立刻就变成水花而不是墨。
    static func drawDroplet(_ ctx: GraphicsContext, drop: ShatterDroplet,
                            origin: CGPoint, v0: CGVector, age: Double,
                            unit: CGFloat, config: ShatterConfig) {
        let t = age / Double(drop.life)
        let k = CGFloat(drop.drag), g = config.gravity
        let now = dropletAdvance(origin, v0, age, drag: k, gravity: g)
        // 尾巴只留很短一截。皂膜那边靠长拖尾做运动模糊，墨点正相反 ——
        // 拖长了就成了一根根胶囊，而斯普拉遁的墨点必须是**圆疙瘩**带一点点尾巴。
        let was = dropletAdvance(origin, v0, max(0, age - 1.0 / 46), drag: k, gravity: g)
        let r = max(0.8, CGFloat(drop.sizeFactor) * unit * 0.030)

        // 快到寿命尽头才收缩消失，中间一直是实心的
        let shrink = CGFloat(1 - pow(max(0, t - 0.62) / 0.38, 1.6).clampedUnit)
        let rr = r * shrink
        guard rr > 0.3 else { return }

        // 小颗压暗一点，整片墨才有层次；不透明度始终是 1
        let color = drop.isFine
            ? config.ink.color.opacity(1).shadedInk(0.82)
            : config.ink.color

        var path = Path()
        path.move(to: was)
        path.addLine(to: now)
        ctx.stroke(path, with: .color(color),
                   style: StrokeStyle(lineWidth: rr * 2, lineCap: .round))

        // 卫星小点：真实的墨滴总是拖着几颗更小的
        if !drop.isFine {
            let ox = cos(CGFloat(drop.hue) * .pi * 2) * rr * 2.1
            let oy = sin(CGFloat(drop.hue) * .pi * 2) * rr * 2.1
            let sr = rr * 0.34
            ctx.fill(Path(ellipseIn: CGRect(x: now.x + ox - sr, y: now.y + oy - sr,
                                            width: sr * 2, height: sr * 2)),
                     with: .color(color))
        }
    }

    // MARK: UIKit 路线

    static var fragmentFunctionName: String { "shatterInkFragment" }

    static func encodeUniforms(into encoder: MTLRenderCommandEncoder,
                               geometry g: ShatterGeometry, stage: ShatterStage,
                               config c: ShatterConfig) {
        var u = InkUniformsGPU(
            color: c.ink.color.rgbaComponents(alpha: 1),
            center: SIMD2(Float(g.center.x), Float(g.center.y)),
            halfSize: SIMD2(Float(g.halfSize.width), Float(g.halfSize.height)),
            nucleus: SIMD2(Float(g.nucleus.x), Float(g.nucleus.y)),
            corner: Float(c.cornerRadius),
            band: Float(c.ink.bandWidth),
            frontT: Float(stage.frontT),
            lobe: Float(c.ink.lobe),
            warp: Float(c.ink.warp),
            phase: g.phase,
            speckleCell: Float(c.ink.speckleCell),
            speckleLead: Float(c.ink.speckleLead))
        encoder.setFragmentBytes(&u, length: MemoryLayout<InkUniformsGPU>.stride, index: 0)
    }

    /// 墨点是不透明的，走普通 source-over
    static var dropletsAreAdditive: Bool { false }

    static func dropletInstances(for drop: ShatterDroplet, origin: CGPoint,
                                 angle: Float, speed: Float, birth: Float,
                                 unit: Float, config c: ShatterConfig) -> [DropletGPU] {
        // 各项系数刻意和上面 `drawDroplet` 保持一致
        let radius = max(0.8, drop.sizeFactor * unit * 0.030)
        let base = drop.isFine ? c.ink.color.shadedInk(0.82) : c.ink.color
        let color = base.rgbaComponents(alpha: 1)

        func instance(_ o: CGPoint, _ r: Float) -> DropletGPU {
            DropletGPU(color: color, origin: SIMD2(Float(o.x), Float(o.y)),
                       angle: angle, speed: speed, radius: r,
                       birth: birth, life: drop.life, drag: drop.drag,
                       spread: 1.0,           // 边缘是硬的，不用留光晕
                       trail: 1.0 / 46)
        }

        var out = [instance(origin, radius)]

        // 大颗要挂一颗卫星小点。轨迹是原点的刚性平移，所以只要把出生点挪一下，
        // 就能得到和 SwiftUI 那边一样的相对位置。
        if !drop.isFine {
            let off = CGFloat(radius) * 2.1
            out.append(instance(CGPoint(x: origin.x + cos(CGFloat(drop.hue) * .pi * 2) * off,
                                        y: origin.y + sin(CGFloat(drop.hue) * .pi * 2) * off),
                                radius * 0.34))
        }
        return out
    }
}
