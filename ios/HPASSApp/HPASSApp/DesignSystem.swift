import SwiftUI
import UIKit

// MARK: - 设计令牌
//
// 新界面只用这里的颜色、字体、间距和组件，见 docs/uiux-redesign.md 第 4、5 节。
// 颜色都基于系统语义色或成对定义（浅色 / 深色），深色模式自动切换。

enum DS {

    // MARK: 颜色

    enum Palette {
        static let accent = Color.accentColor
        static let success = Color(uiColor: .systemGreen)
        static let warning = Color(uiColor: .systemOrange)
        static let danger = Color(uiColor: .systemRed)
        static let info = Color(uiColor: .systemBlue)
        static let neutral = Color(uiColor: .systemGray)
        static let mapping = Color(uiColor: .systemIndigo)

        /// 路线渐变
        static let routeStart = Color(uiColor: .systemBlue)
        static let routeEnd = Color(uiColor: .systemIndigo)

        static let background = Color(uiColor: .systemGroupedBackground)
        static let surface = Color(uiColor: .secondarySystemGroupedBackground)
        static let surfaceRaised = Color(uiColor: .tertiarySystemGroupedBackground)
        static let separator = Color(uiColor: .separator)
        static let textPrimary = Color(uiColor: .label)
        static let textSecondary = Color(uiColor: .secondaryLabel)
        static let textTertiary = Color(uiColor: .tertiaryLabel)

        // 地图
        static let mapFloor = dynamic(light: UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1),
                                      dark: UIColor(red: 0.110, green: 0.110, blue: 0.118, alpha: 1))
        static let mapCorridor = dynamic(light: .white,
                                         dark: UIColor(red: 0.173, green: 0.173, blue: 0.180, alpha: 1))
        static let mapObstacle = dynamic(light: UIColor(red: 0.820, green: 0.820, blue: 0.839, alpha: 1),
                                         dark: UIColor(red: 0.227, green: 0.227, blue: 0.235, alpha: 1))
        static let mapObstacleStroke = dynamic(light: UIColor(red: 0.682, green: 0.682, blue: 0.698, alpha: 1),
                                               dark: UIColor(red: 0.329, green: 0.329, blue: 0.345, alpha: 1))
        static let mapGrid = dynamic(light: UIColor.black.withAlphaComponent(0.06),
                                     dark: UIColor.white.withAlphaComponent(0.06))
        /// 蓝点外圈描边
        static let dotRing = dynamic(light: .white, dark: UIColor(white: 0.95, alpha: 1))

        static func dynamic(light: UIColor, dark: UIColor) -> Color {
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }
    }

    // MARK: 字体（只用动态字体，跟随系统字号）

    enum Typography {
        static let hero = Font.system(.title, design: .rounded).weight(.bold)
        static let metric = Font.system(.title2, design: .rounded).weight(.semibold)
        static let title = Font.title3.weight(.semibold)
        static let headline = Font.headline
        static let body = Font.body
        static let callout = Font.callout
        static let caption = Font.footnote
        static let micro = Font.caption2.weight(.semibold)
    }

    // MARK: 间距 / 圆角

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 10
        static let card: CGFloat = 18
        static let sheet: CGFloat = 24
    }

    /// 最小点击区域
    static let minTap: CGFloat = 44
}

extension View {
    /// 浮在地图上的元素：材质背景 + 轻阴影
    func dsFloating(cornerRadius: CGFloat = DS.Radius.card) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
    }

    /// 卡片背景
    func dsCardBackground() -> some View {
        self.background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
    }
}

// MARK: - 触感反馈

@MainActor
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}

// MARK: - 卡片

struct DSCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    var tint: Color = DS.Palette.accent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            if let title {
                HStack(spacing: DS.Spacing.s) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tint)
                            .accessibilityHidden(true)
                    }
                    Text(title).font(DS.Typography.headline)
                    Spacer(minLength: 0)
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardBackground()
    }
}

// MARK: - 按钮

