//
//  BubblePopView.swift
//  ios-lab
//
//  Demo：点一下，视图鼓成一颗肥皂泡然后崩掉。
//  效果本体在 BubblePop.swift + BubbleFilm.metal，这里只负责摆样式和调参。
//

import SwiftUI

struct BubblePopView: View {
    @State private var heroPopped = false
    @State private var tiles: [Tile] = Tile.initial
    @State private var autoRespawn = true

    @State private var popDuration = 0.42
    @State private var revealDuration = 0.10
    @State private var filmStrength = 2.4
    @State private var thickTop = 700.0
    @State private var dropletCount = 160.0
    @State private var idleFilm = 0.22

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                Spacer(minLength: 8)

                hero
                    .frame(height: 300)

                tileRow
                    .padding(.top, 4)

                Spacer(minLength: 12)

                controls
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: 主角卡片

    private var hero: some View {
        HeroCard()
            .frame(width: 300, height: 188)
            .clipShape(RoundedRectangle(cornerRadius: 30))
            .bubblePopOnTap(isPopped: $heroPopped, config: heroConfig) {
                guard autoRespawn else { return }
                respawn { heroPopped = false }
            }
            .overlay {
                if heroPopped && !autoRespawn {
                    Button("再来一个") { heroPopped = false }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.16))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: heroPopped)
    }

    private var tileRow: some View {
        HStack(spacing: 18) {
            ForEach($tiles) { $tile in
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: tile.colors,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: tile.symbol)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .frame(width: 74, height: 74)
                    .bubblePopOnTap(isPopped: $tile.popped, config: tileConfig) {
                        guard autoRespawn else { return }
                        respawn { tile.popped = false }
                    }
            }
        }
    }

    // MARK: 参数

    private var heroConfig: BubblePopConfig {
        var c = BubblePopConfig()
        c.cornerRadius = 30
        c.popDuration = popDuration
        c.revealDuration = revealDuration
        c.filmStrength = filmStrength
        c.thicknessNM = 300...thickTop
        c.dropletCount = Int(dropletCount)
        c.idleFilm = idleFilm
        return c
    }

    private var tileConfig: BubblePopConfig {
        var c = heroConfig
        c.cornerRadius = 22
        c.popDuration = popDuration * 0.75
        c.sprayMargin = 90
        c.dropletCount = Int(dropletCount * 0.6)
        return c
    }

    private func respawn(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.45))
            action()
        }
    }

    // MARK: 控件

    private var controls: some View {
        VStack(spacing: 10) {
            Text("点哪儿，就从哪儿破")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))

            slider("破裂", $popDuration, 0.12...1.2, fmt: "%.2f s")
            slider("显形", $revealDuration, 0...0.5, fmt: "%.2f s")
            slider("膜强度", $filmStrength, 0.4...5, fmt: "%.1f")
            slider("膜厚", $thickTop, 320...1100, fmt: "%.0f nm")
            slider("液滴", $dropletCount, 0...240, fmt: "%.0f")
            slider("常驻膜", $idleFilm, 0...0.8, fmt: "%.2f")

            Toggle("自动重生", isOn: $autoRespawn)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .tint(.cyan.opacity(0.7))
                .padding(.top, 2)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    private func slider(_ title: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>, fmt: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 52, alignment: .leading)
            Slider(value: value, in: range)
                .tint(.white.opacity(0.5))
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var background: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.09)
            RadialGradient(colors: [Color(red: 0.10, green: 0.20, blue: 0.34).opacity(0.9), .clear],
                           center: .init(x: 0.5, y: 0.32), startRadius: 20, endRadius: 460)
        }
        .ignoresSafeArea()
    }

    struct Tile: Identifiable {
        let id: Int
        var popped = false
        let colors: [Color]
        let symbol: String

        static let initial: [Tile] = [
            Tile(id: 0, colors: [Color(red: 0.98, green: 0.42, blue: 0.55),
                                 Color(red: 0.86, green: 0.24, blue: 0.62)], symbol: "heart.fill"),
            Tile(id: 1, colors: [Color(red: 0.36, green: 0.72, blue: 0.98),
                                 Color(red: 0.26, green: 0.42, blue: 0.92)], symbol: "drop.fill"),
            Tile(id: 2, colors: [Color(red: 0.52, green: 0.88, blue: 0.58),
                                 Color(red: 0.20, green: 0.68, blue: 0.60)], symbol: "leaf.fill"),
        ]
    }
}

// MARK: - 卡面

private struct HeroCard: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.31, green: 0.24, blue: 0.72),
                                    Color(red: 0.68, green: 0.29, blue: 0.62),
                                    Color(red: 0.92, green: 0.46, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "bubbles.and.sparkles.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Text("SOAP FILM")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(2)
                        .opacity(0.7)
                }
                Spacer()
                Text("点我")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                Text("我是一层皂膜，点哪儿从哪儿破")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.75)
            }
            .foregroundStyle(.white)
            .padding(20)
        }
    }
}

#Preview {
    NavigationStack {
        BubblePopView()
    }
    .preferredColorScheme(.dark)
}
