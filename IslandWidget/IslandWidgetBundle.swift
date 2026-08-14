//
//  IslandWidgetBundle.swift
//  IslandWidget
//
//  这个 @main 必须留在 ios-lab/ 之外：ios-lab/ 是 Xcode 同步组，
//  放进去会被 App target 一并收编，和 ios_labApp 的 @main 冲突。
//

import SwiftUI
import WidgetKit

@main
struct IslandWidgetBundle: WidgetBundle {
    var body: some Widget {
        IslandActivityWidget()
    }
}
