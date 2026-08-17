//
//  BubblePop.swift
//  ios-lab
//
//  可复用的「泡泡破裂」修饰器：把任意视图当成一层皂膜，点一下它就从被点到的那一点破开。
//  视图保持自己的形状，不会先鼓成球 —— 膜显形、穿孔、卷边退缩、喷溅，一气呵成。
//
//  分工：
//  - BubbleFilm.metal  负责膜本身（形状、干涉着色、孔洞扩张、卷边亮环）。
//  - 这里负责时间线（显形 → 破裂 → 余滴）、参数动画，以及膜没法画的液滴喷溅。
//
//  液滴用 Canvas 画而不是塞进 shader：它们要飞出视图边界，而且按前一帧到当前帧
//  拉成一段胶囊就能拿到很便宜的运动模糊，比逐像素遍历上百个粒子划算得多。
//

import SwiftUI

// MARK: - 配置

struct BubblePopConfig {
    /// 宿主视图的圆角，要和它自己的 clipShape 对上，否则膜的轮廓会错位
    var cornerRadius: CGFloat = 26
    /// 边缘曲面带的进深 = 该系数 × 视图短边（上限 30pt）。
    /// 膜中间是平的，只有靠边这一圈会弯，掠射角在那里抬高，虹彩和高光才有地方落。
    var domeDepth: CGFloat = 0.22

    /// 膜显形：点下去到穿孔之间的那一小下，让人看清它是层膜
    var revealDuration: Double = 0.10
    /// 孔洞扫完整张膜的时长
    var popDuration: Double = 0.42
    /// 最后一批液滴消失所需的额外时间
    var dropletLife: Double = 0.6

    /// 未点击时的膜强度。0 = 完全是原视图，0.2 左右能看出一层薄薄的皂膜感
    var idleFilm: Double = 0.22
    /// 破裂时的膜强度。皂膜正入射反射率只有百分之几，要让虹彩在屏幕上读得出来
    /// 得当成“被打了光”，所以这里可以大于 1
    var filmStrength: Double = 1.15
    /// 破裂时内容还剩多少。这是「视图碎掉」不是「视图变泡泡」，所以默认几乎全留
    var contentFade: Double = 0.85
    /// 膜厚区间（nm），从上界排液到下界；越薄颜色越冷、越接近黑膜
    var thicknessNM: ClosedRange<Double> = 300...700

    var dropletCount: Int = 160
    /// 液滴重力（pt/s²）
    var gravity: CGFloat = 650
    /// 液滴用叠加混合。深色背景上更像溅起的水光；浅色背景建议关掉
    var additiveDroplets: Bool = true
    /// 未点击时也让膜纹持续流动。开着的话每个泡泡都会常驻 60fps，页面上摆多了很费电，
    /// 而且静止时本来也看不出流动，所以默认关。
    var idleShimmer: Bool = false

    /// 留给膜边缘高光的绘制余量
    var effectPadding: CGFloat = 8
    /// 留给液滴的额外绘制余量
    var sprayMargin: CGFloat = 130

    static let `default` = BubblePopConfig()

    var totalDuration: Double { revealDuration + popDuration + dropletLife }
}

// MARK: - 时间线

/// 把「距离点击过去了多久」翻译成 shader 需要的一组参数。elapsed < 0 表示还没点。
private struct BubbleStage {
    var popT = 0.0
    var contentAlpha = 1.0
    var filmMix = 0.0
    var thickness = 0.0
    var elapsed = -1.0

    var isActive: Bool { elapsed >= 0 }

    init(elapsed: Double, config c: BubblePopConfig) {
        self.elapsed = elapsed
        thickness = c.thicknessNM.upperBound
        filmMix = c.idleFilm
        guard elapsed >= 0 else { return }

        // 显形：easeOut，一下就亮起来
        let raw = min(1, elapsed / max(c.revealDuration, 0.001))
        let reveal = 1 - pow(1 - raw, 3)

        filmMix = c.idleFilm + (c.filmStrength - c.idleFilm) * reveal
        contentAlpha = 1 - (1 - c.contentFade) * reveal
        popT = ((elapsed - c.revealDuration) / max(c.popDuration, 0.001)).clampedUnit

        // 排液：整个破裂过程里膜持续变薄，颜色带会随之扫过一遍
        let drain = (elapsed / max(c.revealDuration + c.popDuration, 0.001)).clampedUnit
        thickness = c.thicknessNM.upperBound
            + (c.thicknessNM.lowerBound - c.thicknessNM.upperBound) * drain
    }
}

