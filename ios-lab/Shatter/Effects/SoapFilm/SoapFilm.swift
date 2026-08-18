//
//  SoapFilm.swift
//  ios-lab
//
//  皂膜效果：参数，以及两条渲染路线的胶水。
//  逐像素的形态与配色在同目录的 SoapFilmCore.h，这里只负责把参数喂进去。
//
//  物理上想还原的是「肥皂膜破裂」：薄膜干涉出彩虹、重力排液让上薄下厚、
//  Taylor–Culick 定律让孔洞半径线性增长、排掉的液体聚在卷边上。
//

import SwiftUI
import Metal
import QuartzCore

// MARK: - 参数

nonisolated struct SoapFilmParams {
    /// 边缘曲面带的进深 = 该系数 × 视图短边（上限 30pt）。
    /// 膜中间是平的，只有靠边这一圈会弯，掠射角在那里抬高，虹彩和高光才有地方落。
    var domeDepth: CGFloat = 0.22
    /// 未点击时的膜强度。0 = 完全是原视图，0.2 左右能看出一层薄薄的皂膜感
    var idleFilm: Double = 0.22
    /// 破裂时的膜强度。皂膜正入射反射率只有百分之几，要让虹彩在屏幕上读得出来
    /// 得当成“被打了光”，所以这里可以大于 1
    var strength: Double = 1.15
    /// 破裂时内容还剩多少。这是「视图碎掉」不是「视图变泡泡」，所以默认几乎全留
    var contentFade: Double = 0.85
    /// 膜厚区间（nm），从上界排液到下界；越薄颜色越冷、越接近黑膜。
    /// 注意**空间上**的跨度另有约束，见 SoapFilmCore.h 里 `thickness` 那段注释
    var thicknessNM: ClosedRange<Double> = 300...700
    /// 未点击时也让膜纹持续流动。开着的话每个泡泡都会常驻 60fps，页面上摆多了很费电，
    /// 而且静止时本来也看不出流动，所以默认关。
    var idleShimmer: Bool = false
}

/// 对应 SoapFilmCore.h 的 `shatter::FilmUniforms`
private struct FilmUniformsGPU {
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var nucleus: SIMD2<Float>
    var corner: Float
    var dome: Float
    var frontT: Float
    var contentAlpha: Float
    var filmMix: Float
    var thicknessNM: Float
    var time: Float
    var pad: Float = 0
}

// MARK: - 效果

