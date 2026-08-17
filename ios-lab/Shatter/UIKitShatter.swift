//
//  UIKitShatter.swift
//  ios-lab
//
//  UIKit 版的「视图碎掉」。
//
//  为什么不能直接复用 SwiftUI 那套：`layerEffect` 要求把宿主视图光栅化成纹理再喂给
//  shader，而 UIKit 托管的图层是系统单独合成的，SwiftUI 栅格不到 —— 实测给
//  `UIViewRepresentable` 套上 `.shatter()` 之后，UIKit 内容会直接被替换成
//  「无法渲染」占位符，**而且 `isEnabled: false` 也一样**，挂上去就废。
//
//  所以这条路线自己动手：
//  1. 用 `drawHierarchy` 把目标视图截成一张位图，传成 MTLTexture；
//  2. 在目标视图上方盖一层 CAMetalLayer，把原视图藏起来；
//  3. 每帧跑同一套 ShatterCore.h 的着色核心，内容改从纹理采样。
//
//  液滴也换了实现：SwiftUI 那边用 Canvas 逐帧在 CPU 上画，这边做成实例化四边形，
//  参数一次性传上 GPU，之后每帧只更新一个时间标量。
//
//  形态参数、时间线、液滴分布全部复用 Shatter.swift 里的同一批函数，
//  所以两条路线的观感是一致的。
//

import UIKit
import SwiftUI
import Metal
import QuartzCore

// MARK: - 与 Metal 端严格对应的内存布局

/// 对应 ShatterCore.h 的 `shatter::FilmUniforms`
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

/// 对应 ShatterCore.h 的 `shatter::InkUniforms`
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

/// 对应 UIKitShatterKernels.metal 的 `DropletGPU`
private struct DropletGPU {
    var color: SIMD4<Float>
    var origin: SIMD2<Float>
    var angle: Float
    var speed: Float
    var radius: Float
    var birth: Float
    var life: Float
    var drag: Float
    var spread: Float
    var trail: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

/// 对应 UIKitShatterKernels.metal 的 `DropUniforms`
private struct DropUniformsGPU {
    var viewSize: SIMD2<Float>
    var t: Float
    var gravity: Float
    var style: Float
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

// MARK: - Metal 上下文

/// device / 管线只建一次，所有碎裂动画共用
final class ShatterMetalContext {
    static let shared: ShatterMetalContext? = ShatterMetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let film: MTLRenderPipelineState
    let ink: MTLRenderPipelineState
    /// 墨点是不透明的，走普通 source-over
    let dropletOver: MTLRenderPipelineState
    /// 水光要叠加，对应 SwiftUI 那边 Canvas 的 `.plusLighter`
    let dropletAdd: MTLRenderPipelineState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = device.makeDefaultLibrary() else { return nil }

        func pipeline(_ vertex: String, _ fragment: String, additive: Bool) -> MTLRenderPipelineState? {
            guard let vf = lib.makeFunction(name: vertex),
                  let ff = lib.makeFunction(name: fragment) else { return nil }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            guard let a = d.colorAttachments[0] else { return nil }
            a.pixelFormat = .bgra8Unorm
            a.isBlendingEnabled = true
            a.rgbBlendOperation = .add
            a.alphaBlendOperation = .add
            // 着色器输出的是预乘色，所以 source 系数恒为 one
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = additive ? .one : .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }

        guard let film = pipeline("shatterQuadVertex", "shatterFilmFragment", additive: false),
              let ink = pipeline("shatterQuadVertex", "shatterInkFragment", additive: false),
              let over = pipeline("shatterDropletVertex", "shatterDropletFragment", additive: false),
              let add = pipeline("shatterDropletVertex", "shatterDropletFragment", additive: true)
        else { return nil }