private extension Double {
    var clampedUnit: Double { Swift.min(1, Swift.max(0, self)) }
}

// MARK: - 几何

/// 破裂点。跟手时就是手指点到的位置（内容局部坐标），否则按 seed 随机取一点。
/// shader 和液滴 Canvas 各自的坐标系不同，但 `center - halfSize` 都是内容的左上角，
/// 所以同一个函数能服务两边。
private func nucleusPoint(center: CGPoint, halfSize: CGSize,
                          tap: CGPoint?, seed: UInt64) -> CGPoint {
    if let tap {
        return CGPoint(x: center.x - halfSize.width + tap.x,
                       y: center.y - halfSize.height + tap.y)
    }
    var rng = SplitMix64(state: seed &* 6_364_136_223_846_793_005 &+ 1)
    return CGPoint(x: center.x + CGFloat(Float.random(in: -0.6...0.6, using: &rng)) * halfSize.width,
                   y: center.y + CGFloat(Float.random(in: -0.6...0.6, using: &rng)) * halfSize.height)
}

/// 孔洞扫完整张膜的行程 = 破裂点到最远那个角的距离。必须和 shader 里算得一模一样，
/// 否则液滴的出生时刻会和卷边的位置对不上。
private func popReach(nucleus: CGPoint, center: CGPoint, halfSize: CGSize,
                      corner: CGFloat, dome: CGFloat) -> CGFloat {
    let vn = CGPoint(x: nucleus.x - center.x, y: nucleus.y - center.y)
    let far = CGPoint(x: vn.x > 0 ? -halfSize.width : halfSize.width,
                      y: vn.y > 0 ? -halfSize.height : halfSize.height)
    return hypot(far.x - vn.x, far.y - vn.y) + corner + dome
}

private func domeDepth(_ inner: CGSize, _ c: BubblePopConfig) -> CGFloat {
    min(min(inner.width, inner.height) * c.domeDepth, 30)
}

// MARK: - 液滴

/// 破裂喷溅出的一颗液滴。出生点按 halfSize 归一化到 [-1,1]²，出生时刻在绘制时
/// 由「它到破裂点的距离 ÷ 行程」现算 —— 生成时还不知道视图多大。
private struct BubbleDroplet {
    var origin: SIMD2<Float>
    var angleJitter: Float      // 相对“背离破裂点”的偏角（弧度）
    var speedFactor: Float      // × 卷边退缩速度 = 初速
    var sizeFactor: Float
    var life: Float
    var drag: Float
    var hue: Float
    var isMist: Bool
}

/// 可复现的 SplitMix64，保证同一个 seed 每帧生成同一批液滴
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func makeDroplets(count: Int, seed: UInt64) -> [BubbleDroplet] {
    var rng = SplitMix64(state: seed | 1)
    return (0..<count).map { i in
        // 2/3 是细雾。真实破膜喷出来的绝大多数是极小的雾滴，个头大的是少数，
        // 所以尺寸走幂律分布 —— 均匀分布会让整片喷溅看起来像撒了一把彩色药丸。
        let mist = i % 3 != 0
        let sizeRoll = Float.random(in: 0...1, using: &rng)
        return BubbleDroplet(
            origin: SIMD2(Float.random(in: -1...1, using: &rng),
                          Float.random(in: -1...1, using: &rng)),
            angleJitter: Float.random(in: -0.45...0.45, using: &rng),
            speedFactor: mist ? Float.random(in: 0.50...1.55, using: &rng)
                              : Float.random(in: 0.45...1.10, using: &rng),
            sizeFactor: mist ? 0.08 + pow(sizeRoll, 2.0) * 0.26
                             : 0.25 + pow(sizeRoll, 2.2) * 1.05,
            life: mist ? Float.random(in: 0.10...0.22, using: &rng)
                       : Float.random(in: 0.24...0.55, using: &rng),
            drag: mist ? Float.random(in: 4.5...10, using: &rng)
                       : Float.random(in: 2.0...5.0, using: &rng),
            hue: Float.random(in: 0...1, using: &rng),
            isMist: mist
        )
    }
}

// MARK: - 膜的着色器参数

