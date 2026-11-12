import CoreMotion
import HPASSKit
import SwiftUI

/// 磁力计偏置的「体检 + 强制校准」。
///
/// 为什么要有：这台测试机的硬铁偏置隔几天就跳 100～300 µT（磁吸配件 / 被磁化），iOS 自己的校准跟不上，
/// 还照样报「高精度」，于是地磁定位、指南针、建图都会偏。
/// - 体检：每次开始建图采集前，读 2 秒原始磁力计，用本机存的偏置扣掉后 |B| 应该像地磁（15～90 µT）。
///   没有存档、或者对不上，就弹全屏校准，校准好了才开始采集。
/// - 校准：用户拿手机画 8 字，用陀螺仪姿态 + 原始磁力计解偏置（HardIronCalibration），
///   达标（转够、残差小、地磁强度合理、结果稳定）才存档关掉；不达标一直在这页。
@MainActor
final class MagCalibrationCenter: ObservableObject {
    static let shared = MagCalibrationCenter()

    /// 全屏校准页是否弹出
    @Published var presented = false
    @Published private(set) var reason = ""
    @Published private(set) var running = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var hint = ""
    @Published private(set) var finished: HardIronCalibration.Result?
    @Published private(set) var elapsed: Double = 0

    /// 校准页一直没达标多久后，给一个「这次先跳过」
    static let skipAfterS: Double = 90

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "magcal"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    /// 正在做采集前体检（约 2 秒），界面显示「检查磁力计…」
    @Published private(set) var checking = false
    /// 体检 / 校准通过后要做的事（开始采集）
    private var pending: (@MainActor () -> Void)?
    private var startedAt: Date?
    private static let owner = "磁力计校准"

    // MARK: 体检

    /// 开始建图采集前调用：先读 2 秒原始磁力计核对本机偏置，通过才执行 `action`；
    /// 没有存档或对不上就弹全屏校准，校准完成（或超时后跳过）再执行。
    func gate(_ action: @escaping @MainActor () -> Void) {
        guard !DemoMode.isOn, manager.isMagnetometerAvailable else { action(); return }
        guard !checking, !presented else { return }
        pending = action
        guard let stored = MagBiasStore.load() else {
            require("这台手机还没有做过磁力计校准，采集前要先做一次")
            return
        }
        checking = true
        SensorArbiter.shared.claim(Self.owner + "·检查") { [weak self] in
            Task { @MainActor in self?.cancelCheck() }
        }
        let box = CheckBox()
        manager.magnetometerUpdateInterval = 0.02
        manager.startMagnetometerUpdates(to: queue) { d, _ in
            guard let f = d?.magneticField else { return }
            box.add((f.x, f.y, f.z))
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard self.checking else { return }
            self.manager.stopMagnetometerUpdates()
            self.checking = false
            SensorArbiter.shared.release(Self.owner + "·检查")
            guard let med = HardIronCheck.medianField(raw: box.all, bias: stored.bias) else {
                self.runPending()       // 读不到数就不拦
                return
            }
            if HardIronCheck.plausibleUT.contains(med) {
                AppLog.i("地磁", "采集前磁力计体检通过：扣掉本机偏置后 |B| \(Int(med)) µT（偏置来源 \(stored.source)）")
                self.runPending()
            } else {
                AppLog.w("地磁", "采集前磁力计体检没通过：扣掉本机偏置后 |B| \(Int(med)) µT，正常 \(Int(HardIronCheck.plausibleUT.lowerBound))～\(Int(HardIronCheck.plausibleUT.upperBound))；偏置变了，要重新校准")
                self.require("手机自身的磁场变了（扣掉旧偏置后读到 \(Int(med)) µT，正常是 15～90 µT），采集前要重新校准。常见原因：磁吸配件、磁铁靠近过手机。")
            }
        }
    }

    private func runPending() {
        let a = pending
        pending = nil
        a?()
    }

    private func cancelCheck() {
        guard checking else { return }
        manager.stopMagnetometerUpdates()
        checking = false
        pending = nil
    }

    /// 设置页手动校准，或者体检没通过
    func require(_ why: String) {
        reason = why
        finished = nil
        progress = 0
        hint = ""
        elapsed = 0
        presented = true
        AppLog.i("地磁", "弹出磁力计校准：\(why)")
    }

    // MARK: 校准

    func startCalibration() {
        guard !running, manager.isMagnetometerAvailable, manager.isDeviceMotionAvailable else {
            if !manager.isMagnetometerAvailable { hint = "这台设备没有磁力计" }
            return
        }
        SensorArbiter.shared.claim(Self.owner) { [weak self] in
            Task { @MainActor in self?.stopSensors() }
        }
        running = true
        finished = nil
        progress = 0
        startedAt = Date()
        hint = "拿稳手机，开始画 8 字"
        let st = CalBox()
        manager.deviceMotionUpdateInterval = 0.02
        manager.magnetometerUpdateInterval = 0.04
        // 不含磁力计的参考系：姿态只来自陀螺 + 加速度计，才能拿来校磁力计
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { m, _ in
            guard let m else { return }
            let r = m.attitude.rotationMatrix
            st.lastRot = (m.timestamp, [[r.m11, r.m12, r.m13], [r.m21, r.m22, r.m23], [r.m31, r.m32, r.m33]])
        }
        manager.startMagnetometerUpdates(to: queue) { [weak self] d, _ in
            guard let d, let rot = st.lastRot, abs(rot.t - d.timestamp) < 0.03 else { return }
            let f = d.magneticField
            st.cal.add(raw: (f.x, f.y, f.z), rotation: rot.r)
            guard d.timestamp - st.lastUI > 0.25 || st.cal.result != nil else { return }
            st.lastUI = d.timestamp
            let snap = Snapshot(progress: st.cal.progress, issue: st.cal.issue, result: st.cal.result)
            Task { @MainActor in self?.update(snap) }
        }
    }