        self.device = device
        self.queue = queue
        self.film = film
        self.ink = ink
        self.dropletOver = over
        self.dropletAdd = add
    }
}

// MARK: - 特效层

/// 盖在目标视图上方、负责播放碎裂动画的一层。动画结束会自己移除。
final class ShatterEffectView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let ctx: ShatterMetalContext
    private let config: ShatterConfig
    private let contentHalf: CGSize
    private let contentCenter: CGPoint   // 特效视图坐标系里的内容中心（`center` 是 UIView 自己的属性）
    private let nucleus: CGPoint      // 同上
    private let texture: MTLTexture
    private let dropletBuffer: MTLBuffer?
    private let dropletCount: Int
    private let phase: Float

    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var onFinished: (() -> Void)?

    /// 失败就返回 nil（没有 Metal、视图太小、截图失败……），调用方据此回退成直接隐藏
    init?(target: UIView, config: ShatterConfig, tap: CGPoint?) {
        guard let ctx = ShatterMetalContext.shared else { return nil }
        let size = target.bounds.size
        guard size.width > 1, size.height > 1 else { return nil }

        let margin = config.sprayMargin
        let canvas = CGSize(width: size.width + margin * 2, height: size.height + margin * 2)

        // 截图直接铺满整张画布（内容摆在 margin 偏移处），这样着色器里
        // uv = pt / viewSize 就能直接用，内容之外自然是透明的
        guard let snapshot = Self.snapshot(target, canvas: canvas, offset: CGPoint(x: margin, y: margin)),
              let texture = Self.makeTexture(device: ctx.device, image: snapshot)
        else { return nil }

        let half = CGSize(width: size.width / 2, height: size.height / 2)
        let center = CGPoint(x: margin + half.width, y: margin + half.height)
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        let nucleus = nucleusPoint(center: center, halfSize: half, tap: tap, seed: seed)

        self.ctx = ctx
        self.config = config
        self.contentHalf = half
        self.contentCenter = center
        self.nucleus = nucleus
        self.texture = texture
        self.phase = Float(seed % 1000) / 1000

        let drops = Self.buildDroplets(config: config, seed: seed,
                                       center: center, half: half, nucleus: nucleus)
        self.dropletCount = drops.count
        self.dropletBuffer = drops.isEmpty ? nil : ctx.device.makeBuffer(
            bytes: drops,
            length: MemoryLayout<DropletGPU>.stride * drops.count,
            options: .storageModeShared)

        super.init(frame: target.frame.insetBy(dx: -margin, dy: -margin))
        isUserInteractionEnabled = false
        backgroundColor = .clear
        metalLayer.device = ctx.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.presentsWithTransaction = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? traitCollection.displayScale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func start(onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func cancel() {
        link?.invalidate()
        link = nil
        onFinished = nil
    }

    @objc private func step() {
        let elapsed = CACurrentMediaTime() - startTime
        guard elapsed < config.totalDuration else {
            link?.invalidate()
            link = nil
            let done = onFinished
            onFinished = nil
            done?()
            return
        }
        render(elapsed: elapsed)
    }

    // MARK: 渲染

    private func render(elapsed: Double) {
        guard metalLayer.drawableSize.width > 0,
              let drawable = metalLayer.nextDrawable(),
              let cmd = ctx.queue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }

        let stage = ShatterStage(elapsed: elapsed, config: config)
        var viewSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))

        enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        switch config.style {
        case .soapFilm:
            var u = filmUniforms(stage)
            enc.setRenderPipelineState(ctx.film)
            enc.setFragmentBytes(&u, length: MemoryLayout<FilmUniformsGPU>.stride, index: 0)
        case .inkSplat:
            var u = inkUniforms(stage)
            enc.setRenderPipelineState(ctx.ink)
            enc.setFragmentBytes(&u, length: MemoryLayout<InkUniformsGPU>.stride, index: 0)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 液滴：前沿开始推进之后才有
        let t = elapsed - config.revealDuration
        if t > 0, let buffer = dropletBuffer, dropletCount > 0 {
            var du = DropUniformsGPU(viewSize: viewSize,
                                     t: Float(t),
                                     gravity: Float(config.gravity),
                                     style: config.style == .inkSplat ? 1 : 0)
            enc.setRenderPipelineState(config.style == .inkSplat ? ctx.dropletOver : ctx.dropletAdd)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&du, length: MemoryLayout<DropUniformsGPU>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: dropletCount)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func filmUniforms(_ stage: ShatterStage) -> FilmUniformsGPU {
        let inner = CGSize(width: contentHalf.width * 2, height: contentHalf.height * 2)
        return FilmUniformsGPU(
            center: SIMD2(Float(contentCenter.x), Float(contentCenter.y)),
            halfSize: SIMD2(Float(contentHalf.width), Float(contentHalf.height)),
            nucleus: SIMD2(Float(nucleus.x), Float(nucleus.y)),
            corner: Float(config.cornerRadius),
            dome: Float(domeDepth(inner, config)),
            frontT: Float(stage.frontT),
            contentAlpha: Float(stage.contentAlpha),
            filmMix: Float(stage.filmMix),
            thicknessNM: Float(stage.thickness),
            // 取模要取小：这个值会乘上流速喂给噪声坐标，太大 float32 精度不够
            time: Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 60)))
    }

    private func inkUniforms(_ stage: ShatterStage) -> InkUniformsGPU {
        InkUniformsGPU(
            color: config.ink.color.rgbaComponents(alpha: 1),
            center: SIMD2(Float(contentCenter.x), Float(contentCenter.y)),
            halfSize: SIMD2(Float(contentHalf.width), Float(contentHalf.height)),
            nucleus: SIMD2(Float(nucleus.x), Float(nucleus.y)),
            corner: Float(config.cornerRadius),
            band: Float(config.ink.bandWidth),
            frontT: Float(stage.frontT),
            lobe: Float(config.ink.lobe),
            warp: Float(config.ink.warp),
            phase: phase,
            speckleCell: Float(config.ink.speckleCell),
            speckleLead: Float(config.ink.speckleLead))
    }

    // MARK: 准备数据

    private static func snapshot(_ view: UIView, canvas: CGSize, offset: CGPoint) -> UIImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        // 必须锁成标准动态范围。默认的 preferred() 在广色域设备上会给出 16 位
        // 扩展范围的位图，那种 CGImage 喂不进纹理（实测整条链路静默失败，
        // 表现就是「点了没反应」）。
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { _ in
            view.drawHierarchy(in: CGRect(origin: offset, size: view.bounds.size),
                               afterScreenUpdates: false)
        }
    }

    /// 自己画进一块 rgba8/预乘/deviceRGB 的位图再上传，不依赖 MTKTextureLoader
    /// 去猜 CGImage 的格式 —— 格式一旦对不上就是静默失败，很难查。
    private static func makeTexture(device: MTLDevice, image: UIImage) -> MTLTexture? {
        guard let cg = image.cgImage, cg.width > 0, cg.height > 0 else { return nil }
        let w = cg.width, h = cg.height
        let bytesPerRow = w * 4
        guard let data = calloc(h, bytesPerRow) else { return nil }
        defer { free(data) }

        guard let bmp = CGContext(data: data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return nil }

        // 这里**不要**加翻转。CGBitmapContext 的用户坐标系原点虽然在左下，但内存里
        // 第 0 行本来就对应图像顶部；直接 draw 出来的缓冲区就是 Metal 想要的
        // 左上原点。多翻一次的结果是整张快照上下颠倒（内容一眼就能看出来）。
        bmp.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                            width: w, height: h,
                                                            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: bytesPerRow)
        return tex
    }

    /// 把 Shatter.swift 里那套归一化液滴，按这次的尺寸解析成 GPU 实例。
    /// 各项系数刻意和 SwiftUI 那边 Canvas 的画法保持一致。
    private static func buildDroplets(config: ShatterConfig, seed: UInt64,
                                      center: CGPoint, half: CGSize,
                                      nucleus: CGPoint) -> [DropletGPU] {
        let drops = makeDroplets(count: config.dropletCount, style: config.style, seed: seed)
        guard !drops.isEmpty else { return [] }

        let reach = frontReach(nucleus: nucleus, center: center, halfSize: half, config: config)
        let frontSpeed = reach / config.shatterDuration
        let unit = Float(min(half.width, half.height))
        let inky = config.style == .inkSplat

        var out: [DropletGPU] = []
        out.reserveCapacity(drops.count * (inky ? 2 : 1))

        for d in drops {
            let origin = CGPoint(x: center.x + CGFloat(d.origin.x) * half.width,
                                 y: center.y + CGFloat(d.origin.y) * half.height)
            let dx = origin.x - nucleus.x, dy = origin.y - nucleus.y
            let dist = max(hypot(dx, dy), 0.001)
            // 前沿扫到这里的时刻，就是这颗液滴被甩出来的时刻
            let birth = Float(dist / reach) * Float(config.shatterDuration)
            let angle = Float(atan2(dy, dx)) + d.angleJitter
            let speed = d.speedFactor * Float(frontSpeed)

            let radius: Float, spread: Float, trail: Float
            let color: SIMD4<Float>
            if inky {
                radius = max(0.8, d.sizeFactor * unit * 0.030)
                spread = 1.0
                trail = 1.0 / 46
                let base = d.isFine ? config.ink.color.shadedInk(0.82) : config.ink.color
                color = base.rgbaComponents(alpha: 1)
            } else {
                radius = max(0.45, d.sizeFactor * unit * 0.032)
                spread = 1.5
                trail = d.isFine ? 1.0 / 26 : 1.0 / 34
                color = Color(hue: Double(d.hue),
                              saturation: d.isFine ? 0.04 : 0.11,
                              brightness: 1)
                    .rgbaComponents(alpha: d.isFine ? 0.7 : 1.0)
            }

            out.append(DropletGPU(color: color,
                                  origin: SIMD2(Float(origin.x), Float(origin.y)),
                                  angle: angle, speed: speed, radius: radius,
                                  birth: birth, life: d.life, drag: d.drag,
                                  spread: spread, trail: trail))

            // 墨水的大颗要挂一颗卫星小点。轨迹是原点的刚性平移，所以只要把出生点
            // 挪一下就能得到和 SwiftUI 那边一样的相对位置。
            if inky, !d.isFine {
                let off = CGFloat(radius) * 2.1
                let sx = origin.x + cos(CGFloat(d.hue) * .pi * 2) * off
                let sy = origin.y + sin(CGFloat(d.hue) * .pi * 2) * off
                out.append(DropletGPU(color: color,
                                      origin: SIMD2(Float(sx), Float(sy)),
                                      angle: angle, speed: speed, radius: radius * 0.34,
                                      birth: birth, life: d.life, drag: d.drag,
                                      spread: spread, trail: trail))
            }
        }
        return out
    }
}

// MARK: - 对外 API

extension UIView {
    /// 让这个 UIKit 视图碎掉：先截图，再把自己藏起来，由一层临时的 Metal 视图播放动画。
    ///
    /// - Parameters:
    ///   - config: 形态参数，和 SwiftUI 版共用同一个类型
    ///   - point: 起爆点（自身坐标系）。传 nil 就随机取一点
    ///   - completion: 动画结束时回调。此时自己仍是 `isHidden = true`，
    ///     要复原就在回调里置回 false
    /// - Returns: 是否成功启动。设备没有 Metal、视图尺寸为零、截图失败时返回 false，
    ///   这时视图不会被隐藏，调用方该走自己的兜底路径
    @discardableResult
    func shatter(config: ShatterConfig = .default,
                 at point: CGPoint? = nil,
                 completion: (() -> Void)? = nil) -> Bool {
        guard let superview,
              let effect = ShatterEffectView(target: self, config: config, tap: point)
        else { return false }

        superview.insertSubview(effect, aboveSubview: self)
        isHidden = true
        effect.start { [weak effect] in
            effect?.removeFromSuperview()
            completion?()
        }
        return true
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