/// 放在 View 外面：`visualEffect` 的闭包是 nonisolated 的，不能在里面碰 View 的成员。
private func bubbleFilmShader(stage: BubbleStage, padded: CGSize, now: Double,
                              config c: BubblePopConfig, tap: CGPoint?, seed: UInt64) -> Shader {
    let inner = CGSize(width: max(1, padded.width - c.effectPadding * 2),
                       height: max(1, padded.height - c.effectPadding * 2))
    let half = CGSize(width: inner.width / 2, height: inner.height / 2)
    let center = CGPoint(x: padded.width / 2, y: padded.height / 2)
    let nucleus = nucleusPoint(center: center, halfSize: half, tap: tap, seed: seed)

    return ShaderLibrary.bubbleFilm(
        .float2(Float(center.x), Float(center.y)),
        .float2(Float(half.width), Float(half.height)),
        .float2(Float(c.cornerRadius), Float(domeDepth(inner, c))),
        .float4(Float(stage.popT), Float(stage.contentAlpha),
                Float(stage.filmMix), Float(stage.thickness)),
        .float2(Float(nucleus.x), Float(nucleus.y)),
        .float(Float(now))
    )
}

// MARK: - 修饰器

private struct BubblePopModifier: ViewModifier {
    @Binding var isPopped: Bool
    var config: BubblePopConfig
    var tapToPop: Bool
    var onFinished: (() -> Void)?

    @State private var start: Date?
    @State private var seed: UInt64 = 0
    @State private var tap: CGPoint?
    @State private var droplets: [BubbleDroplet] = []
    @State private var finished = false
    @State private var timer: Task<Void, Never>?

