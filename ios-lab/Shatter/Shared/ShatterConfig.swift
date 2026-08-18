//
//  ShatterConfig.swift
//  ios-lab
//
//  碎裂效果的通用参数。SwiftUI 和 UIKit 两条渲染路线共用同一套配置类型，
//  换路线不用换参数。
//
//  这里只放**所有效果都要用**的东西（时长、液滴数、重力、绘制余量）。
//  效果专属的参数各自装在自己的 Effects/<Name>/<Name>.swift 里，
//  在这里挂一个成员即可 —— 加新效果时这是要动的第二处（第一处是 ShatterStyle）。
//

import SwiftUI

nonisolated struct ShatterConfig {
    var style: ShatterStyle = .soapFilm

    /// 宿主视图的圆角，要和它自己的 clipShape 对上，否则轮廓会错位
    var cornerRadius: CGFloat = 26
    /// 起手的那一小下（皂膜是「膜显形」）。**和前沿并行**，不是前置阶段 ——
    /// 前沿从第 0 帧就开始推，这只是叠在上面的一层渐变，见 ShatterStage。
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

    // MARK: 各效果的专属参数

    var film = SoapFilmParams()
    var ink = InkSplatParams()

    static let `default` = ShatterConfig()

    /// reveal 现在和前沿重叠，本可以不算进来；留着是因为最后一批液滴的寿命
    /// （墨水最长 0.8s）本来就超过 dropletLife，这 0.1s 正好当尾部余量。
    var totalDuration: Double { revealDuration + shatterDuration + dropletLife }

    /// 静止时也要跑 shader 吗（各效果自己说了算）
    var drawsWhenIdle: Bool { style.effect.drawsWhenIdle(self) }
    var animatesWhenIdle: Bool { style.effect.animatesWhenIdle(self) }
}
