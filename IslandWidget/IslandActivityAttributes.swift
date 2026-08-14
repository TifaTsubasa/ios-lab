//
//  IslandActivityAttributes.swift
//  IslandWidget
//
//  App 与 widget extension 共享的 Live Activity 契约。
//  同时属于两个 target：widget 靠同步组收编，App 靠 pbxproj 里的显式文件引用加入。
//  App target 还支持 macOS / visionOS，而 ActivityKit 只在 iOS 上可用，所以整体加平台守卫。
//

#if os(iOS)
import ActivityKit
import Foundation

struct InAppIslandActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 活动开始时刻，用来在岛上跑一个计时器，证明它一直活着。
        var startedAt: Date
        /// App 回到前台的次数。回前台时 +1 并 update，
        /// 下次切后台再看岛上的数字有没有变，就知道活动是被「隐藏」还是被「结束」了。
        var foregroundReturns: Int
    }

    var demoTitle: String
}
#endif
