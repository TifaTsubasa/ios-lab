//
//  InAppDynamicIslandView.swift
//  ios-lab
//
//  App 内灵动岛：在挖孔坐标处画一个纯黑胶囊压住系统灵动岛，外圈描一圈红色边框。
//  系统灵动岛由系统在所有 App 之上的图层渲染，App 画不上去，只能靠「黑对黑」融为一体。
//
//  页面里还带一个实时活动实测台：启动一个真实的 Live Activity（UI 在 IslandWidget target），
//  切后台能在系统灵动岛上看到它，切回前台它会消失——但时间线会显示 activityState 仍是 active。
//  这就把「系统前台自动隐藏」和「活动被结束」两件肉眼一样的事区分开了。
//  Apple 明确表态过：没有任何 API 能关掉其他 App 的灵动岛，能碰的只有自己这一个。
//

import SwiftUI
#if os(iOS)
import ActivityKit
import UIKit
#endif

// MARK: - 主视图

struct InAppDynamicIslandView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var phase: IslandPhase = .collapsed
    @State private var metrics = IslandMetrics()
    /// 默认白底：黑胶囊和真实挖孔在白色上对比最强，一眼能看出有没有对齐。
    @State private var useDarkBackground = false
    @State private var lab = LiveActivityLab()
    @State private var audioLab = AudioPreemptionLab()
    /// 抢占音频只对音乐/播客那种 Now Playing 岛有用，而且会真的停掉用户的音乐，默认关。
    @AppStorage("island.autoPreemptAudio") private var autoPreemptAudio = false
    /// 实测有效的那条路：请求系统隐藏非必要覆盖层，别家的 Live Activity 就不渲染了。
    @AppStorage("island.hideOverlays") private var hideOverlays = true
    @AppStorage("island.hideStatusBar") private var hideStatusBar = false
    @State private var showTuning = false

    private var foreground: Color { useDarkBackground ? .white : Color(red: 0.11, green: 0.10, blue: 0.13) }

    var body: some View {
        ZStack(alignment: .top) {
            background

            infoScroll

            // 展开后铺满全屏的透明层：点岛体以外的任何位置都收起。
            if phase == .expanded {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { setPhase(.collapsed) }
            }

            islandLayer
        }
        // 进页面只清点、不结束：正在运行的活动本身就是要观察的对象。
        .task {
            lab.adoptRunningActivity()
            audioLab.refresh()
            if autoPreemptAudio { audioLab.preempt() }
        }
        // 离开页面把会话还回去，被打断的 App 才有机会恢复播放。
        .onDisappear { audioLab.release() }
        // 这两条就是让别家灵动岛消失的开关，作用范围仅限本页面。
        .persistentSystemOverlays(hideOverlays ? .hidden : .automatic)
        .statusBarHidden(hideStatusBar)
        .onChange(of: scenePhase) { _, newPhase in
            lab.handleScenePhase(newPhase)
        }
        // 导航栏会画在岛体之上、返回按钮正好压住展开态，这里整条隐藏，改用页面内的返回按钮。
        .toolbar(.hidden, for: .navigationBar)
    }

    private var background: some View {
        Group {
            if useDarkBackground {
                Color(red: 0.05, green: 0.04, blue: 0.07)
            } else {
                Color.white
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 灵动岛图层

    /// 独立铺满全屏（含安全区）的一层，只承载岛体本身，保证它压在页面最上方。
    private var islandLayer: some View {
        ZStack(alignment: .top) {
            // 实测：屏幕顶部约 54pt（状态栏整条）收不到触摸，系统图层在 App 之上把点击吃掉了。
            // 岛体 13.5~50.8pt 整个落在这条死区里，怎么点都没反应，所以用一条从屏幕顶端
            // 向下延伸进活动区的带子接管「点击展开」。
            if phase == .collapsed {
                Color.clear
                    .frame(height: metrics.tapBandHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { setPhase(.expanded) }
            }

            VStack(spacing: 0) {
                island
                    .padding(.top, metrics.topInset)
                Spacer(minLength: 0)
            }
        }
        .ignoresSafeArea()
    }

    private var island: some View {
        let size = metrics.size(for: phase)
        let radius = metrics.cornerRadius(for: phase)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let ringInset = metrics.ringGap + metrics.ringWidth

        let hitInset = ringInset + metrics.hitSlop

        return expandedContent
            .opacity(phase == .expanded ? 1 : 0)
            .frame(width: size.width, height: size.height)
        .background(Color.black, in: shape)
        .clipShape(shape)
        .overlay {
            RoundedRectangle(cornerRadius: radius + ringInset, style: .continuous)
                .strokeBorder(Color.red, lineWidth: metrics.ringWidth)
                .frame(width: size.width + ringInset * 2,
                       height: size.height + ringInset * 2)
        }
        // 挖孔本身那一小块屏幕收不到触摸（系统状态栏图层在 App 之上），
        // 所以点击热区要比胶囊大一圈，让手指落在挖孔边缘也能命中。
        .overlay {
            RoundedRectangle(cornerRadius: radius + hitInset, style: .continuous)
                .fill(.clear)
                .contentShape(RoundedRectangle(cornerRadius: radius + hitInset, style: .continuous))
                .frame(width: size.width + hitInset * 2,
                       height: size.height + hitInset * 2)
                .onTapGesture { setPhase(phase == .collapsed ? .expanded : .collapsed) }
        }
    }

    /// 展开态：顶部整条留空，同时避开挖孔和系统状态栏（时间、信号、电量都画在 App 之上）。
    private var expandedContent: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: metrics.collapsedHeight)

            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(red: 0.98, green: 0.45, blue: 0.32),
                                                Color(red: 0.62, green: 0.24, blue: 0.72)],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )
                    .frame(width: 54, height: 54)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("App 内灵动岛")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("ios-lab · 正在播放")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer(minLength: 0)

                Image(systemName: "pause.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Text("1:12")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))

                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.white)
                                .frame(width: proxy.size.width * 0.34, height: 4)
                        }
                    }

                Text("3:40")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .frame(width: metrics.expandedWidth)
    }

    private func setPhase(_ next: IslandPhase) {
        guard next != phase else { return }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
            phase = next
        }
    }

    // MARK: - 页面说明与控制

    private var infoScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                backButton

                if !DeviceProbe.hasDynamicIsland {
                    hintCard(symbol: "iphone.gen2",
                             text: "当前设备没有灵动岛，上方为模拟位置，仅供查看外观。")
                }

                usageCard

                OverlaySuppressionCard(hideOverlays: $hideOverlays,
                                       hideStatusBar: $hideStatusBar,
                                       foreground: foreground)

                OtherAudioPreemptionCard(lab: audioLab,
                                         autoPreempt: $autoPreemptAudio,
                                         foreground: foreground)

                labCard

                timelineCard

                explanationCard

                Toggle("深色背景", isOn: $useDarkBackground)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(foreground)
                    .tint(Color(red: 0.98, green: 0.45, blue: 0.32))
                    .padding(.horizontal, 4)

                tuningSection
            }
            .padding(.horizontal, 20)
            // 让出展开态灵动岛的高度，避免内容被压在下面。
            .padding(.top, 120)
            .padding(.bottom, 40)
        }
    }

    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Label("ios-lab", systemImage: "chevron.left")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foreground.opacity(0.75))
        }
        .buttonStyle(.plain)
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(phase == .collapsed ? "点一下上方的灵动岛展开" : "点击岛体以外的任何位置收起")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(foreground)
                    .contentTransition(.opacity)
            } icon: {
                Image(systemName: phase == .collapsed ? "hand.tap" : "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(Color(red: 0.98, green: 0.45, blue: 0.32))
            }

            if phase == .collapsed {
                Text("屏幕顶部约 54pt 是系统触摸死区，岛体整个落在里面、点不到，所以热区向下延伸到了死区之外。")
                    .font(.system(size: 12))
                    .foregroundStyle(foreground.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }

    /// 实测台：启动/结束一个真实 Live Activity，并显示它此刻的状态。
    private var labCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("实时活动实测")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground)
            } icon: {
                Image(systemName: lab.status.symbol)
                    .foregroundStyle(lab.status.tint)
            }

            Text(lab.status.title)
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if lab.isSupported {
                HStack(spacing: 10) {
                    Button {
                        lab.start()
                    } label: {
                        Text("开始实时活动")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.98, green: 0.45, blue: 0.32))
                    .disabled(!lab.canStart)

                    Button {
                        lab.endAll()
                    } label: {
                        Text("全部结束")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(foreground.opacity(0.6))
                    .disabled(lab.activityCount == 0)
                }

                Text("步骤：① 开始 → ② 上滑回桌面，灵动岛出现本 Demo → ③ 切回本 App，岛消失 → ④ 看下面的时间线，活动状态仍是 active。")
                    .font(.system(size: 12))
                    .foregroundStyle(foreground.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("能碰的只有自家这一个。系统不给任何 API 关掉别的 App 的灵动岛，那是用户级设置。")
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }

    /// 时间线：前后台切换与活动状态变化的流水，是本次实测的证据本身。
    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("时间线")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground)

                Spacer()

                if !lab.entries.isEmpty {
                    Button("清空") { lab.clearLog() }
                        .font(.system(size: 12))
                        .tint(foreground.opacity(0.5))
                }
            }

            if lab.entries.isEmpty {
                Text("还没有记录。点上面的「开始实时活动」，然后在前后台之间切几次。")
                    .font(.system(size: 12))
                    .foregroundStyle(foreground.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lab.entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(entry.stamp)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(foreground.opacity(0.35))
                                .frame(width: 58, alignment: .leading)

                            Image(systemName: entry.symbol)
                                .font(.system(size: 11))
                                .foregroundStyle(entry.tint)
                                .frame(width: 14)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(foreground.opacity(0.85))

                                if let detail = entry.detail {
                                    Text(detail)
                                        .font(.system(size: 11))
                                        .foregroundStyle(foreground.opacity(0.4))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这个岛是 App 画的")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(foreground)

            Text("系统灵动岛渲染在所有 App 之上，App 无法真正盖住它。这里在挖孔坐标处画了一个纯黑胶囊，黑对黑视觉上与挖孔融为一体，红框描在胶囊外侧，真实挖孔正好落在红框里面。")
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }

    private var tuningSection: some View {
        DisclosureGroup(isExpanded: $showTuning) {
            VStack(spacing: 14) {
                tuningSlider(title: "宽度", value: $metrics.collapsedWidth, range: 100...160)
                tuningSlider(title: "高度", value: $metrics.collapsedHeight, range: 28...50)
                tuningSlider(title: "顶部距离", value: $metrics.topInset, range: 0...30)
                tuningSlider(title: "红框间距", value: $metrics.ringGap, range: 0...12)

                Button("恢复默认") {
                    withAnimation(.snappy) { metrics = IslandMetrics() }
                }
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
        } label: {
            Text("微调（对齐挖孔）")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(foreground)
        }
        .tint(foreground.opacity(0.6))
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }

    private func tuningSlider(title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.6))
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(foreground.opacity(0.4))
            }

            Slider(value: value, in: range)
                .tint(Color(red: 0.98, green: 0.45, blue: 0.32))
        }
    }

    private func hintCard(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(foreground.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
    }
}

