//
//  UIKitShatter.swift
//  ios-lab
//
//  UIKit 版的「视图碎掉」—— 只有框架，不认识任何一种具体效果。
//
//  为什么不能直接复用 SwiftUI 那套：`layerEffect` 要求把宿主视图光栅化成纹理再喂给
//  shader，而 UIKit 托管的图层是系统单独合成的，SwiftUI 栅格不到 —— 实测给
//  `UIViewRepresentable` 套上 `.shatter()` 之后，UIKit 内容会直接被替换成
//  「无法渲染」占位符，**而且 `isEnabled: false` 也一样**，挂上去就废。
//
//  所以这条路线自己动手：
//  1. 用 `drawHierarchy` 把目标视图截成一张位图，传成 MTLTexture；
//  2. 在目标视图上方盖一层 CAMetalLayer，把原视图藏起来；
//  3. 每帧跑效果自己的 fragment（Effects/<Name>/<Name>Fragment.metal），
//     内容改从纹理采样。
//
//  液滴也换了实现：SwiftUI 那边用 Canvas 逐帧在 CPU 上画，这边做成实例化四边形，
//  参数一次性传上 GPU，之后每帧只更新一个时间标量。
//
//  「这种效果长什么样」全部甩给 `config.style.effect`（见 Shared/ShatterEffect.swift），
//  加新效果不用动这个文件。
//

import UIKit
import SwiftUI
import Metal
import QuartzCore

// MARK: - 与 Metal 端严格对应的内存布局

/// 对应 UIKitShatterKernels.metal 的 `DropletGPU`。
/// 显式补到 64 字节，不依赖编译器的补位规则。由各效果的 `dropletInstances` 填。
struct DropletGPU {
    var color: SIMD4<Float>   // 未预乘
    var origin: SIMD2<Float>  // 出生点（视图坐标 pt）
    var angle: Float          // 飞行方向
    var speed: Float          // 初速 pt/s
    var radius: Float         // 核半径 pt
    var birth: Float          // 出生时刻（秒，相对前沿开始）
    var life: Float           // 寿命（秒）
    var drag: Float           // 线性阻力系数
    var spread: Float         // 四边形要比核半径胖多少倍（有光晕的要留出来）
    var trail: Float          // 拖尾时长（秒）
    var pad0: Float = 0
    var pad1: Float = 0
}

/// 对应 UIKitShatterKernels.metal 的 `DropUniforms`
private struct DropUniformsGPU {
    var viewSize: SIMD2<Float>
    var t: Float
    var gravity: Float
    var style: Float      // 0 = 有光晕且会渐隐（皂膜）, 1 = 实心不渐隐（墨水）
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
    /// 每种风格的 fragment 管线，按 `fragmentFunctionName` 存
    private let effectPipelines: [String: MTLRenderPipelineState]
    /// 墨点那类是不透明的，走普通 source-over
    let dropletOver: MTLRenderPipelineState
    /// 水光那类要叠加，对应 SwiftUI 那边 Canvas 的 `.plusLighter`
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

        // 所有风格的管线一次建齐 —— 加新效果时这里自动覆盖到，不用改代码
        var effects: [String: MTLRenderPipelineState] = [:]
        for style in ShatterStyle.allCases {
            let name = style.effect.fragmentFunctionName
            guard effects[name] == nil else { continue }
            guard let p = pipeline("shatterQuadVertex", name, additive: false) else { return nil }
            effects[name] = p
        }

        guard let over = pipeline("shatterDropletVertex", "shatterDropletFragment", additive: false),
              let add = pipeline("shatterDropletVertex", "shatterDropletFragment", additive: true)
        else { return nil }

        self.device = device
        self.queue = queue
        self.effectPipelines = effects
        self.dropletOver = over
        self.dropletAdd = add
    }

    func pipeline(for style: ShatterStyle) -> MTLRenderPipelineState? {
        effectPipelines[style.effect.fragmentFunctionName]
    }
}

// MARK: - 特效层

