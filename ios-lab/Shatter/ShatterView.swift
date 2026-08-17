//
//  ShatterView.swift
//  ios-lab
//
//  Demo：点一下，视图从被点到的那一点碎掉。两种风格可切换 ——
//  皂膜（肥皂泡破裂）和墨水（斯普拉遁式喷射）。
//  效果本体在 Shatter.swift + SoapFilm.metal / InkSplat.metal，这里只负责摆样式和调参。
//

import SwiftUI

struct ShatterView: View {
    @State private var style: ShatterStyle = .inkSplat
    @State private var heroGone = false
    @State private var tiles: [Tile] = Tile.initial
    @State private var autoRespawn = true

    // 通用
    @State private var shatterDuration = 0.42
    @State private var dropletCount = 160.0
    // 皂膜
    @State private var thickTop = 700.0
    @State private var filmStrength = 1.15
    @State private var idleFilm = 0.22
    // 墨水
    @State private var inkTeam: InkTeam = .neonGreen
    @State private var bandWidth = 30.0
    @State private var lobe = 0.20
    @State private var speckleCell = 34.0

    var body: some View {
        ZStack {
            background

            VStack(spacing: 0) {
                stylePicker
                    .padding(.top, 6)

                Spacer(minLength: 4)

                hero
                    .frame(height: 260)

                tileRow
                    .padding(.top, 2)

                Spacer(minLength: 10)

                controls
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: 风格切换

    private var stylePicker: some View {
        HStack(spacing: 10) {
            ForEach(ShatterStyle.allCases) { item in
                Button {
                    withAnimation(.snappy) {
                        style = item
                        resetAll()
                    }
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(style == item ? .black : .white.opacity(0.7))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(style == item ? AnyShapeStyle(accent) : AnyShapeStyle(.white.opacity(0.10)),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 墨水风格下，强调色跟着团队色走
    private var accent: Color {
        style == .inkSplat ? inkTeam.color : .white
    }

    // MARK: 主角卡片

    private var hero: some View {
        HeroCard(style: style, ink: inkTeam.color)
            .frame(width: 300, height: 188)
            .clipShape(RoundedRectangle(cornerRadius: 30))
            .shatterOnTap(isShattered: $heroGone, config: heroConfig) {
                guard autoRespawn else { return }
                respawn { heroGone = false }
            }
            .overlay {
                if heroGone && !autoRespawn {
                    Button("再来一个") { heroGone = false }
                        .font(.subheadline.weight(.medium))
                        .buttonStyle(.borderedProminent)
                        .tint(.white.opacity(0.16))
                        .foregroundStyle(.white)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: heroGone)
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
                    .shatterOnTap(isShattered: $tile.gone, config: tileConfig) {
                        guard autoRespawn else { return }
                        respawn { tile.gone = false }
                    }
            }
        }
    }

    // MARK: 参数

    private var heroConfig: ShatterConfig {
        var c = ShatterConfig()
        c.style = style
        c.cornerRadius = 30
        c.shatterDuration = shatterDuration
        c.dropletCount = Int(dropletCount)

        c.film.thicknessNM = 300...thickTop
        c.film.strength = filmStrength
        c.film.idleFilm = idleFilm

        c.ink.color = inkTeam.color
        c.ink.bandWidth = bandWidth
        c.ink.lobe = lobe
        c.ink.speckleCell = speckleCell
        return c
    }

    private var tileConfig: ShatterConfig {
        var c = heroConfig
        c.cornerRadius = 22
        c.shatterDuration = shatterDuration * 0.75
        c.sprayMargin = 90
        c.dropletCount = Int(dropletCount * 0.6)
        // 小块上墨带和散墨格子都要按比例收，否则一喷就整块糊死
        c.ink.bandWidth = bandWidth * 0.5
        c.ink.speckleCell = speckleCell * 0.55
        c.ink.speckleLead = 22
        return c
    }

    private func respawn(_ action: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.45))
            action()
        }
    }

    private func resetAll() {
        heroGone = false
        for i in tiles.indices { tiles[i].gone = false }
    }

    // MARK: 控件

    private var controls: some View {
        VStack(spacing: 10) {
            Text(style == .inkSplat ? "点哪儿，墨就从哪儿喷开" : "点哪儿，膜就从哪儿破")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.4))

            slider("时长", $shatterDuration, 0.12...1.2, fmt: "%.2f s")
            slider("液滴", $dropletCount, 0...260, fmt: "%.0f")

            switch style {
            case .soapFilm:
                slider("膜厚", $thickTop, 320...1100, fmt: "%.0f nm")
                slider("膜强度", $filmStrength, 0.4...3, fmt: "%.2f")
                slider("常驻膜", $idleFilm, 0...0.8, fmt: "%.2f")
            case .inkSplat:
                teamPicker
                slider("墨带", $bandWidth, 6...70, fmt: "%.0f pt")
                slider("瓣状", $lobe, 0...0.45, fmt: "%.2f")
                slider("散墨", $speckleCell, 14...70, fmt: "%.0f pt")
            }

            Toggle("自动重生", isOn: $autoRespawn)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
                .tint(accent.opacity(0.8))
                .padding(.top, 2)
        }
        .padding(16)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22))
    }

    private var teamPicker: some View {
        HStack(spacing: 10) {
            Text("墨色")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 52, alignment: .leading)
            ForEach(InkTeam.allCases) { team in
                Button {
                    inkTeam = team
                } label: {
                    Circle()
                        .fill(team.color)
                        .frame(width: 26, height: 26)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(inkTeam == team ? 0.95 : 0),
                                                  lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
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
            RadialGradient(colors: [accent.opacity(0.16), .clear],
                           center: .init(x: 0.5, y: 0.34), startRadius: 20, endRadius: 460)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: accent)
    }

    // MARK: 数据

    /// 斯普拉遁的团队色都是高饱和荧光色
    enum InkTeam: String, CaseIterable, Identifiable {
        case neonGreen, hotPink, cyan, orange
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .neonGreen: return Color(red: 0.58, green: 0.95, blue: 0.10)
            case .hotPink:   return Color(red: 1.00, green: 0.16, blue: 0.55)
            case .cyan:      return Color(red: 0.12, green: 0.82, blue: 0.98)
            case .orange:    return Color(red: 1.00, green: 0.52, blue: 0.05)
            }
        }
    }

    struct Tile: Identifiable {
        let id: Int
        var gone = false
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
    var style: ShatterStyle
    var ink: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.31, green: 0.24, blue: 0.72),
                                    Color(red: 0.68, green: 0.29, blue: 0.62),
                                    Color(red: 0.92, green: 0.46, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: style == .inkSplat ? "paintbrush.pointed.fill"
                                                         : "bubbles.and.sparkles.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Spacer()
                    Text(style == .inkSplat ? "SPLAT" : "SOAP FILM")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(2)
                        .opacity(0.7)
                }
                Spacer()
                Text("点我")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                Text(style == .inkSplat ? "一枪下去，整块被墨吃掉"
                                        : "我是一层皂膜，点哪儿从哪儿破")
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
        ShatterView()
    }
    .preferredColorScheme(.dark)
}