// MARK: - 形态

/// 模拟灵动岛的两种形态：收起、展开。
private enum IslandPhase {
    case collapsed, expanded
}

// MARK: - 尺寸

/// 灵动岛几何没有公开 API 可取，这里用 iPhone 14 Pro 之后机型的实测值，并允许运行时微调。
private struct IslandMetrics {
    var collapsedWidth: CGFloat = 126
    var collapsedHeight: CGFloat = 37.33
    /// 在 iPhone 17 Pro 模拟器上量出来的实际值，比常见的 11 略低；不同机型可用下方微调对齐。
    var topInset: CGFloat = 13.5
    var ringGap: CGFloat = 3
    var ringWidth: CGFloat = 2
    /// 点击热区在红框之外再外扩的距离。
    var hitSlop: CGFloat = 14
    /// 收起态「点击展开」的热区高度，从屏幕顶端算起，必须越过约 54pt 的状态栏触摸死区。
    var tapBandHeight: CGFloat = 140

    var expandedWidth: CGFloat = 371
    var expandedHeight: CGFloat = 160
    var expandedCornerRadius: CGFloat = 44

    func size(for phase: IslandPhase) -> CGSize {
        switch phase {
        case .collapsed: return CGSize(width: collapsedWidth, height: collapsedHeight)
        case .expanded: return CGSize(width: expandedWidth, height: expandedHeight)
        }
    }

