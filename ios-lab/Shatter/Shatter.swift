//
//  Shatter.swift
//  ios-lab
//
//  可复用的「视图碎掉」修饰器：点一下，视图就从被点到的那一点开始崩解。
//  两种风格，共用同一套时间线和液滴系统：
//
//  - `.soapFilm`  肥皂泡膜。视图是一层皂膜，穿孔后孔洞沿膜面扩张，卷边退缩、喷溅水光。
//  - `.inkSplat`  斯普拉遁式墨水喷射。一道有机的墨线扫过视图，糊上墨，然后整块消失。
//
//  分工：
//  - SoapFilm.metal / InkSplat.metal 负责逐像素的形态与着色。
//  - 这里负责时间线、参数动画，以及 shader 画不了的液滴 —— 它们要飞出视图边界。
//
//  液滴用 Canvas 画：按「上一帧→当前帧」拉成一段胶囊就能拿到很便宜的运动模糊，
//  比逐像素遍历上百个粒子划算得多。
//

import SwiftUI

// MARK: - 风格

enum ShatterStyle: String, CaseIterable, Identifiable {
    case soapFilm
    case inkSplat

    var id: String { rawValue }
    var title: String {
        switch self {
        case .soapFilm: return "皂膜"
        case .inkSplat: return "墨水"
        }
    }
}

// MARK: - 配置

/// 皂膜风格专属参数
struct SoapFilmParams {
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
    /// 注意**空间上**的跨度另有约束，见 SoapFilm.metal
    var thicknessNM: ClosedRange<Double> = 300...700
    /// 未点击时也让膜纹持续流动。开着的话每个泡泡都会常驻 60fps，页面上摆多了很费电，
    /// 而且静止时本来也看不出流动，所以默认关。
    var idleShimmer: Bool = false
}

/// 墨水风格专属参数
struct InkSplatParams {
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

struct ShatterConfig {
    var style: ShatterStyle = .soapFilm

    /// 宿主视图的圆角，要和它自己的 clipShape 对上，否则轮廓会错位
    var cornerRadius: CGFloat = 26
    /// 起手的那一小下（皂膜是「膜显形」，墨水是「起喷」）
    var revealDuration: Double = 0.10
    /// 前沿扫完整个视图的时长
    var shatterDuration: Double = 0.42
    /// 最后一批液滴消失所需的额外时间
    var dropletLife: Double = 0.6

    var dropletCount: Int = 160
    /// 液滴重力（pt/s²）
    var gravity: CGFloat = 650

    /// 留给边缘高光 / 墨点的绘制余量
    var effectPadding: CGFloat = 8
    /// 留给液滴的额外绘制余量
    var sprayMargin: CGFloat = 130

    var film = SoapFilmParams()
    var ink = InkSplatParams()

    static let `default` = ShatterConfig()

    var totalDuration: Double { revealDuration + shatterDuration + dropletLife }

    /// 静止时也要跑 shader 吗（皂膜有常驻膜，墨水静止时就是原视图）
    var drawsWhenIdle: Bool { style == .soapFilm && film.idleFilm > 0 }
    var animatesWhenIdle: Bool { style == .soapFilm && film.idleShimmer }
}

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

// MARK: - 着色器参数

/// 放在 View 外面：`visualEffect` 的闭包是 nonisolated 的，不能在里面碰 View 的成员。
private func shatterShader(stage: ShatterStage, padded: CGSize, now: Double,
                           config c: ShatterConfig, tap: CGPoint?, seed: UInt64) -> Shader {
    let inner = CGSize(width: max(1, padded.width - c.effectPadding * 2),
                       height: max(1, padded.height - c.effectPadding * 2))
    let half = CGSize(width: inner.width / 2, height: inner.height / 2)
    let center = CGPoint(x: padded.width / 2, y: padded.height / 2)
    let nucleus = nucleusPoint(center: center, halfSize: half, tap: tap, seed: seed)

    switch c.style {
    case .soapFilm:
        return ShaderLibrary.soapFilm(
            .float2(Float(center.x), Float(center.y)),
            .float2(Float(half.width), Float(half.height)),
            .float2(Float(c.cornerRadius), Float(domeDepth(inner, c))),
            .float4(Float(stage.frontT), Float(stage.contentAlpha),
                    Float(stage.filmMix), Float(stage.thickness)),
            .float2(Float(nucleus.x), Float(nucleus.y)),
            .float(Float(now))
        )
    case .inkSplat:
        // seed 只用来给瓣和噪声换个相位，取 [0,1) 就够，别喂大数进 shader
        let phase = Float(seed % 1000) / 1000
        return ShaderLibrary.inkSplat(
            .float2(Float(center.x), Float(center.y)),
            .float2(Float(half.width), Float(half.height)),
            .float2(Float(c.cornerRadius), Float(c.ink.bandWidth)),
            .float4(Float(stage.frontT), Float(c.ink.lobe), Float(c.ink.warp), phase),
            .float2(Float(c.ink.speckleCell), Float(c.ink.speckleLead)),
            .float2(Float(nucleus.x), Float(nucleus.y)),
            .color(c.ink.color)
        )
    }
}

// MARK: - 修饰器

private struct ShatterModifier: ViewModifier {
    @Binding var isShattered: Bool
    var config: ShatterConfig
    var tapToShatter: Bool
    var onFinished: (() -> Void)?

