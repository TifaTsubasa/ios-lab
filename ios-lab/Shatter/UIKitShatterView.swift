//
//  UIKitShatterView.swift
//  ios-lab
//
//  Demo：UIKit 版的视图碎裂。
//
//  这一页刻意全部用**真的 UIKit 控件**（UILabel / UISwitch / UISlider / UIButton /
//  UITextField / UIImageView），而且碎之前都能正常交互 —— 因为 SwiftUI 那条路线
//  对 UIViewRepresentable 是直接失效的（内容会变成「无法渲染」占位符），
//  这一页存在的意义就是证明 UIKit 这条路真的走通了。
//

import SwiftUI
import UIKit

// MARK: - SwiftUI 入口

struct UIKitShatterView: View {
    var body: some View {
        UIKitShatterHost()
            .ignoresSafeArea(edges: .bottom)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

private struct UIKitShatterHost: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIKitShatterViewController {
        UIKitShatterViewController()
    }
    func updateUIViewController(_ vc: UIKitShatterViewController, context: Context) {}
}

// MARK: - 控制器

final class UIKitShatterViewController: UIViewController {

    private var style: ShatterStyle = .inkSplat
    private var inkColor = UIColor(red: 0.58, green: 0.95, blue: 0.10, alpha: 1)
    private var autoRespawn = true

    private var targets: [UIView] = []
    private let styleControl = UISegmentedControl(items: ShatterStyle.allCases.map(\.title))
    private let colorRow = UIStackView()
    private let hintLabel = UILabel()
    private var colorButtons: [UIButton] = []

    private let teamColors: [UIColor] = [
        UIColor(red: 0.58, green: 0.95, blue: 0.10, alpha: 1),
        UIColor(red: 1.00, green: 0.16, blue: 0.55, alpha: 1),
        UIColor(red: 0.12, green: 0.82, blue: 0.98, alpha: 1),
        UIColor(red: 1.00, green: 0.52, blue: 0.05, alpha: 1),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1)
        buildChrome()
        buildTargets()
    }

    // MARK: 顶部控件

    private func buildChrome() {
        styleControl.selectedSegmentIndex = ShatterStyle.allCases.firstIndex(of: style) ?? 0
        styleControl.selectedSegmentTintColor = inkColor
        styleControl.setTitleTextAttributes([.foregroundColor: UIColor.white.withAlphaComponent(0.7)],
                                            for: .normal)
        styleControl.setTitleTextAttributes([.foregroundColor: UIColor.black], for: .selected)
        styleControl.addTarget(self, action: #selector(styleChanged), for: .valueChanged)
        styleControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(styleControl)

        colorRow.axis = .horizontal
        colorRow.spacing = 12
        colorRow.translatesAutoresizingMaskIntoConstraints = false
        for (i, c) in teamColors.enumerated() {
            let b = UIButton(type: .custom)
            b.backgroundColor = c
            b.layer.cornerRadius = 13
            b.tag = i
            b.layer.borderColor = UIColor.white.cgColor
            b.layer.borderWidth = (i == 0) ? 2 : 0
            b.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            colorButtons.append(b)
            colorRow.addArrangedSubview(b)
        }
        view.addSubview(colorRow)

        hintLabel.text = "点卡片空白处碎掉 · 控件本身照常能用"
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        hintLabel.textAlignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hintLabel)

        var restoreCfg = UIButton.Configuration.gray()
        restoreCfg.title = "全部复原"
        restoreCfg.cornerStyle = .capsule
        restoreCfg.baseForegroundColor = .white
        restoreCfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20)
        let restore = UIButton(configuration: restoreCfg)
        restore.addTarget(self, action: #selector(restoreAll), for: .touchUpInside)
        restore.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(restore)

        let autoLabel = UILabel()
        autoLabel.text = "自动重生"
        autoLabel.font = .systemFont(ofSize: 13)
        autoLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        let autoSwitch = UISwitch()
        autoSwitch.isOn = autoRespawn
        autoSwitch.onTintColor = inkColor
        autoSwitch.addTarget(self, action: #selector(autoChanged(_:)), for: .valueChanged)
        let autoRow = UIStackView(arrangedSubviews: [autoLabel, autoSwitch])
        autoRow.spacing = 8
        autoRow.alignment = .center
        autoRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(autoRow)

        NSLayoutConstraint.activate([
            styleControl.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            styleControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            styleControl.widthAnchor.constraint(equalToConstant: 220),

            colorRow.topAnchor.constraint(equalTo: styleControl.bottomAnchor, constant: 14),
            colorRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            hintLabel.topAnchor.constraint(equalTo: colorRow.bottomAnchor, constant: 14),
            hintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            restore.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
            restore.centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: -70),

            autoRow.centerYAnchor.constraint(equalTo: restore.centerYAnchor),
            autoRow.leadingAnchor.constraint(equalTo: restore.trailingAnchor, constant: 20),
        ])
    }

    // MARK: 碎裂目标

    private func buildTargets() {
        let card = makeControlCard()
        let image = makeImageCard()
        let field = makeFieldCard()
        targets = [card, image, field]

        for t in targets {
            t.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(t)
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            t.addGestureRecognizer(tap)
        }

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 22),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.widthAnchor.constraint(equalToConstant: 300),
            card.heightAnchor.constraint(equalToConstant: 190),

