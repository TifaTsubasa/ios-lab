//
//  ShatterStyle.swift
//  ios-lab
//
//  风格枚举 —— 也是效果的注册表。加新效果时这里是**唯一**要改的分发点，
//  框架其余部分只认 `ShatterEffect` 协议。
//

import Foundation

nonisolated enum ShatterStyle: String, CaseIterable, Identifiable {
    case soapFilm
    case inkSplat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soapFilm: return "皂膜"
        case .inkSplat: return "墨水"
        }
    }

    /// 这个风格由谁实现。实现放在 Effects/<Name>/<Name>.swift。
    var effect: any ShatterEffect.Type {
        switch self {
        case .soapFilm: return SoapFilmEffect.self
        case .inkSplat: return InkSplatEffect.self
        }
    }
}
