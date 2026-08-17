//
//  ShatterModel.swift
//  ios-lab
//
//  两条渲染路线共用的动画模型：时间线、破裂点与行程、液滴的分布。
//
//  这些必须是同一份实现，尤其是 `frontReach` —— 着色器算前沿位置、液滴算出生时刻，
//  两边用的是同一个行程；公式一旦分叉，液滴就会和前沿脱节。
//
//  液滴在这里只描述「归一化的一颗」（出生点相对 halfSize、速度相对前沿推进速度），
//  解析成实际像素由各条路线自己做：SwiftUI 在 Canvas 里逐帧算，UIKit 一次性传给 GPU。
//

import SwiftUI

// MARK: - 时间线

/// 把「距离点击过去了多久」翻译成 shader 需要的一组参数。elapsed < 0 表示还没点。
struct ShatterStage {
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
        frontT = ((elapsed - c.revealDuration) / max(c.shatterDuration, 0.001)).clampedUnit

        // 排液：整个破裂过程里膜持续变薄，颜色带会随之扫过一遍
        let drain = (elapsed / max(c.revealDuration + c.shatterDuration, 0.001)).clampedUnit
        thickness = c.film.thicknessNM.upperBound
            + (c.film.thicknessNM.lowerBound - c.film.thicknessNM.upperBound) * drain
    }
}

extension Double {
    var clampedUnit: Double { Swift.min(1, Swift.max(0, self)) }
}

// MARK: - 几何

/// 破裂点。跟手时就是手指点到的位置（内容局部坐标），否则按 seed 随机取一点。
/// shader 和液滴 Canvas 各自的坐标系不同，但 `center - halfSize` 都是内容的左上角，
/// 所以同一个函数能服务两边。
func nucleusPoint(center: CGPoint, halfSize: CGSize,
                          tap: CGPoint?, seed: UInt64) -> CGPoint {
    if let tap {
        return CGPoint(x: center.x - halfSize.width + tap.x,
                       y: center.y - halfSize.height + tap.y)
    }
    var rng = SplitMix64(state: seed &* 6_364_136_223_846_793_005 &+ 1)
    return CGPoint(x: center.x + CGFloat(Float.random(in: -0.6...0.6, using: &rng)) * halfSize.width,
                   y: center.y + CGFloat(Float.random(in: -0.6...0.6, using: &rng)) * halfSize.height)
}

func domeDepth(_ inner: CGSize, _ c: ShatterConfig) -> CGFloat {
    min(min(inner.width, inner.height) * c.film.domeDepth, 30)
}

/// 前沿扫完整个视图的行程。必须和 shader 里算得一模一样，
/// 否则液滴的出生时刻会和前沿的位置对不上。
func frontReach(nucleus: CGPoint, center: CGPoint, halfSize: CGSize,
                        config c: ShatterConfig) -> CGFloat {
    let vn = CGPoint(x: nucleus.x - center.x, y: nucleus.y - center.y)
    let far = CGPoint(x: vn.x > 0 ? -halfSize.width : halfSize.width,
                      y: vn.y > 0 ? -halfSize.height : halfSize.height)
    let base = hypot(far.x - vn.x, far.y - vn.y) + c.cornerRadius
    switch c.style {
    case .soapFilm:
        return base + domeDepth(CGSize(width: halfSize.width * 2,
                                       height: halfSize.height * 2), c)
    case .inkSplat:
        let scale = hypot(halfSize.width, halfSize.height)
        return base * (1 + c.ink.lobe) + CGFloat(c.ink.warp) * scale
    }
}

// MARK: - 液滴

/// 崩解喷出的一颗液滴。出生点按 halfSize 归一化到 [-1,1]²，出生时刻在绘制时
/// 由「它到破裂点的距离 ÷ 行程」现算 —— 生成时还不知道视图多大。
struct ShatterDroplet {
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
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func makeDroplets(count: Int, style: ShatterStyle, seed: UInt64) -> [ShatterDroplet] {
    var rng = SplitMix64(state: seed | 1)
    let inky = style == .inkSplat
    return (0..<count).map { i in
        // 大颗的是少数：尺寸走幂律。均匀分布会让整片喷溅看起来像撒了一把药丸。
        // 墨水的“细”颗粒比例低一些 —— 斯普拉遁的墨点是一颗颗看得清的圆疙瘩，
        // 不是水雾，糊成一片就没有那个卡通味了。
        let fine = inky ? (i % 2 == 0) : (i % 3 != 0)
        let sizeRoll = Float.random(in: 0...1, using: &rng)
        return ShatterDroplet(
            origin: SIMD2(Float.random(in: -1...1, using: &rng),
                          Float.random(in: -1...1, using: &rng)),
            angleJitter: Float.random(in: -0.45...0.45, using: &rng),
            speedFactor: fine ? Float.random(in: 0.50...1.55, using: &rng)
                              : Float.random(in: 0.45...1.10, using: &rng),
            sizeFactor: inky
                ? (fine ? 0.26 + pow(sizeRoll, 1.6) * 0.62 : 0.85 + pow(sizeRoll, 2.4) * 3.3)
                : (fine ? 0.08 + pow(sizeRoll, 2.0) * 0.26 : 0.25 + pow(sizeRoll, 2.2) * 1.05),
            life: inky ? Float.random(in: 0.34...0.80, using: &rng)
                       : (fine ? Float.random(in: 0.10...0.22, using: &rng)
                               : Float.random(in: 0.24...0.55, using: &rng)),
            drag: inky ? Float.random(in: 1.1...2.6, using: &rng)
                       : (fine ? Float.random(in: 4.5...10, using: &rng)
                               : Float.random(in: 2.0...5.0, using: &rng)),
            hue: Float.random(in: 0...1, using: &rng),
            isFine: fine
        )
    }
}

// MARK: - 小工具

extension Color {
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