    private func update(_ s: Snapshot) {
        let p = s.progress, issue = s.issue, result = s.result
        guard running else { return }
        progress = p
        elapsed = Date().timeIntervalSince(startedAt ?? Date())
        if let r = result {
            stopSensors()
            finished = r
            MagBiasStore.save((r.bias[0], r.bias[1], r.bias[2]), source: "calibrated")
            AppLog.i("地磁", "磁力计校准完成：偏置 \(Int(r.bias[0])), \(Int(r.bias[1])), \(Int(r.bias[2])) µT，地磁 \(Int(r.fieldUT)) µT，残差 \(String(format: "%.1f", r.rmsUT)) µT，用时 \(Int(elapsed)) 秒")
            Haptics.success()
            return
        }
        switch issue {
        case .noisy(let rms):
            hint = "附近磁场太乱（残差 \(Int(rms)) µT）：离开电脑、桌子腿、柜子和磁铁，原地转，别走动"
        case .fieldOutOfRange(let f):
            hint = "读到的地磁强度 \(Int(f)) µT 不对：换到离金属远一点的地方再转"
        default:
            hint = p < 0.3 ? "像画 8 字一样转手机：翻过来、竖起来、侧过来，各个方向都要转到"
                : p < 0.9 ? "继续转，再多转几个方向" : "快好了，再转几圈让结果稳定下来"
        }
    }

    private func stopSensors() {
        if manager.isMagnetometerActive { manager.stopMagnetometerUpdates() }
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
        running = false
        SensorArbiter.shared.release(Self.owner)
    }

    /// 关掉校准页（达标后「完成」，或超时后「这次先跳过」）
    func dismiss(skipped: Bool) {
        if skipped { AppLog.w("地磁", "磁力计校准没达标就跳过了，地磁定位这次会不准") }
        stopSensors()
        presented = false
        runPending()
    }

    /// 设置页手动校准：不接任何后续动作
    func calibrateManually() {
        pending = nil
        require("手动校准：换了手机壳、拿掉磁吸配件后，或者觉得方向不对时做一次")
    }
}

/// 体检时攒原始读数（传感器队列写、主线程读）
private final class CheckBox: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: [(Double, Double, Double)] = []
    func add(_ v: (Double, Double, Double)) { lock.lock(); raw.append(v); lock.unlock() }
    var all: [(Double, Double, Double)] { lock.lock(); defer { lock.unlock() }; return raw }
}

/// 校准状态：只在传感器队列（串行）上读写
private final class CalBox: @unchecked Sendable {
    var cal = HardIronCalibration()
    var lastRot: (t: TimeInterval, r: [[Double]])?
    var lastUI: TimeInterval = 0
}

private struct Snapshot: @unchecked Sendable {
    let progress: Double
    let issue: HardIronCalibration.Issue?
    let result: HardIronCalibration.Result?
}

/// 全屏校准页
struct MagCalibrationView: View {
    @ObservedObject var center = MagCalibrationCenter.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            Image(systemName: center.finished != nil ? "checkmark.seal.fill" : "infinity")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(center.finished != nil ? DS.Palette.success : DS.Palette.info)
            Text(center.finished != nil ? "校准好了" : "校准磁力计").font(DS.Typography.hero)
            if center.finished == nil {
                Text(center.reason).font(DS.Typography.callout).foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let r = center.finished {
                VStack(spacing: 6) {
                    Text("地磁强度 \(Int(r.fieldUT)) µT，残差 \(String(format: "%.1f", r.rmsUT)) µT")
                    Text("本机偏置 \(Int(r.bias[0])), \(Int(r.bias[1])), \(Int(r.bias[2])) µT").foregroundStyle(DS.Palette.textSecondary)
                }
                .font(DS.Typography.callout)
                LoggedButton(name: "磁力计校准·完成") { center.dismiss(skipped: false) } label: {
                    Text("完成").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else if center.running {
                ProgressView(value: center.progress).progressViewStyle(.linear).tint(DS.Palette.info)
                Text(center.hint).font(DS.Typography.body).multilineTextAlignment(.center)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("先拿掉磁吸卡包、磁吸支架等带磁铁的东西", systemImage: "1.circle")
                    Label("离电脑、金属桌腿、柜子远一点", systemImage: "2.circle")
                    Label("点开始后，原地拿手机在空中画 8 字，翻转到各个方向，直到进度条走满", systemImage: "3.circle")
                }
                .font(DS.Typography.callout)
                LoggedButton(name: "磁力计校准·开始") { center.startCalibration() } label: {
                    Text("开始校准").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                if !center.hint.isEmpty { Text(center.hint).font(DS.Typography.caption).foregroundStyle(DS.Palette.warning) }
            }
            Spacer()
            if center.finished == nil, center.elapsed >= MagCalibrationCenter.skipAfterS {
                LoggedButton(name: "磁力计校准·跳过", role: .destructive) { center.dismiss(skipped: true) } label: {
                    Text("这次先跳过（地磁定位会不准）").font(DS.Typography.caption)
                }
            }
        }
        .padding(24)
        .interactiveDismissDisabled(true)
    }
}