    func cornerRadius(for phase: IslandPhase) -> CGFloat {
        switch phase {
        case .collapsed: return collapsedHeight / 2
        case .expanded: return expandedCornerRadius
        }
    }
}

// MARK: - 设备探测

private enum DeviceProbe {
    /// 用安全区顶部高度粗略判断当前 iPhone 是否带灵动岛。
    static var hasDynamicIsland: Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let top = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .compactMap { $0.keyWindow?.safeAreaInsets.top }
            .max() ?? 0
        return top >= 51
        #else
        return false
        #endif
    }
}

// MARK: - 实时活动实测台

// `InAppIslandActivityAttributes` 定义在 IslandWidget/IslandActivityAttributes.swift，
// 由 App 与 widget extension 两个 target 共享。

/// 时间线里的一条记录。
private struct LabLogEntry: Identifiable {
    let id = UUID()
    let stamp: String
    let symbol: String
    let title: String
    let detail: String?
    let tint: Color
}

/// 实测台的整体状态，决定卡片顶部那行文案与图标。
private enum LabStatus {
    case unsupported
    case denied
    case idle
    case running(Int)
    case failed(String)

    var title: String {
        switch self {
        case .unsupported: return "当前平台不支持实时活动"
        case .denied: return "系统未开启实时活动权限，去「设置 → ios-lab → 实时活动」打开"
        case .idle: return "本 App 当前没有运行中的 Live Activity"
        case .running(let count): return "本 App 有 \(count) 个 Live Activity 正在运行"
        case .failed(let message): return "启动失败：\(message)"
        }
    }

