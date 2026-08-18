//
//  ShatterModel.swift
//  ios-lab
//
//  两条渲染路线共用的动画模型：时间线、几何、液滴的分布与运动。
//  和具体效果无关的那部分都在这儿；效果专属的部分通过 `ShatterEffect` 回调出去。
//

import SwiftUI

// MARK: - 时间线

/// 把「距离点击过去了多久」翻译成 shader 需要的一组参数。elapsed < 0 表示还没点。
///
/// 皂膜专属的两项（filmMix / thickness）也在这里算：它们要跟 reveal 和排液
/// 共用同一条时间轴，拆出去反而要把整条时间轴复制一遍。别的效果忽略即可。
nonisolated struct ShatterStage {
    var frontT = 0.0            // 前沿进度 0...1
    var contentAlpha = 1.0
    var filmMix = 0.0
    var thickness = 0.0
    var elapsed = -1.0

    var isActive: Bool { elapsed >= 0 }

    init(elapsed: Double, config c: ShatterConfig) {
        self.elapsed = elapsed
        thickness = c.film.thicknessNM.upperBound
        filmMix = c.film.idleFilm
        guard elapsed >= 0 else { return }

        // 起手：easeOut，一下就亮起来
        let raw = min(1, elapsed / max(c.revealDuration, 0.001))
        let reveal = 1 - pow(1 - raw, 3)

        filmMix = c.film.idleFilm + (c.film.strength - c.film.idleFilm) * reveal
        contentAlpha = 1 - (1 - c.film.contentFade) * reveal

        // 前沿从第一帧就开始推进，reveal 只是叠在上面的一层渐变，两者**并行**。
        // 曾经是串行的（减掉 revealDuration 再除），结果头 100ms 里 frontT 恒等于 0：
        // 墨水那边画面纹丝不动，皂膜那边只是膜亮了一点、视图并没有开始破。
        // 实测这段空窗占了「点击到有反应」总延迟的 75–95%，读起来就是卡了一下。
        frontT = (elapsed / max(c.shatterDuration, 0.001)).clampedUnit

        // 排液：整个破裂过程里膜持续变薄，颜色带会随之扫过一遍
        let drain = (elapsed / max(c.revealDuration + c.shatterDuration, 0.001)).clampedUnit
        thickness = c.film.thicknessNM.upperBound
            + (c.film.thicknessNM.lowerBound - c.film.thicknessNM.upperBound) * drain
    }
}

nonisolated extension Double {
    var clampedUnit: Double { Swift.min(1, Swift.max(0, self)) }
}

// MARK: - 几何

/// 一次碎裂的几何：内容中心、半宽高、破裂点、前沿行程。
///
/// 同一次动画会在不同坐标系里建好几个（着色器按 effectPadding 留边，
/// 液滴按 sprayMargin 留边），但只要 seed 和 tap 一样，破裂点在内容里的相对位置
/// 就是同一个 —— `center - halfSize` 都是内容的左上角。
nonisolated struct ShatterGeometry {
    let center: CGPoint
    let halfSize: CGSize
    let nucleus: CGPoint
    /// 前沿扫完整个视图的行程。着色器算前沿位置、液滴算出生时刻，用的是这同一个数。
    let reach: CGFloat
    let seed: UInt64

    /// 内容的完整尺寸
    var contentSize: CGSize {
        CGSize(width: halfSize.width * 2, height: halfSize.height * 2)
    }

    /// 给着色器里的噪声/瓣换个相位。取 [0,1) 就够，别把大数喂进 shader。
    var phase: Float { Float(seed % 1000) / 1000 }

    /// 前沿的推进速度（pt/s）
    func frontSpeed(_ config: ShatterConfig) -> CGFloat {
        reach / config.shatterDuration
    }

    init(center: CGPoint, halfSize: CGSize, tap: CGPoint?, seed: UInt64, config: ShatterConfig) {
        self.center = center
        self.halfSize = halfSize
        self.seed = seed

        // 破裂点：跟手时就是手指点到的位置（内容局部坐标），否则按 seed 随机取一点
        if let tap {
            nucleus = CGPoint(x: center.x - halfSize.width + tap.x,
                              y: center.y - halfSize.height + tap.y)
        } else {
            var rng = SplitMix64(state: seed &* 6_364_136_223_846_793_005 &+ 1)
            nucleus = CGPoint(
                x: center.x + CGFloat(Float.random(in: -0.6...0.6, using: &rng)) * halfSize.width,
                y: center.y + CGFloat(Float.random(in: -0.6...0.6, using: &rng)) * halfSize.height)
        }

        // 基准行程 = 破裂点到最远那个角 + 圆角。效果可以再放大（瓣、球冠）。
        let vn = CGPoint(x: nucleus.x - center.x, y: nucleus.y - center.y)
        let far = CGPoint(x: vn.x > 0 ? -halfSize.width : halfSize.width,
                          y: vn.y > 0 ? -halfSize.height : halfSize.height)
        let base = hypot(far.x - vn.x, far.y - vn.y) + config.cornerRadius
        reach = config.style.effect.frontReach(base: base, halfSize: halfSize, config: config)
    }
}

// MARK: - 液滴

/// 崩解喷出的一颗液滴。出生点按 halfSize 归一化到 [-1,1]²，出生时刻在绘制时
/// 由「它到破裂点的距离 ÷ 行程」现算 —— 生成时还不知道视图多大。
nonisolated struct ShatterDroplet {
    var origin: SIMD2<Float>
    var angleJitter: Float      // 相对“背离破裂点”的偏角（弧度）
    var speedFactor: Float      // × 前沿推进速度 = 初速
    var sizeFactor: Float
    var life: Float
    var drag: Float
    var hue: Float
    var isFine: Bool            // 皂膜里是细雾，墨水里是小墨点
}

/// 可复现的 SplitMix64，保证同一个 seed 每帧生成同一批液滴
nonisolated struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 一整批液滴。每颗长什么样由效果自己定（见 `ShatterEffect.makeDroplet`）。
nonisolated func makeDroplets(count: Int, style: ShatterStyle, seed: UInt64) -> [ShatterDroplet] {
    var rng = SplitMix64(state: seed | 1)
    let effect = style.effect
    return (0..<count).map { effect.makeDroplet(index: $0, rng: &rng) }
}

/// 线性阻力 + 重力下的解析解：x = v₀·(1-e^{-kτ})/k, y 再加 g·(τ-(1-e^{-kτ})/k)/k
///
/// UIKit 路线在顶点着色器里（`dropAdvance`）用的是同一个式子，改这儿记得改那儿。
nonisolated func dropletAdvance(_ p: CGPoint, _ v0: CGVector, _ t: Double,
                    drag k: CGFloat, gravity g: CGFloat) -> CGPoint {
    let tau = CGFloat(t)
    let ek = (1 - exp(-k * tau)) / k
    return CGPoint(x: p.x + v0.dx * ek,
                   y: p.y + v0.dy * ek + g * (tau - ek) / k)
}

// MARK: - 小工具

nonisolated extension Color {
    /// 压暗到原来的 f，用来给小墨点做层次
    func shadedInk(_ f: Double) -> Color {
        let c = UIColor(self)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard c.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return Color(hue: h, saturation: min(1, s * 1.06), brightness: b * f, opacity: a)
    }

    /// 拆成 shader 要的 RGBA。alpha 单独给，方便把「这颗液滴多不透明」塞进 color.a。
    func rgbaComponents(alpha: Float) -> SIMD4<Float> {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4(Float(r), Float(g), Float(b), alpha)
    }
}