    @State private var start: Date?
    @State private var seed: UInt64 = 0
    @State private var tap: CGPoint?
    @State private var droplets: [ShatterDroplet] = []
    @State private var finished = false
    @State private var timer: Task<Void, Never>?

    private var running: Bool { start != nil && !finished }

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !running && !config.animatesWhenIdle)) { ctx in
            let stage = ShatterStage(elapsed: start.map { ctx.date.timeIntervalSince($0) } ?? -1,
                                     config: config)
            // 取模要取小：这个值会乘上流速喂给噪声坐标，太大 float32 精度不够（见 hash21）
            let now = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60)

            content
                // 手势挂在 padding 之前，.local 才是内容自己的坐标系
                .onTapGesture(coordinateSpace: .local) { location in
                    guard tapToShatter, !isShattered else { return }
                    tap = location
                    isShattered = true
                }
                .padding(config.effectPadding)
                .visualEffect { [config, tap, seed] view, proxy in
                    view.layerEffect(shatterShader(stage: stage, padded: proxy.size, now: now,
                                                   config: config, tap: tap, seed: seed),
                                     maxSampleOffset: CGSize(width: 24, height: 24),
                                     isEnabled: stage.isActive || config.drawsWhenIdle)
                }
                .padding(-config.effectPadding)
                .overlay { spray(stage: stage) }
                .opacity(finished ? 0 : 1)
                .allowsHitTesting(!stage.isActive)
        }
        .onChange(of: isShattered, initial: false) { _, on in reset(on: on) }
        .onDisappear { timer?.cancel() }
    }

    // MARK: 液滴

    private func spray(stage: ShatterStage) -> some View {
        Canvas { ctx, size in
            let t = stage.elapsed - config.revealDuration
            guard stage.isActive, t > 0, !droplets.isEmpty else { return }

            let m = config.sprayMargin
            let inner = CGSize(width: max(1, size.width - m * 2),
                               height: max(1, size.height - m * 2))
            let half = CGSize(width: inner.width / 2, height: inner.height / 2)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let nucleus = nucleusPoint(center: center, halfSize: half, tap: tap, seed: seed)
            let reach = frontReach(nucleus: nucleus, center: center, halfSize: half, config: config)
            // 前沿推进速度：和 shader 里是同一个量
            let frontSpeed = reach / config.shatterDuration
            let unit = min(half.width, half.height)

            if config.style == .soapFilm { ctx.blendMode = .plusLighter }

            for drop in droplets {
                let origin = CGPoint(x: center.x + CGFloat(drop.origin.x) * half.width,
                                     y: center.y + CGFloat(drop.origin.y) * half.height)
                let dx = origin.x - nucleus.x, dy = origin.y - nucleus.y
                let dist = max(hypot(dx, dy), 0.001)

                // 前沿扫到这里的时刻，就是这颗液滴被甩出来的时刻
                let age = t - Double(dist / reach) * config.shatterDuration
                guard age > 0, age < Double(drop.life) else { continue }

                // 前沿沿着「背离破裂点」的方向推，液滴带着这个速度飞出去
                let a = atan2(dy, dx) + CGFloat(drop.angleJitter)
                let speed = CGFloat(drop.speedFactor) * frontSpeed
                let v0 = CGVector(dx: cos(a) * speed, dy: sin(a) * speed)

                switch config.style {
                case .soapFilm:
                    drawWaterDrop(ctx, drop, origin, v0, age, unit)
                case .inkSplat:
                    drawInkBlob(ctx, drop, origin, v0, age, unit)
                }
            }
        }
        .padding(-config.sprayMargin)
        .allowsHitTesting(false)
    }

    /// 皂膜：近白的细streak + 高光核，叠加混合出水光
    private func drawWaterDrop(_ ctx: GraphicsContext, _ drop: ShatterDroplet,
                               _ origin: CGPoint, _ v0: CGVector, _ age: Double, _ unit: CGFloat) {
        // 拉一段比一帧更长的轨迹当运动模糊，液滴才会是「条」而不是「粒」
        let trail = drop.isFine ? 1.0 / 26 : 1.0 / 34
        let now = advance(origin, v0, age, drag: CGFloat(drop.drag))
        let was = advance(origin, v0, max(0, age - trail), drag: CGFloat(drop.drag))

        let k = age / Double(drop.life)
        // 衰减压得很平：水光该是「一直亮着，然后突然没了」，
        // 用陡峭的曲线会让整片喷溅始终是半透明的灰点。
        let fade = min(1, age / 0.012) * pow(1 - k, 0.7)
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

    /// 墨水：不透明的圆疙瘩 + 一条短尾巴 + 一两颗卫星小点。
    /// 关键是**不透明、不叠加、几乎不缩**：斯普拉遁的墨点是实心色块，
    /// 一旦做成半透明或者让它渐隐，立刻就变成水花而不是墨。
    private func drawInkBlob(_ ctx: GraphicsContext, _ drop: ShatterDroplet,
                             _ origin: CGPoint, _ v0: CGVector, _ age: Double, _ unit: CGFloat) {
        let k = age / Double(drop.life)
        let now = advance(origin, v0, age, drag: CGFloat(drop.drag))
        // 尾巴只留很短一截。皂膜那边靠长拖尾做运动模糊，墨点正相反 ——
        // 拖长了就成了一根根胶囊，而斯普拉遁的墨点必须是**圆疙瘩**带一点点尾巴。
        let was = advance(origin, v0, max(0, age - 1.0 / 46), drag: CGFloat(drop.drag))
        let r = max(0.8, CGFloat(drop.sizeFactor) * unit * 0.030)

        // 快到寿命尽头才收缩消失，中间一直是实心的
        let shrink = CGFloat(1 - pow(max(0, k - 0.62) / 0.38, 1.6).clampedUnit)
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

    /// 线性阻力 + 重力下的解析解：x = v₀·(1-e^{-kτ})/k, y 再加 g·(τ-(1-e^{-kτ})/k)/k
    private func advance(_ p: CGPoint, _ v0: CGVector, _ t: Double, drag k: CGFloat) -> CGPoint {
        let tau = CGFloat(t)
        let ek = (1 - exp(-k * tau)) / k
        return CGPoint(x: p.x + v0.dx * ek,
                       y: p.y + v0.dy * ek + config.gravity * (tau - ek) / k)
    }

    // MARK: 状态

    private func reset(on: Bool) {
        timer?.cancel()
        guard on else {
            start = nil
            finished = false
            tap = nil
            return
        }
        seed = UInt64.random(in: UInt64.min...UInt64.max)
        droplets = makeDroplets(count: config.dropletCount, style: config.style, seed: seed)
        finished = false
        start = Date()
        timer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(config.totalDuration))
            guard !Task.isCancelled else { return }
            finished = true
            onFinished?()
        }
    }
}


extension View {
    /// 让视图碎掉。`isShattered` 置 true 触发，置回 false 立刻复原。
    /// 破裂点按 seed 随机取；想跟手请用 `shatterOnTap`。
    ///
    /// 注意：液滴会飞出视图边界，所以别把它塞进会裁剪的容器（ScrollView / List /
    /// clipped 的 ZStack）里，否则喷溅会被切掉。
    func shatter(isShattered: Binding<Bool>,
                 config: ShatterConfig = .default,
                 onFinished: (() -> Void)? = nil) -> some View {
        modifier(ShatterModifier(isShattered: isShattered, config: config,
                                 tapToShatter: false, onFinished: onFinished))
    }

    /// 点一下就碎，并且从手指点到的那一点开始崩解。
    func shatterOnTap(isShattered: Binding<Bool>,
                      config: ShatterConfig = .default,
                      onFinished: (() -> Void)? = nil) -> some View {
        modifier(ShatterModifier(isShattered: isShattered, config: config,
                                 tapToShatter: true, onFinished: onFinished))
    }
}
