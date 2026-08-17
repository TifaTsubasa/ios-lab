//
//  ShatterConfig.swift
//  ios-lab
//
//  碎裂效果的风格与参数。SwiftUI 和 UIKit 两条渲染路线共用同一套配置类型，
//  换路线不用换参数。
//
//  - 通用参数（时长、液滴数、重力、绘制余量）在 `ShatterConfig` 顶层。
//  - 风格专属参数分别装在 `.film` 和 `.ink` 里。
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