            image.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 26),
            image.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            image.widthAnchor.constraint(equalToConstant: 132),
            image.heightAnchor.constraint(equalToConstant: 96),

            field.topAnchor.constraint(equalTo: image.topAnchor),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            field.widthAnchor.constraint(equalToConstant: 148),
            field.heightAnchor.constraint(equalToConstant: 96),
        ])
    }

    /// 一张塞满真控件的卡片：Label + Switch + Slider + Button，碎之前都能正常操作
    private func makeControlCard() -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(red: 0.20, green: 0.24, blue: 0.52, alpha: 1)
        card.layer.cornerRadius = 26
        card.clipsToBounds = true

        let title = UILabel()
        title.text = "UIKit 原生控件"
        title.font = .systemFont(ofSize: 19, weight: .bold)
        title.textColor = .white

        let sub = UILabel()
        sub.text = "UILabel · UISwitch · UISlider · UIButton"
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = UIColor.white.withAlphaComponent(0.6)

        let sw = UISwitch()
        sw.isOn = true
        sw.onTintColor = UIColor(red: 0.35, green: 0.85, blue: 0.55, alpha: 1)

        let slider = UISlider()
        slider.value = 0.62
        slider.minimumTrackTintColor = .systemOrange

        let row = UIStackView(arrangedSubviews: [sw, slider])
        row.spacing = 14
        row.alignment = .center

        var cfg = UIButton.Configuration.filled()
        cfg.title = "我是 UIButton"
        cfg.baseBackgroundColor = .systemOrange
        cfg.cornerStyle = .capsule
        let button = UIButton(configuration: cfg)
        button.addTarget(self, action: #selector(demoButtonTapped(_:)), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [title, sub, row, button])
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
        ])
        return card
    }

    private func makeImageCard() -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(red: 0.66, green: 0.25, blue: 0.42, alpha: 1)
        card.layer.cornerRadius = 22
        card.clipsToBounds = true

        let iv = UIImageView(image: UIImage(systemName: "photo.artframe"))
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 46),
            iv.heightAnchor.constraint(equalToConstant: 46),
        ])
        return card
    }

    private func makeFieldCard() -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(red: 0.15, green: 0.45, blue: 0.42, alpha: 1)
        card.layer.cornerRadius = 22
        card.clipsToBounds = true

        let field = UITextField()
        field.text = "可编辑"
        field.borderStyle = .roundedRect
        field.font = .systemFont(ofSize: 14)
        field.translatesAutoresizingMaskIntoConstraints = false

        let caption = UILabel()
        caption.text = "UITextField"
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = UIColor.white.withAlphaComponent(0.7)
        caption.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(field)
        card.addSubview(caption)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: card.centerYAnchor, constant: -6),
            caption.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            caption.centerXAnchor.constraint(equalTo: card.centerXAnchor),
        ])
        return card
    }

    // MARK: 交互

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let target = g.view, !target.isHidden else { return }
        let point = g.location(in: target)
        let ok = target.shatter(config: config(for: target), at: point) { [weak self, weak target] in
            guard let self, let target else { return }
            guard self.autoRespawn else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                target.isHidden = false
            }
        }
        // Metal 不可用 / 截图失败时兜底，别让点击毫无反应
        if !ok { target.isHidden = true }
    }

    private func config(for target: UIView) -> ShatterConfig {
        var c = ShatterConfig()
        c.style = style
        c.cornerRadius = target.layer.cornerRadius
        c.ink.color = Color(inkColor)
        // 小卡片上墨带和散墨格子要按比例收，否则一喷就整块糊死
        let small = min(target.bounds.width, target.bounds.height) < 120
        if small {
            c.shatterDuration = 0.32
            c.dropletCount = 100
            c.ink.bandWidth = 16
            c.ink.speckleCell = 20
            c.ink.speckleLead = 24
            c.sprayMargin = 100
        }
        return c
    }

    @objc private func styleChanged() {
        style = ShatterStyle.allCases[styleControl.selectedSegmentIndex]
        colorRow.isHidden = (style != .inkSplat)
        restoreAll()
    }

    @objc private func colorTapped(_ sender: UIButton) {
        inkColor = teamColors[sender.tag]
        for (i, b) in colorButtons.enumerated() {
            b.layer.borderWidth = (i == sender.tag) ? 2 : 0
        }
        styleControl.selectedSegmentTintColor = inkColor
    }

    @objc private func autoChanged(_ sender: UISwitch) {
        autoRespawn = sender.isOn
    }

    @objc private func restoreAll() {
        for t in targets { t.isHidden = false }
    }

    /// 证明碎之前控件是真能点的
    @objc private func demoButtonTapped(_ sender: UIButton) {
        var cfg = sender.configuration
        cfg?.title = "点到了！"
        sender.configuration = cfg
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            var back = sender.configuration
            back?.title = "我是 UIButton"
            sender.configuration = back
        }
    }
}

#Preview {
    NavigationStack {
        UIKitShatterView()
    }
    .preferredColorScheme(.dark)
}