    var symbol: String {
        switch self {
        case .unsupported: return "xmark.circle"
        case .denied: return "exclamationmark.triangle.fill"
        case .idle: return "circle"
        case .running: return "dot.radiowaves.left.and.right"
        case .failed: return "exclamationmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unsupported: return .gray
        case .denied: return .orange
        case .idle: return .gray
        case .running: return .green
        case .failed: return .red
        }
    }
}

/// 驱动实测的模型：启动/结束自家 Live Activity，并把前后台切换与活动状态变化记成时间线。
///
/// 核心用法是「切后台看岛、切回前台看时间线」——如果回到前台那一刻活动状态还是 active，
/// 就说明岛的消失是系统渲染层面的隐藏，而不是活动被结束了。
@Observable
private final class LiveActivityLab {
    private(set) var entries: [LabLogEntry] = []
    private(set) var activityCount = 0
    private(set) var status: LabStatus = .idle

    /// 已经离开过前台，用来跳过页面首次出现时的那次 `.active`。
    private var didLeaveForeground = false
    private var foregroundReturns = 0

    #if os(iOS)
    private var activity: Activity<InAppIslandActivityAttributes>?
    private var startedAt = Date()
    private var observation: Task<Void, Never>?
    #endif

    var isSupported: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    var canStart: Bool {
        #if os(iOS)
        return ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        return false
        #endif
    }

    // MARK: 生命周期

    /// 进入页面时接管已经在跑的活动（比如上次离开页面时留下的），不结束任何东西。
    func adoptRunningActivity() {
        #if os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = .denied
            return
        }

        let running = Activity<InAppIslandActivityAttributes>.activities
        activityCount = running.count

        if let existing = running.first {
            activity = existing
            startedAt = existing.content.state.startedAt
            foregroundReturns = existing.content.state.foregroundReturns
            observe(existing)
            log("接管了已在运行的活动", detail: "状态 \(existing.activityState.label)", symbol: "arrow.triangle.2.circlepath", tint: .green)
        }

