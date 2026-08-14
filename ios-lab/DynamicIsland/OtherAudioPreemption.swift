//
//  OtherAudioPreemption.swift
//  ios-lab
//
//  让「别的 App 的音乐岛」在进入本页面时消失。
//
//  关键在于分清两种岛：
//  1. Apple Music / Spotify 那种，是系统的 Now Playing 指示器，跟着**播放状态**走。
//     音乐一暂停，那个岛过几秒自己就没了。
//  2. ActivityKit 的 Live Activity（外卖、比分、计时器），Apple 明确没有任何 API 能关掉别家的。
//
//  这里走的是第 1 条：把 audio session 设成非混音的 .playback 再激活，
//  系统会打断其他非混音会话——Apple Music 被暂停，它的岛随之消失。
//  代价是真的停了用户的音乐，不是视觉上的隐藏，离开页面时要记得归还。
//

import SwiftUI
#if os(iOS)
import AVFAudio
#endif

// MARK: - 模型

/// 抢占系统音频会话，用来打断其他 App 正在播放的音频。
@Observable
final class AudioPreemptionLab {
    /// 抢占之前，系统里是否有别的 App 在出声。
    private(set) var isOtherAudioPlaying = false
    private(set) var hasPreempted = false
    private(set) var lastError: String?

    var isSupported: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// 刷新「现在有没有别的 App 在放音频」。抢占成功后这里会变成 false。
    func refresh() {
        #if os(iOS)
        isOtherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
        #endif
    }

    /// 打断其他音频：非混音的 .playback 一旦激活，系统就会中断其他非混音会话。
    func preempt() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        isOtherAudioPlaying = session.isOtherAudioPlaying

        do {
            // options 留空就是非混音；加上 .mixWithOthers 反而不会打断别人。
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            hasPreempted = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            hasPreempted = false
        }

        refresh()
        #endif
    }

    /// 归还会话。`.notifyOthersOnDeactivation` 会通知刚才被打断的 App，让它有机会恢复播放。
    func release() {
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }

        hasPreempted = false
        refresh()
        #endif
    }
}

// MARK: - 卡片

/// 页面里的「别的 App 的音乐岛」区块。
struct OtherAudioPreemptionCard: View {
    @Bindable var lab: AudioPreemptionLab
    @Binding var autoPreempt: Bool
    let foreground: Color

    private var accent: Color { Color(red: 0.98, green: 0.45, blue: 0.32) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("别的 App 的音乐岛")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground)
            } icon: {
                Image(systemName: lab.hasPreempted ? "speaker.slash.fill" : "music.note")
                    .foregroundStyle(lab.hasPreempted ? .green : .gray)
            }

            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            if lab.isSupported {
                Toggle("进入页面自动打断", isOn: $autoPreempt)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(foreground)
                    .tint(accent)

                HStack(spacing: 10) {
                    Button {
                        lab.preempt()
                    } label: {
                        Text("打断其他音频")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(lab.hasPreempted)

                    Button {
                        lab.release()
                    } label: {
                        Text("归还会话")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(foreground.opacity(0.6))
                    .disabled(!lab.hasPreempted)
                }
            }

            Text("Apple Music 的岛是系统 Now Playing 指示器，跟播放状态走。非混音的 .playback 会话一激活就打断它，音乐暂停后那个岛过几秒自己消失。")
                .font(.system(size: 12))
                .foregroundStyle(foreground.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)

            Text("注意这是真的把用户的音乐停了，不是视觉隐藏；离开页面会自动归还会话。外卖、比分、计时器那种 Live Activity 不吃这一套，那个确实关不掉。")
                .font(.system(size: 12))
                .foregroundStyle(.orange.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(foreground.opacity(0.06))
        )
    }

    private var statusText: String {
        if !lab.isSupported { return "当前平台没有 AVAudioSession" }
        if let error = lab.lastError { return "音频会话操作失败：\(error)" }
        if lab.hasPreempted {
            return "已抢占音频会话，其他 App 的音频被打断，它们的岛应当已经消失"
        }
        return lab.isOtherAudioPlaying ? "检测到有别的 App 正在放音频" : "当前没有检测到别的 App 在放音频"
    }
}