    private var running: Bool { start != nil && !finished }

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !running && !config.idleShimmer)) { ctx in
            let stage = BubbleStage(elapsed: start.map { ctx.date.timeIntervalSince($0) } ?? -1,
                                    config: config)
            // 取模要取小：这个值会乘上流速喂给噪声坐标，太大 float32 精度不够（见 hash21）
            let now = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60)

            content
                // 手势挂在 padding 之前，.local 才是内容自己的坐标系
                .onTapGesture(coordinateSpace: .local) { location in
                    guard tapToPop, !isPopped else { return }
                    tap = location
                    isPopped = true
                }
                .padding(config.effectPadding)
                .visualEffect { [config, tap, seed] view, proxy in
                    view.layerEffect(bubbleFilmShader(stage: stage, padded: proxy.size, now: now,
                                                      config: config, tap: tap, seed: seed),
                                     maxSampleOffset: CGSize(width: 24, height: 24),
                                     isEnabled: stage.isActive || config.idleFilm > 0)
                }
                .padding(-config.effectPadding)
                .overlay { spray(stage: stage) }
                .opacity(finished ? 0 : 1)
                .allowsHitTesting(!stage.isActive)
        }
        .onChange(of: isPopped, initial: false) { _, popped in reset(popped: popped) }
        .onDisappear { timer?.cancel() }
    }

    // MARK: 液滴

    private func spray(stage: BubbleStage) -> some View {
        Canvas { ctx, size in
            let t = stage.elapsed - config.revealDuration
            guard stage.isActive, t > 0, !droplets.isEmpty else { return }

            let m = config.sprayMargin
            let inner = CGSize(width: max(1, size.width - m * 2),
                               height: max(1, size.height - m * 2))
            let half = CGSize(width: inner.width / 2, height: inner.height / 2)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let nucleus = nucleusPoint(center: center, halfSize: half, tap: tap, seed: seed)
            let reach = popReach(nucleus: nucleus, center: center, halfSize: half,
                                 corner: config.cornerRadius, dome: domeDepth(inner, config))
            // 卷边退缩速度：和 shader 里孔洞的扩张速度是同一个量
            let rimSpeed = reach / config.popDuration

            if config.additiveDroplets { ctx.blendMode = .plusLighter }

            for drop in droplets {
                let origin = CGPoint(x: center.x + CGFloat(drop.origin.x) * half.width,
                                     y: center.y + CGFloat(drop.origin.y) * half.height)
                let dx = origin.x - nucleus.x, dy = origin.y - nucleus.y
                let dist = max(hypot(dx, dy), 0.001)

                // 卷边扫到这里的时刻，就是这颗液滴被甩出来的时刻
                let age = t - Double(dist / reach) * config.popDuration
                guard age > 0, age < Double(drop.life) else { continue }

                // 膜是平的，卷边就沿着「背离破裂点」的方向退，液滴带着这个速度飞出去
                let a = atan2(dy, dx) + CGFloat(drop.angleJitter)
                let speed = CGFloat(drop.speedFactor) * rimSpeed
                let v0 = CGVector(dx: cos(a) * speed, dy: sin(a) * speed)

                // 拉一段比一帧更长的轨迹当运动模糊，液滴才会是「条」而不是「粒」
                let trail = drop.isMist ? 1.0 / 26 : 1.0 / 34
                let now = advance(origin, v0, age, drag: CGFloat(drop.drag))
                let was = advance(origin, v0, max(0, age - trail), drag: CGFloat(drop.drag))

                let k = age / Double(drop.life)
                // 衰减压得很平：水光该是「一直亮着，然后突然没了」，
                // 用陡峭的曲线会让整片喷溅始终是半透明的灰点。
                let fade = min(1, age / 0.012) * pow(1 - k, 0.7)
                let r = max(0.45, CGFloat(drop.sizeFactor) * min(half.width, half.height) * 0.032)

                var path = Path()
                path.move(to: was)
                path.addLine(to: now)
                let hue = Double(drop.hue)
                let sat = drop.isMist ? 0.04 : 0.11
                let alpha = fade * (drop.isMist ? 0.7 : 1.0)
                // 一道很淡的光晕托底，再压一道近白的实心，水光才亮得起来
                ctx.stroke(path, with: .color(Color(hue: hue, saturation: sat * 2, brightness: 1)
                                                .opacity(alpha * 0.18)),
                           style: StrokeStyle(lineWidth: r * 3, lineCap: .round))
                ctx.stroke(path, with: .color(Color(hue: hue, saturation: sat, brightness: 1)
                                                .opacity(alpha)),
                           style: StrokeStyle(lineWidth: r * 2, lineCap: .round))

                // 稍大的液滴上再点一个高光核，看着才像小水珠而不是色块
                if !drop.isMist, r > 1.2 {
                    let dd = r * 0.8
                    ctx.fill(Path(ellipseIn: CGRect(x: now.x - dd / 2 - r * 0.2,
                                                    y: now.y - dd / 2 - r * 0.2,
                                                    width: dd, height: dd)),
                             with: .color(.white.opacity(fade)))
                }
            }
        }
        .padding(-config.sprayMargin)
        .allowsHitTesting(false)
    }

    /// 线性阻力 + 重力下的解析解：x = v₀·(1-e^{-kτ})/k, y 再加 g·(τ-(1-e^{-kτ})/k)/k
    private func advance(_ p: CGPoint, _ v0: CGVector, _ t: Double, drag k: CGFloat) -> CGPoint {
        let tau = CGFloat(t)
        let ek = (1 - exp(-k * tau)) / k
        return CGPoint(x: p.x + v0.dx * ek,
                       y: p.y + v0.dy * ek + config.gravity * (tau - ek) / k)
    }

    // MARK: 状态

    private func reset(popped: Bool) {
        timer?.cancel()
        guard popped else {
            start = nil
            finished = false
            tap = nil
            return
        }
        seed = UInt64.random(in: UInt64.min...UInt64.max)
        droplets = makeDroplets(count: config.dropletCount, seed: seed)
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
    /// 让视图像泡泡一样破掉。`isPopped` 置 true 触发，置回 false 立刻复原。
    /// 破裂点按 seed 随机取；想跟手请用 `bubblePopOnTap`。
    ///
    /// 注意：液滴会飞出视图边界，所以别把它塞进会裁剪的容器（ScrollView / List /
    /// clipped 的 ZStack）里，否则喷溅会被切掉。
    func bubblePop(isPopped: Binding<Bool>,
                   config: BubblePopConfig = .default,
                   onFinished: (() -> Void)? = nil) -> some View {
        modifier(BubblePopModifier(isPopped: isPopped, config: config,
                                   tapToPop: false, onFinished: onFinished))
    }

    /// 点一下就破，并且从手指点到的那一点破开。
    func bubblePopOnTap(isPopped: Binding<Bool>,
                        config: BubblePopConfig = .default,
                        onFinished: (() -> Void)? = nil) -> some View {
        modifier(BubblePopModifier(isPopped: isPopped, config: config,
                                   tapToPop: true, onFinished: onFinished))
    }
}
