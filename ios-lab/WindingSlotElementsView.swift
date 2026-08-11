//
//  WindingSlotElementsView.swift
//  ios-lab
//
//  Created by Codex on 2026/5/29.
//

import SwiftUI

/// 复刻参考图右侧 7、8、9 三个素材元素的独立 SwiftUI 视图。
struct WindingSlotElementsView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            WindingSlotPalette.paper
                .ignoresSafeArea()

            AssetCalloutLabel(number: "07", title: "卷带槽（右侧）", subtitle: "WINDING SLOT")
                .position(x: 79, y: 38)

            WindingSlotView()
                .position(x: 101, y: 361)

            AssetCalloutLabel(number: "08", title: "滑块条", subtitle: "SLIDER BAR")
                .position(x: 257, y: 85)

            SliderBarReplicaView()
                .position(x: 275, y: 286)

            AssetCalloutLabel(number: "09", title: "导向线", subtitle: "GUIDE LINE")
                .position(x: 258, y: 462)

            GuideLineReplicaView()
                .position(x: 275, y: 580)
        }
        .frame(width: 360, height: 700)
        .background(WindingSlotPalette.paper)
    }
}

/// 提供复刻视图使用的固定色板。
private enum WindingSlotPalette {
    static let paper = Color(red: 0.985, green: 0.972, blue: 0.945)
    static let ink = Color(red: 0.175, green: 0.115, blue: 0.075)
    static let warmBrown = Color(red: 0.55, green: 0.38, blue: 0.24)
    static let outline = Color(red: 0.66, green: 0.55, blue: 0.43)
    static let softPink = Color(red: 0.95, green: 0.44, blue: 0.53)
}

/// 显示素材拆解编号、中英文标题的标注标签。
private struct AssetCalloutLabel: View {
    let number: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(number)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(WindingSlotPalette.warmBrown)
                .frame(width: 31, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(WindingSlotPalette.outline.opacity(0.8), lineWidth: 1)
                        .background(.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WindingSlotPalette.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                Text(subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(WindingSlotPalette.warmBrown.opacity(0.78))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.top, 2)
        }
    }
}

/// 绘制 7 号卷带槽的奶油色立体竖向凹槽。
private struct WindingSlotView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.92, green: 0.89, blue: 0.82),
                            Color(red: 0.80, green: 0.75, blue: 0.66),
                            Color(red: 0.96, green: 0.93, blue: 0.86)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(.white.opacity(0.58), lineWidth: 4)
                        .padding(3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .stroke(WindingSlotPalette.outline.opacity(0.35), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(0.16), radius: 12, x: 8, y: 12)
                .shadow(color: .white.opacity(0.9), radius: 7, x: -5, y: -7)

            RoundedRectangle(cornerRadius: 23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.80, green: 0.75, blue: 0.66),
                            Color(red: 0.50, green: 0.43, blue: 0.34),
                            Color(red: 0.74, green: 0.68, blue: 0.59)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 34, height: 516)
                .shadow(color: .black.opacity(0.28), radius: 7, x: 2, y: 2)
                .shadow(color: .white.opacity(0.55), radius: 5, x: -3, y: -2)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.91, blue: 0.84),
                            Color(red: 0.66, green: 0.59, blue: 0.49),
                            Color(red: 0.50, green: 0.43, blue: 0.34)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 21, height: 500)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.black.opacity(0.12), lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.26))
                .frame(width: 5, height: 464)
                .offset(x: -8)
                .blur(radius: 0.5)
        }
        .frame(width: 80, height: 585)
    }
}

/// 绘制 8 号细长滑块条的静态外观。
private struct SliderBarReplicaView: View {
    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.84, green: 0.81, blue: 0.76),
                            Color(red: 0.67, green: 0.63, blue: 0.57),
                            Color(red: 0.90, green: 0.87, blue: 0.82)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 22, height: 326)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(WindingSlotPalette.outline.opacity(0.55), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 6, x: 5, y: 8)
                .shadow(color: .white.opacity(0.65), radius: 4, x: -3, y: -5)

            Capsule(style: .continuous)
                .fill(.white.opacity(0.35))
                .frame(width: 4, height: 296)
                .offset(x: -7)
                .blur(radius: 0.4)

            Text("Pull co wind")
                .font(.system(size: 10, weight: .regular, design: .serif))
                .foregroundStyle(WindingSlotPalette.ink.opacity(0.58))
                .rotationEffect(.degrees(90))
                .fixedSize()

            Text("III")
                .font(.system(size: 8, weight: .semibold, design: .serif))
                .foregroundStyle(WindingSlotPalette.ink.opacity(0.48))
                .rotationEffect(.degrees(90))
                .fixedSize()
                .offset(y: 126)
        }
        .frame(width: 46, height: 356)
    }
}

/// 绘制 9 号导向线的粉色发光细线。
private struct GuideLineReplicaView: View {
    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(WindingSlotPalette.softPink.opacity(0.18))
                .frame(width: 11, height: 178)
                .blur(radius: 6)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            WindingSlotPalette.softPink.opacity(0.22),
                            WindingSlotPalette.softPink,
                            WindingSlotPalette.softPink.opacity(0.62)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 4, height: 169)
                .shadow(color: WindingSlotPalette.softPink.opacity(0.55), radius: 4, x: 0, y: 0)

            Capsule(style: .continuous)
                .fill(.white.opacity(0.45))
                .frame(width: 1.3, height: 152)
                .offset(x: -1.2)
        }
        .frame(width: 24, height: 188)
    }
}

#Preview("Winding Slot Elements") {
    WindingSlotElementsView()
        .padding(24)
}