struct DSPrimaryButtonStyle: ButtonStyle {
    var tint: Color = DS.Palette.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, DS.Spacing.l)
            .background((isEnabled ? tint : DS.Palette.neutral.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct DSSecondaryButtonStyle: ButtonStyle {
    var tint: Color = DS.Palette.accent
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? tint : DS.Palette.textTertiary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, DS.Spacing.l)
            .background(tint.opacity(isEnabled ? 0.12 : 0.05),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == DSPrimaryButtonStyle {
    static var dsPrimary: DSPrimaryButtonStyle { DSPrimaryButtonStyle() }
    static func dsPrimaryTint(_ tint: Color) -> DSPrimaryButtonStyle { DSPrimaryButtonStyle(tint: tint) }
}

extension ButtonStyle where Self == DSSecondaryButtonStyle {
    static var dsSecondary: DSSecondaryButtonStyle { DSSecondaryButtonStyle() }
    static func dsSecondaryTint(_ tint: Color) -> DSSecondaryButtonStyle { DSSecondaryButtonStyle(tint: tint) }
}

/// 地图上的圆形浮动按钮
struct DSIconButton: View {
    let systemImage: String
    let label: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(.body).weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(active ? Color.white : DS.Palette.accent)
                .frame(width: DS.minTap, height: DS.minTap)
                .background {
                    if active {
                        Circle().fill(DS.Palette.accent)
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - 状态胶囊

struct StatusPill: View {
    enum Tone { case neutral, info, success, warning, danger, mapping }

    let text: String
    var systemImage: String?
    var tone: Tone = .neutral
    var busy = false

    var color: Color {
        switch tone {
        case .neutral: return DS.Palette.neutral
        case .info: return DS.Palette.info
        case .success: return DS.Palette.success
        case .warning: return DS.Palette.warning
        case .danger: return DS.Palette.danger
        case .mapping: return DS.Palette.mapping
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if busy {
                ProgressView().controlSize(.mini).tint(color)
            } else if let systemImage {
                Image(systemName: systemImage).imageScale(.small)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text).lineLimit(1)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - 步骤条

struct DSStepIndicator: View {
    let steps: [String]
    let current: Int

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(steps.indices, id: \.self) { i in
                VStack(spacing: 6) {
                    Capsule()
                        .fill(i <= current ? DS.Palette.accent : DS.Palette.separator.opacity(0.6))
                        .frame(height: 4)
                    Text(steps[i])
                        .font(.caption2.weight(i == current ? .bold : .regular))
                        .foregroundStyle(i == current ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(current + 1) 步，共 \(steps.count) 步：\(steps.indices.contains(current) ? steps[current] : "")")
    }
}

// MARK: - 进度环

struct ProgressRing: View {
    let value: Double
    var lineWidth: CGFloat = 10
    var tint: Color = DS.Palette.success
    var label: String?

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: value)
            VStack(spacing: 0) {
                Text("\(Int((min(max(value, 0), 1) * 100).rounded()))%")
                    .font(DS.Typography.metric)
                    .monospacedDigit()
                if let label {
                    Text(label).font(.caption2).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "进度")
        .accessibilityValue("\(Int((min(max(value, 0), 1) * 100).rounded()))%")
    }
}

// MARK: - 指标

struct MetricTile: View {
    let value: String
    var unit: String?
    let label: String
    var tint: Color = DS.Palette.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(DS.Typography.metric).monospacedDigit().foregroundStyle(tint)
                if let unit { Text(unit).font(.footnote.weight(.medium)).foregroundStyle(DS.Palette.textSecondary) }
            }
            Text(label).font(.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value + (unit ?? ""))
    }
}

// MARK: - 清单

struct ChecklistRow: View {
    enum Status { case ok, warning, missing }
    let state: Status
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: icon)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if let detail { Text(detail).font(.footnote).foregroundStyle(DS.Palette.textSecondary) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .ok ? "已就绪" : (state == .warning ? "建议处理" : "未就绪"))
    }

    private var icon: String {
        switch state {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .missing: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .ok: return DS.Palette.success
        case .warning: return DS.Palette.warning
        case .missing: return DS.Palette.danger
        }
    }
}

// MARK: - 空状态 / 加载 / 出错 / 权限

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Spacing.l) {
            Image(systemName: systemImage)
                .font(.system(size: 52, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(DS.Palette.accent)
                .accessibilityHidden(true)
            VStack(spacing: DS.Spacing.s) {
                Text(title).font(DS.Typography.title).multilineTextAlignment(.center)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.dsPrimary)
            }
            if let secondaryTitle, let secondaryAction {
                Button(secondaryTitle, action: secondaryAction).buttonStyle(.dsSecondary)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .contain)
    }
}

struct LoadingStateView: View {
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            ProgressView().controlSize(.large)
            Text(title).font(DS.Typography.headline)
            if let message {
                Text(message).font(.footnote).foregroundStyle(DS.Palette.textSecondary).multilineTextAlignment(.center)
            }
        }
        .padding(DS.Spacing.xl)
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let message: String
    var retryTitle = "重试"
    var onRetry: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Palette.danger)
                .accessibilityHidden(true)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let onRetry {
                Button(retryTitle, action: onRetry).font(.footnote.weight(.semibold))
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(DS.Palette.textSecondary)
                }
                .accessibilityLabel("关闭")
            }
        }
        .padding(DS.Spacing.m)
        .background(DS.Palette.danger.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.small, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("出错：\(message)")
    }
}

/// 权限说明：为什么需要、怎么打开
struct PermissionExplainer: View {
    struct Item: Identifiable {
        let systemImage: String
        let title: String
        let reason: String
        var id: String { title }
    }

    let items: [Item]

    static let positioning: [Item] = [
        Item(systemImage: "gyroscope", title: "运动与健身", reason: "用加速度计、陀螺仪推算你走了多远、朝哪走"),
        Item(systemImage: "camera", title: "相机", reason: "视觉里程计让定位更稳，画面只在本机处理、不保存"),
        Item(systemImage: "location", title: "位置（使用期间）", reason: "只读罗盘方向，不使用你的地理位置"),
        Item(systemImage: "antenna.radiowaves.left.and.right", title: "蓝牙（可选）", reason: "附近有蓝牙信标时辅助定位"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            ForEach(items) { it in
                HStack(alignment: .top, spacing: DS.Spacing.m) {
                    Image(systemName: it.systemImage)
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(DS.Palette.accent)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(it.title).font(.callout.weight(.semibold))
                        Text(it.reason).font(.footnote).foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Label("在系统设置里管理权限", systemImage: "gear")
                    .font(.footnote.weight(.semibold))
            }
        }
    }
}

// MARK: - 楼层切换

struct FloorSwitcher: View {
    let floors: [String]
    @Binding var selection: Int

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "square.3.layers.3d")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: DS.minTap, height: 30)
                .accessibilityHidden(true)
            ForEach(floors.indices, id: \.self) { i in
                Button {
                    Haptics.selection()
                    withAnimation(.easeInOut(duration: 0.2)) { selection = i }
                } label: {
                    Text(floors[i])
                        .font(.footnote.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(i == selection ? Color.white : DS.Palette.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(i == selection ? DS.Palette.accent : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(width: DS.minTap, height: DS.minTap)
                .accessibilityLabel("楼层 \(floors[i])")
                .accessibilityAddTraits(i == selection ? .isSelected : [])
            }
        }
        .padding(.bottom, 4)
        .dsFloating(cornerRadius: 14)
    }
}

// MARK: - 转向提示卡片

struct TurnCard: View {
    enum Maneuver { case straight, left, right, uturn, arrived, offRoute, planning }

    let maneuver: Maneuver
    let primary: String
    var secondary: String?
    var remaining: String?
    var onEnd: (() -> Void)?

    var body: some View {
        HStack(spacing: DS.Spacing.l) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(primary).font(DS.Typography.title).lineLimit(2).minimumScaleFactor(0.8)
                if let secondary {
                    Text(secondary).font(.footnote).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: DS.Spacing.s) {
                if let remaining {
                    Text(remaining).font(DS.Typography.metric).monospacedDigit()
                }
                if let onEnd {
                    Button("结束", action: onEnd)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(DS.Palette.danger)
                        .accessibilityLabel("结束导航")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch maneuver {
        case .straight: return "arrow.up"
        case .left: return "arrow.turn.up.left"
        case .right: return "arrow.turn.up.right"
        case .uturn: return "arrow.uturn.down"
        case .arrived: return "flag.checkered"
        case .offRoute: return "arrow.triangle.2.circlepath"
        case .planning: return "ellipsis"
        }
    }

    private var tint: Color {
        switch maneuver {
        case .arrived: return DS.Palette.success
        case .offRoute: return DS.Palette.warning
        case .planning: return DS.Palette.neutral
        default: return DS.Palette.accent
        }
    }
}

// MARK: - 设置行

struct DSRowLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = DS.Palette.accent
    var subtitle: String?

    var body: some View {
        HStack(spacing: DS.Spacing.m) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
    }
}