nonisolated enum SoapFilmEffect: ShatterEffect {

    /// 边缘曲面带的进深。着色器和行程计算都要用同一个数。
    static func domeDepth(_ contentSize: CGSize, _ c: ShatterConfig) -> CGFloat {
        min(min(contentSize.width, contentSize.height) * c.film.domeDepth, 30)
    }

    // MARK: 通用

    /// 孔洞是沿**膜面**扩张的，膜边缘那圈球冠比平面多出一段路，所以要补上进深。
    /// 和 SoapFilmCore.h 里 `reach = length(far - vn) + u.corner + dome` 对应。
    static func frontReach(base: CGFloat, halfSize: CGSize, config: ShatterConfig) -> CGFloat {
        base + domeDepth(CGSize(width: halfSize.width * 2, height: halfSize.height * 2), config)
    }

    static func drawsWhenIdle(_ config: ShatterConfig) -> Bool { config.film.idleFilm > 0 }
    static func animatesWhenIdle(_ config: ShatterConfig) -> Bool { config.film.idleShimmer }

    static func makeDroplet(index i: Int, rng: inout SplitMix64) -> ShatterDroplet {
        // 大颗的是少数：尺寸走幂律。均匀分布会让整片喷溅看起来像撒了一把药丸。
        let fine = i % 3 != 0
        let sizeRoll = Float.random(in: 0...1, using: &rng)
        return ShatterDroplet(
            origin: SIMD2(Float.random(in: -1...1, using: &rng),
                          Float.random(in: -1...1, using: &rng)),
            angleJitter: Float.random(in: -0.45...0.45, using: &rng),
            speedFactor: fine ? Float.random(in: 0.50...1.55, using: &rng)
                              : Float.random(in: 0.45...1.10, using: &rng),
            sizeFactor: fine ? 0.08 + pow(sizeRoll, 2.0) * 0.26
                             : 0.25 + pow(sizeRoll, 2.2) * 1.05,
            life: fine ? Float.random(in: 0.10...0.22, using: &rng)
                       : Float.random(in: 0.24...0.55, using: &rng),
            drag: fine ? Float.random(in: 4.5...10, using: &rng)
                       : Float.random(in: 2.0...5.0, using: &rng),
            hue: Float.random(in: 0...1, using: &rng),
            isFine: fine)
    }

    // MARK: SwiftUI 路线

    /// 参数顺序要和 SoapFilmStitchable.metal 的 `soapFilm(...)` 签名严格对上
    static func shader(geometry g: ShatterGeometry, stage: ShatterStage,
                       config c: ShatterConfig, now: Double) -> Shader {
        ShaderLibrary.soapFilm(
            .float2(Float(g.center.x), Float(g.center.y)),
            .float2(Float(g.halfSize.width), Float(g.halfSize.height)),
            .float2(Float(c.cornerRadius), Float(domeDepth(g.contentSize, c))),
            .float4(Float(stage.frontT), Float(stage.contentAlpha),
                    Float(stage.filmMix), Float(stage.thickness)),
            .float2(Float(g.nucleus.x), Float(g.nucleus.y)),
            .float(Float(now))
        )
    }

    static var dropletBlendMode: GraphicsContext.BlendMode { .plusLighter }

    /// 近白的细 streak + 高光核，叠加混合出水光
    static func drawDroplet(_ ctx: GraphicsContext, drop: ShatterDroplet,
                            origin: CGPoint, v0: CGVector, age: Double,
                            unit: CGFloat, config: ShatterConfig) {
        // 拉一段比一帧更长的轨迹当运动模糊，液滴才会是「条」而不是「粒」
        let trail = drop.isFine ? 1.0 / 26 : 1.0 / 34
        let k = CGFloat(drop.drag), g = config.gravity
        let now = dropletAdvance(origin, v0, age, drag: k, gravity: g)
        let was = dropletAdvance(origin, v0, max(0, age - trail), drag: k, gravity: g)

        let t = age / Double(drop.life)
        // 衰减压得很平：水光该是「一直亮着，然后突然没了」，
        // 用陡峭的曲线会让整片喷溅始终是半透明的灰点。
        let fade = min(1, age / 0.012) * pow(1 - t, 0.7)
        let r = max(0.45, CGFloat(drop.sizeFactor) * unit * 0.032)

        var path = Path()
        path.move(to: was)
        path.addLine(to: now)
        let hue = Double(drop.hue)
        let sat = drop.isFine ? 0.04 : 0.11
        let alpha = fade * (drop.isFine ? 0.7 : 1.0)
        // 一道很淡的光晕托底，再压一道近白的实心，水光才亮得起来
        ctx.stroke(path, with: .color(Color(hue: hue, saturation: sat * 2, brightness: 1)
                                        .opacity(alpha * 0.18)),
                   style: StrokeStyle(lineWidth: r * 3, lineCap: .round))
        ctx.stroke(path, with: .color(Color(hue: hue, saturation: sat, brightness: 1)
                                        .opacity(alpha)),
                   style: StrokeStyle(lineWidth: r * 2, lineCap: .round))

        if !drop.isFine, r > 1.2 {
            let dd = r * 0.8
            ctx.fill(Path(ellipseIn: CGRect(x: now.x - dd / 2 - r * 0.2,
                                            y: now.y - dd / 2 - r * 0.2,
                                            width: dd, height: dd)),
                     with: .color(.white.opacity(fade)))
        }
    }

    // MARK: UIKit 路线

    static var fragmentFunctionName: String { "shatterFilmFragment" }

    static func encodeUniforms(into encoder: MTLRenderCommandEncoder,
                               geometry g: ShatterGeometry, stage: ShatterStage,
                               config c: ShatterConfig) {
        var u = FilmUniformsGPU(
            center: SIMD2(Float(g.center.x), Float(g.center.y)),
            halfSize: SIMD2(Float(g.halfSize.width), Float(g.halfSize.height)),
            nucleus: SIMD2(Float(g.nucleus.x), Float(g.nucleus.y)),
            corner: Float(c.cornerRadius),
            dome: Float(domeDepth(g.contentSize, c)),
            frontT: Float(stage.frontT),
            contentAlpha: Float(stage.contentAlpha),
            filmMix: Float(stage.filmMix),
            thicknessNM: Float(stage.thickness),
            // 取模要取小：这个值会乘上流速喂给噪声坐标，太大 float32 精度不够（见 hash21）
            time: Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 60)))
        encoder.setFragmentBytes(&u, length: MemoryLayout<FilmUniformsGPU>.stride, index: 0)
    }

    /// 水光要叠加，对应 SwiftUI 那边的 `.plusLighter`
    static var dropletsAreAdditive: Bool { true }

    static func dropletInstances(for drop: ShatterDroplet, origin: CGPoint,
                                 angle: Float, speed: Float, birth: Float,
                                 unit: Float, config: ShatterConfig) -> [DropletGPU] {
        // 各项系数刻意和上面 `drawDroplet` 保持一致
        let color = Color(hue: Double(drop.hue),
                          saturation: drop.isFine ? 0.04 : 0.11,
                          brightness: 1)
            .rgbaComponents(alpha: drop.isFine ? 0.7 : 1.0)
        return [DropletGPU(color: color,
                           origin: SIMD2(Float(origin.x), Float(origin.y)),
                           angle: angle, speed: speed,
                           radius: max(0.45, drop.sizeFactor * unit * 0.032),
                           birth: birth, life: drop.life, drag: drop.drag,
                           spread: 1.5,                                  // 光晕要留出地方
                           trail: drop.isFine ? 1.0 / 26 : 1.0 / 34)]
    }
}
