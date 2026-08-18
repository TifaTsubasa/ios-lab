//
//  ShatterEffect.swift
//  ios-lab
//
//  一种碎裂效果要实现的全部钩子。框架（SwiftUI/ 和 UIKit/）只跟这个协议打交道，
//  不认识任何一种具体效果 —— 所以加效果不用去改框架里的 switch。
//
//  ## 加一种新效果
//
//  在 Effects/ 下照着 SoapFilm/ 建一个文件夹，五个文件：
//
//      Effects/Xxx/
//      ├── XxxCore.h            逐像素的形态与配色，两条路线共用这一份
//      ├── XxxStitchable.metal  SwiftUI 入口（[[stitchable]]，内容来自 SwiftUI::Layer）
//      ├── XxxFragment.metal    UIKit 入口（[[fragment]]，内容来自快照纹理）
//      └── Xxx.swift            参数 + 本协议的实现（两条路线的胶水）
//
//  再去 ShatterStyle 加一个 case、ShatterConfig 加一行参数，就接上了。
//
//  ## 为什么核心要拆成「算形态」和「合成」两步
//
//  两条路线的**内容来源**不同：SwiftUI 用 `SwiftUI::Layer.sample()`，UIKit 用
//  `texture2d.sample()`（因为 `layerEffect` 栅格不到 UIKit 图层，见 AGENTS.md）。
//  所以 `xxxShade(pos, uniforms)` 只算形态，顺带给出该去哪儿采样；
//  `xxxComposite(src, shade)` 拿到采样结果再出最终颜色。采样这一步由各自的入口做，
//  中间的逻辑一个字都不用重复。
//
//  ## 唯一必须两边对齐的东西
//
//  `frontReach` —— 着色器算前沿位置、液滴算出生时刻，用的是同一个行程。
//  Swift 和 Metal 各写了一遍，公式一旦分叉，液滴就会和前沿脱节（看起来像
//  「墨还没扫到那儿，液滴已经飞出来了」）。改任何一边记得改另一边。
//

import SwiftUI
import Metal

nonisolated protocol ShatterEffect {

    // MARK: - 通用

    /// 前沿扫完整个视图的行程。`base` 是「破裂点到最远那个角的距离 + 圆角」，
    /// 效果如果会把前沿甩得更远（墨的瓣、膜的球冠），在这里放大。
    ///
    /// 必须和自己 Core.h 里算的 `reach` 一模一样。
    static func frontReach(base: CGFloat, halfSize: CGSize, config: ShatterConfig) -> CGFloat

    /// 静止（还没触发）时是否仍要跑着色器。皂膜有常驻的一层膜，墨水静止时就是原视图。
    static func drawsWhenIdle(_ config: ShatterConfig) -> Bool
    /// 静止时是否还要持续重绘（会常驻 60fps，很费电，默认都该是 false）
    static func animatesWhenIdle(_ config: ShatterConfig) -> Bool

    /// 造一颗归一化的液滴。出生点相对 halfSize、速度相对前沿推进速度，
    /// 解析成像素由各条路线自己做。
    ///
    /// 整个函数里的随机数抽取顺序决定了同一个 seed 会得到哪一批液滴，
    /// 所以顺序改了外观就会变（不会出错，但和之前不是同一批）。
    static func makeDroplet(index: Int, rng: inout SplitMix64) -> ShatterDroplet

    // MARK: - SwiftUI 路线

    /// 装配 `.layerEffect` 用的 Shader。参数顺序要和 XxxStitchable.metal 的签名对上。
    static func shader(geometry: ShatterGeometry, stage: ShatterStage,
                       config: ShatterConfig, now: Double) -> Shader

    /// 液滴的混合模式。皂膜的水光要叠加（`.plusLighter`），墨点是实心色块（`.normal`）。
    static var dropletBlendMode: GraphicsContext.BlendMode { get }

    /// 用 Canvas 画一颗液滴。位置自己用 `dropletAdvance` 算 —— 拖尾多长是效果自己的事。
    static func drawDroplet(_ ctx: GraphicsContext, drop: ShatterDroplet,
                            origin: CGPoint, v0: CGVector, age: Double,
                            unit: CGFloat, config: ShatterConfig)

    // MARK: - UIKit 路线

    /// 自己那个 fragment 函数的名字，签名见 UIKit/ShatterQuad.h
    static var fragmentFunctionName: String { get }

    /// 把这一帧的 uniforms 塞进 encoder 的 buffer(0)。
    /// 结构体布局必须和 Core.h 里的 `XxxUniforms` 严格对上。
    static func encodeUniforms(into encoder: MTLRenderCommandEncoder,
                               geometry: ShatterGeometry, stage: ShatterStage,
                               config: ShatterConfig)

    /// 液滴是否走叠加混合，对应 SwiftUI 那边的 `dropletBlendMode`
    static var dropletsAreAdditive: Bool { get }

    /// 把一颗归一化液滴解析成 GPU 实例。返回多个就是一颗液滴画好几块
    /// （墨水的大颗会挂一颗卫星小点）。各项系数要和 `drawDroplet` 保持一致。
    static func dropletInstances(for drop: ShatterDroplet, origin: CGPoint,
                                 angle: Float, speed: Float, birth: Float,
                                 unit: Float, config: ShatterConfig) -> [DropletGPU]
}
