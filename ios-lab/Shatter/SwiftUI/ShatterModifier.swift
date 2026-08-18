//
//  ShatterModifier.swift
//  ios-lab
//
//  SwiftUI 路线的 `.shatter()` 修饰器 —— 只有框架，不认识任何一种具体效果。
//
//  它负责的是：计时、把 shader 挂到 `layerEffect` 上、驱动液滴 Canvas、收尾。
//  每一步里「这种效果长什么样」都甩给 `config.style.effect`（见 Shared/ShatterEffect.swift），
//  所以加新效果不用动这个文件。
//
//  液滴单独用 Canvas 画而不是塞进 shader：它们要飞出视图边界，而 `layerEffect`
//  只能在视图自己的范围内改像素。按「上一帧→当前帧」拉成一段胶囊还能拿到
//  很便宜的运动模糊，比逐像素遍历上百个粒子划算得多。
//
//  注意这条路线**对 UIKit 内容是失效的**（`layerEffect` 栅格不到 UIKit 图层），
//  要碎 UIKit 视图请走 UIKit/UIKitShatter.swift。
//

import SwiftUI

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
                // 手势挂在 padding 之前，.local 才是内容自己的坐标系。
                //
                // 用零距离 DragGesture 而不是 onTapGesture：后者要等**抬手**才 fire，
                // 手指按住那 50–100ms 用户会算进「卡顿」里。onChanged 在 touch-down
                // 就触发，startLocation 就是按下那一点。
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        guard tapToShatter, !isShattered else { return }
                        tap = v.startLocation
                        isShattered = true
                    })
                .padding(config.effectPadding)
                // 闭包是 nonisolated 的，不能在里面碰 View 的成员，所以要显式捕获
                .visualEffect { [config, tap, seed] view, proxy in
                    let g = geometry(padded: proxy.size, inset: config.effectPadding,
                                     tap: tap, seed: seed, config: config)
                    return view.layerEffect(
                        config.style.effect.shader(geometry: g, stage: stage,
                                                   config: config, now: now),
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
            // 和 frontT 同一条时间轴（前沿从 0 开始推），不再减 revealDuration
            let t = stage.elapsed
            guard stage.isActive, t > 0, !droplets.isEmpty else { return }

            // 注意这里的坐标系和上面 shader 的不是同一个（余量不一样），
            // 但破裂点在内容里的相对位置是同一个 —— seed 和 tap 都没变。
            let g = geometry(padded: size, inset: config.sprayMargin,
                             tap: tap, seed: seed, config: config)
            let frontSpeed = g.frontSpeed(config)
            let unit = min(g.halfSize.width, g.halfSize.height)
            let effect = config.style.effect

            ctx.blendMode = effect.dropletBlendMode

            for drop in droplets {
                let origin = CGPoint(x: g.center.x + CGFloat(drop.origin.x) * g.halfSize.width,
                                     y: g.center.y + CGFloat(drop.origin.y) * g.halfSize.height)
                let dx = origin.x - g.nucleus.x, dy = origin.y - g.nucleus.y
                let dist = max(hypot(dx, dy), 0.001)

                // 前沿扫到这里的时刻，就是这颗液滴被甩出来的时刻
                let age = t - Double(dist / g.reach) * config.shatterDuration
                guard age > 0, age < Double(drop.life) else { continue }

                // 前沿沿着「背离破裂点」的方向推，液滴带着这个速度飞出去
                let a = atan2(dy, dx) + CGFloat(drop.angleJitter)
                let speed = CGFloat(drop.speedFactor) * frontSpeed
                let v0 = CGVector(dx: cos(a) * speed, dy: sin(a) * speed)

                effect.drawDroplet(ctx, drop: drop, origin: origin, v0: v0,
                                   age: age, unit: unit, config: config)
            }
        }
        .padding(-config.sprayMargin)
        .allowsHitTesting(false)
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

/// 从「留了边的画布尺寸」还原出内容的几何。放在 View 外面：`visualEffect`
/// 的闭包是 nonisolated 的，不能在里面调 View 的方法。
private nonisolated func geometry(padded: CGSize, inset: CGFloat, tap: CGPoint?,
                                  seed: UInt64, config: ShatterConfig) -> ShatterGeometry {
    let inner = CGSize(width: max(1, padded.width - inset * 2),
                       height: max(1, padded.height - inset * 2))
    return ShatterGeometry(center: CGPoint(x: padded.width / 2, y: padded.height / 2),
                           halfSize: CGSize(width: inner.width / 2, height: inner.height / 2),
                           tap: tap, seed: seed, config: config)
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
    ///
    /// 是**按下**就碎，不是抬手才碎 —— tap 手势要等 touch-up，按住那 50–100ms
    /// 会被当成卡顿。代价是在卡片上起手滑动也会触发，这个效果里可以接受。
    func shatterOnTap(isShattered: Binding<Bool>,
                      config: ShatterConfig = .default,
                      onFinished: (() -> Void)? = nil) -> some View {
        modifier(ShatterModifier(isShattered: isShattered, config: config,
                                 tapToShatter: true, onFinished: onFinished))
    }
}
