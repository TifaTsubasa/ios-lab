//
//  ShatterModifier.swift
//  ios-lab
//
//  SwiftUI 路线的 `.shatter()` 修饰器。
//
//  分工：
//  - Shared/ShatterCore.h 负责逐像素的形态与着色；本目录下的 SoapFilm.metal /
//    InkSplat.metal 只是把参数装进 uniforms 的薄包装。
//  - Shared/ShatterConfig.swift、ShatterModel.swift 负责参数与动画模型。
//  - 这里负责把两者接起来，外加 shader 画不了的液滴 —— 它们要飞出视图边界。
//
//  液滴用 Canvas 画：按「上一帧→当前帧」拉成一段胶囊就能拿到很便宜的运动模糊，
//  比逐像素遍历上百个粒子划算得多。
//
//  注意这条路线**对 UIKit 内容是失效的**（`layerEffect` 栅格不到 UIKit 图层），
//  要碎 UIKit 视图请走 UIKit/UIKitShatter.swift。
//

import SwiftUI

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
