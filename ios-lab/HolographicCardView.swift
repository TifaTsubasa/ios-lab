//
//  HolographicCardView.swift
//  ios-lab
//
//  镭射闪光卡片：复刻参考视频中的全息箔卡效果。
//  真机上跟随陀螺仪流动镭射光泽，也可以拖拽卡片；快速甩动可让卡片转一圈。
//

import SwiftUI
import Combine
import CoreMotion

// MARK: - 主视图

struct HolographicCardView: View {
    enum FoilMode: Int, CaseIterable, Identifiable {
        case aurora, silver, rainbow
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .aurora: return "极光"
            case .silver: return "银彩"
            case .rainbow: return "虹箔"
            }
        }
    }

    @StateObject private var motion = MotionTiltProvider()
    @State private var mode: FoilMode = .rainbow
    @State private var dragTilt: CGSize = .zero
    @State private var spinAngle: Double = 0

    /// 陀螺仪与拖拽合成后的倾斜量，范围约 -1...1
    private var tiltX: Double { clamp(motion.tilt.width + dragTilt.width, -1.2, 1.2) }
    private var tiltY: Double { clamp(motion.tilt.height + dragTilt.height, -1.2, 1.2) }

    var body: some View {
        ZStack {
            background

            VStack(spacing: 28) {
                modePicker

                HoloCard(mode: mode,
                         tiltX: tiltX,
                         tiltY: tiltY,
                         spinAngle: spinAngle)
                    .rotation3DEffect(.degrees(tiltX * 14 + spinAngle),
                                      axis: (x: 0, y: 1, z: 0),
                                      perspective: 0.55)
                    .rotation3DEffect(.degrees(-tiltY * 12),
                                      axis: (x: 1, y: 0, z: 0),
                                      perspective: 0.55)
                    .gesture(dragGesture)

                Text("左右倾斜或拖拽卡片，用力甩可以转一圈")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .onAppear { motion.start() }
        .onDisappear { motion.stop() }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var background: some View {
        ZStack {
            Color(red: 0.05, green: 0.04, blue: 0.07)
            RadialGradient(colors: [Color(red: 0.22, green: 0.12, blue: 0.30).opacity(0.8), .clear],
                           center: .center, startRadius: 40, endRadius: 420)
        }
        .ignoresSafeArea()
    }

    private var modePicker: some View {
        HStack(spacing: 10) {
            ForEach(FoilMode.allCases) { item in
                Button {
                    withAnimation(.snappy) { mode = item }
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(mode == item ? .black : .white.opacity(0.75))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(mode == item ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.10)),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragTilt = CGSize(width: value.translation.width / 140,
                                  height: -value.translation.height / 180)
            }
            .onEnded { value in
                let velocity = value.predictedEndTranslation.width - value.translation.width
                if abs(velocity) > 220 {
                    // 甩动：卡片转一整圈
                    withAnimation(.spring(response: 1.1, dampingFraction: 0.85)) {
                        spinAngle += velocity > 0 ? 360 : -360
                    }
                }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    dragTilt = .zero
                }
            }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }
}

// MARK: - 卡片本体

private struct HoloCard: View {
    let mode: HolographicCardView.FoilMode
    let tiltX: Double
    let tiltY: Double
    let spinAngle: Double

    private let cardSize = CGSize(width: 320, height: 452)
    private let frameWidth: CGFloat = 11

    /// 传入 shader 的光泽偏移：倾斜 + 甩动旋转共同驱动
    private var shaderShiftX: Double { tiltX + spinAngle / 180 }

    var body: some View {
        ZStack {
            // 金属银边框
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.92),
                                              Color(white: 0.60),
                                              Color(white: 0.88),
                                              Color(white: 0.55),
                                              Color(white: 0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))

            // 全息箔面
            foil
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(frameWidth)

            content
                .padding(frameWidth)
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .shadow(color: .black.opacity(0.55), radius: 28, y: 18)
    }

    private var foil: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1000)
            Rectangle()
                .fill(.white)
                .colorEffect(ShaderLibrary.holographicFoil(
                    .float2(Float(cardSize.width - frameWidth * 2),
                            Float(cardSize.height - frameWidth * 2)),
                    .float2(Float(shaderShiftX), Float(tiltY)),
                    .float(Float(t)),
                    .float(Float(mode.rawValue))
                ))
        }
    }

    // MARK: 卡面内容

    private var content: some View {
        ZStack {
            sticker

            VStack {
                HStack(alignment: .top) {
                    studioBadge
                    Spacer()
                    scoreLabel
                }
                Spacer()
                infoPanel
            }
            .padding(14)
        }
    }

    /// 中央贴纸：倾斜到一定角度会切换表情（复刻视频里的“透镜变脸”效果）
    private var sticker: some View {
        let wink = smoothstep(0.35, 0.65, abs(tiltX))
        return ZStack {
            StickerFace(emoji: "😧").opacity(1 - wink)
            StickerFace(emoji: "😜").opacity(wink)
        }
        .offset(y: -26)
    }

    private var studioBadge: some View {
        Text("LIKO STUDIO")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .kerning(0.5)
            .foregroundStyle(.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(LinearGradient(colors: [Color(white: 0.95),
                                                       Color(white: 0.68),
                                                       Color(white: 0.90)],
                                              startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)

    }

    private var scoreLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("LS")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
            Text("90")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Liko Lens")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
            Text("Move around the card to reveal another studio mood.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black.opacity(0.18))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// 带白描边的大号表情贴纸（用叠加白色阴影模拟贴纸描边）
private struct StickerFace: View {
    let emoji: String

    var body: some View {
        Text(emoji)
            .font(.system(size: 180))
            .shadow(color: .white, radius: 3)
            .shadow(color: .white, radius: 3)
            .shadow(color: .white, radius: 3)
            .shadow(color: .white, radius: 3)
            .shadow(color: .white, radius: 3)
            .shadow(color: .white, radius: 3)
            .shadow(color: .white, radius: 3)
            .shadow(color: .white, radius: 3)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 9)
    }
}

// MARK: - 陀螺仪

/// 以启动时的姿态为基准，输出 -1...1 的相对倾斜量。
final class MotionTiltProvider: ObservableObject {
    @Published var tilt: CGSize = .zero

    private let manager = CMMotionManager()
    private var reference: (roll: Double, pitch: Double)?

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] deviceMotion, _ in
            guard let self, let m = deviceMotion else { return }
            let attitude = m.attitude
            if self.reference == nil {
                self.reference = (attitude.roll, attitude.pitch)
            }
            guard let ref = self.reference else { return }
            let range = Double.pi / 4  // ±45° 映射到 ±1
            self.tilt = CGSize(
                width: max(-1, min(1, (attitude.roll - ref.roll) / range)),
                height: max(-1, min(1, (attitude.pitch - ref.pitch) / range))
            )
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        reference = nil
    }
}

#Preview {
    HolographicCardView()
}
