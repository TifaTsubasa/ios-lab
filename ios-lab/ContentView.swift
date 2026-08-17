//
//  ContentView.swift
//  ios-lab
//
//  Created by Barry on 2026/5/29.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("镭射闪光卡片") {
                    HolographicCardView()
                }
                NavigationLink("卷带槽元素复刻") {
                    WindingSlotElementsView()
                }
                NavigationLink("RustCore 跨端架构") {
                    RustCoreLabView()
                }
                NavigationLink("App 内灵动岛") {
                    InAppDynamicIslandView()
                }
                NavigationLink("泡泡破裂") {
                    BubblePopView()
                }
            }
            .navigationTitle("ios-lab")
        }
    }
}

#Preview {
    ContentView()
}