/// 盖在目标视图上方、负责播放碎裂动画的一层。动画结束会自己移除。
final class ShatterEffectView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let ctx: ShatterMetalContext
    private let config: ShatterConfig
    /// 特效视图自己坐标系里的几何（`center` 这个名字被 UIView 占了，所以整包放这儿）
    private let geometry: ShatterGeometry
    private let pipeline: MTLRenderPipelineState
    private let texture: MTLTexture
    private let dropletBuffer: MTLBuffer?
    private let dropletCount: Int

    private var link: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var onFinished: (() -> Void)?

    /// 失败就返回 nil（没有 Metal、视图太小、截图失败……），调用方据此回退成直接隐藏
    init?(target: UIView, config: ShatterConfig, tap: CGPoint?) {
        guard let ctx = ShatterMetalContext.shared,
              let pipeline = ctx.pipeline(for: config.style) else { return nil }
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
        let geometry = ShatterGeometry(center: CGPoint(x: margin + half.width,
                                                       y: margin + half.height),
                                       halfSize: half, tap: tap,
                                       seed: UInt64.random(in: UInt64.min...UInt64.max),
                                       config: config)

        self.ctx = ctx
        self.config = config
        self.geometry = geometry
        self.pipeline = pipeline
        self.texture = texture

        let drops = Self.buildDroplets(config: config, geometry: geometry)
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
        let effect = config.style.effect
        var viewSize = SIMD2<Float>(Float(bounds.width), Float(bounds.height))

        enc.setVertexBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&viewSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

        enc.setRenderPipelineState(pipeline)
        effect.encodeUniforms(into: enc, geometry: geometry, stage: stage, config: config)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 液滴：前沿开始推进之后才有
        let t = elapsed - config.revealDuration
        if t > 0, let buffer = dropletBuffer, dropletCount > 0 {
            var du = DropUniformsGPU(viewSize: viewSize,
                                     t: Float(t),
                                     gravity: Float(config.gravity),
                                     style: effect.dropletsAreAdditive ? 0 : 1)
            enc.setRenderPipelineState(effect.dropletsAreAdditive ? ctx.dropletAdd : ctx.dropletOver)
            enc.setVertexBuffer(buffer, offset: 0, index: 0)
            enc.setVertexBytes(&du, length: MemoryLayout<DropUniformsGPU>.stride, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6,
                               instanceCount: dropletCount)
        }

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
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

    /// 把 Shared/ShatterModel.swift 里那套归一化液滴，按这次的尺寸解析成 GPU 实例。
    /// 出生点、方向、初速这些通用量在这里算，尺寸/颜色/拖尾交给效果自己。
    private static func buildDroplets(config: ShatterConfig,
                                      geometry g: ShatterGeometry) -> [DropletGPU] {
        let drops = makeDroplets(count: config.dropletCount, style: config.style, seed: g.seed)
        guard !drops.isEmpty else { return [] }

        let effect = config.style.effect
        let frontSpeed = g.frontSpeed(config)
        let unit = Float(min(g.halfSize.width, g.halfSize.height))

        var out: [DropletGPU] = []
        out.reserveCapacity(drops.count)

        for d in drops {
            let origin = CGPoint(x: g.center.x + CGFloat(d.origin.x) * g.halfSize.width,
                                 y: g.center.y + CGFloat(d.origin.y) * g.halfSize.height)
            let dx = origin.x - g.nucleus.x, dy = origin.y - g.nucleus.y
            let dist = max(hypot(dx, dy), 0.001)
            // 前沿扫到这里的时刻，就是这颗液滴被甩出来的时刻
            let birth = Float(dist / g.reach) * Float(config.shatterDuration)
            let angle = Float(atan2(dy, dx)) + d.angleJitter
            let speed = d.speedFactor * Float(frontSpeed)

            out += effect.dropletInstances(for: d, origin: origin, angle: angle,
                                           speed: speed, birth: birth,
                                           unit: unit, config: config)
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