        refreshStatus()
        #else
        status = .unsupported
        #endif
    }

    func start() {
        #if os(iOS)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status = .denied
            return
        }

        startedAt = Date()
        foregroundReturns = 0
        didLeaveForeground = false

        let attributes = InAppIslandActivityAttributes(demoTitle: "ios-lab · 灵动岛实测")
        let state = InAppIslandActivityAttributes.ContentState(startedAt: startedAt, foregroundReturns: 0)

        do {
            let requested = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activity = requested
            observe(requested)
            log("已启动 Live Activity", detail: "现在上滑回桌面，系统灵动岛上会出现它", symbol: "play.circle.fill", tint: .green)
        } catch {
            log("启动失败", detail: error.localizedDescription, symbol: "exclamationmark.octagon.fill", tint: .red)
            status = .failed(error.localizedDescription)
            return
        }

        refreshStatus()
        #endif
    }

    func endAll() {
        #if os(iOS)
        let running = Activity<InAppIslandActivityAttributes>.activities
        guard !running.isEmpty else {
            refreshStatus()
            return
        }

        observation?.cancel()
        observation = nil
        activity = nil

        Task {
            for item in running {
                await item.end(nil, dismissalPolicy: .immediate)
            }
            log("已结束 \(running.count) 个活动", detail: "这一次岛是真的没了，不是被藏起来", symbol: "stop.circle.fill", tint: .orange)
            refreshStatus()
        }
        #endif
    }

    func clearLog() {
        entries.removeAll()
    }

    // MARK: 前后台

    func handleScenePhase(_ phase: ScenePhase) {
        #if os(iOS)
        switch phase {
        case .background:
            didLeaveForeground = true
            log("App 进入后台", detail: currentStateDetail(prefix: "此时灵动岛应当可见"), symbol: "arrow.down.right.circle", tint: .blue)

        case .active:
            guard didLeaveForeground else { return }
            didLeaveForeground = false
            foregroundReturns += 1
            log("App 回到前台", detail: currentStateDetail(prefix: "灵动岛已消失"), symbol: "arrow.up.left.circle", tint: .purple)
            pushForegroundReturn()

        default:
            break
        }

        refreshStatus()
        #endif
    }

    // MARK: 内部

    #if os(iOS)
    /// 回到前台时把计数写进活动内容。下次切后台岛上的数字会变，说明它一直活着。
    private func pushForegroundReturn() {
        guard let activity else { return }
        let state = InAppIslandActivityAttributes.ContentState(startedAt: startedAt, foregroundReturns: foregroundReturns)

        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private func observe(_ activity: Activity<InAppIslandActivityAttributes>) {
        observation?.cancel()
        observation = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                self?.log("活动状态变为 \(state.label)", detail: nil, symbol: "waveform.path.ecg", tint: state == .active ? .green : .orange)
                self?.refreshStatus()
            }
        }
    }

    /// 时间线的关键一句：把当前 activityState 摊在明面上。
    private func currentStateDetail(prefix: String) -> String {
        guard let activity else { return "\(prefix)；当前没有活动" }
        return "\(prefix)；活动状态 = \(activity.activityState.label)，回前台 \(foregroundReturns) 次"
    }

    private func refreshStatus() {
        let running = Activity<InAppIslandActivityAttributes>.activities
        activityCount = running.count
        status = running.isEmpty ? .idle : .running(running.count)
    }
    #endif

    /// 只在时间线里用，固定格式，不跟随区域设置。
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func log(_ title: String, detail: String?, symbol: String, tint: Color) {
        entries.insert(
            LabLogEntry(stamp: Self.stampFormatter.string(from: Date()), symbol: symbol, title: title, detail: detail, tint: tint),
            at: 0
        )
        if entries.count > 40 { entries.removeLast(entries.count - 40) }
    }
}

#if os(iOS)
private extension ActivityState {
    /// `ActivityState` 没有可读描述，这里给时间线用。
    var label: String {
        switch self {
        case .active: return "active"
        case .ended: return "ended"
        case .dismissed: return "dismissed"
        case .stale: return "stale"
        @unknown default: return "unknown"
        }
    }
}
#endif

#Preview("App 内灵动岛") {
    NavigationStack {
        InAppDynamicIslandView()
    }
}
