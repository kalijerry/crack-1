import Foundation

/// 跟着建图采集一起跑的地磁定位（冷启动、不知道起点和朝向），和实时定位页「自动定位」是同一套：
/// 原始磁力计减偏置 → 特征；ARKit 的位移（自身坐标系）当运动；粒子滤波找位置。
///
/// 两个用途：
/// 1. 自动起点：在已经有磁场图的区域，开始采集后直接走，定到了就自动当起点，不用长按、设朝向；
/// 2. 精度测试：采集的轨迹（ARKit + 贴通道）当参考，看地磁定位差多少。
///
/// 非线程安全，所有调用放在同一个串行队列里。
public final class ShadowLocalizer {
    public let localizer: MagneticLocalizer
    public let rotFit = ARMapRotationFit()
    public let useRawMag: Bool

    private let extractor = MagneticFeatureExtractor()
    private let bias = RawBiasTracker()
    private var lastRaw: (t: Int64, v: (Double, Double, Double))?
    private var latest: MagneticFeature?
    private var lastA: Point2?
    private var accum = Point2.zero

    public private(set) var estimate: MagneticEstimate?
    /// 收敛之后、位置一路连续（没跳）走了多远（cm）
    public private(set) var stableCm = 0.0
    /// 最近一次 step 时的 ARKit 位置（和 estimate 同一时刻）
    public private(set) var estimateA: Point2?

    /// 每走这么远（cm）送一次滤波器
    public var stepCm = 20.0
    /// 蓝牙指纹（有就每秒用最近 2.5 秒的价签读数当粗定位，和实时定位页一样）
    public var bleMap: BLEFingerprintMap?
    private var bleWindow: [(t: Int64, id: String, rssi: Double)] = []
    private var lastBle: Int64 = 0
    /// 蓝牙交叉检验 / 不在采集区域判断（见 BLEAssist）
    public var crossCheckEnabled = true
    private var assist: BLEAssist?
    public var crossCheckResets: Int { assist?.resets ?? 0 }
    public var outsideSurveyed: Bool { assist?.outsideSurveyed ?? false }

    public init(field: MagneticFieldMap, walkable: WalkableMap?, useRawMag: Bool) {
        var cfg = MagneticConfig()
        cfg.initialHeadingBiasSigmaDeg = 30
        // 和实时定位页视觉里程计模式一致
        cfg.featureWeights = (0.5, 1.0, 0.25)
        cfg.jumpConfirmUpdates = 15
        cfg.convergedPositionNoiseFraction = 0.03
        localizer = MagneticLocalizer(field: field, walkable: walkable, config: cfg)
        localizer.reset(start: nil, headingUnknown: true)
        self.useRawMag = useRawMag
    }

    public func imu(_ s: IMUSample) {
        extractor.updateGravity(s)
        if useRawMag {
            if let r = lastRaw, abs(r.t - s.tMs) <= 30 { bias.add(tMs: s.tMs, raw: r.v, calibrated: (s.mx, s.my, s.mz)) }
            if !bias.isReady { latest = extractor.process(magnetic: (s.mx, s.my, s.mz), tMs: s.tMs) ?? latest }
        } else {
            latest = extractor.process(magnetic: (s.mx, s.my, s.mz), tMs: s.tMs) ?? latest
        }
    }

    public func rawMag(tMs: Int64, _ v: (Double, Double, Double)) {
        lastRaw = (tMs, v)
        if useRawMag, let m = bias.corrected(v) { latest = extractor.process(magnetic: m, tMs: tMs) ?? latest }
    }

    public func bleReading(tMs: Int64, id: String, rssi: Double) {
        guard bleMap != nil else { return }
        bleWindow.append((tMs, id, rssi))
        if bleWindow.count > 3000 { bleWindow.removeFirst(bleWindow.count - 3000) }
    }

    private func bleTick(_ t: Int64) {
        guard let m = bleMap, t - lastBle >= 1000 else { return }
        lastBle = t
        bleWindow.removeAll { $0.t < t - 2500 || $0.t > t }
        var acc: [String: (Double, Int)] = [:]
        for r in bleWindow { let a = acc[r.id] ?? (0, 0); acc[r.id] = (a.0 + r.rssi, a.1 + 1) }
        if assist == nil || assist!.map.tags.count != m.tags.count { assist = BLEAssist(map: m) }
        assist!.crossCheckEnabled = crossCheckEnabled
        assist!.tick(obs: acc.mapValues { $0.0 / Double($0.1) }, localizer: localizer,
                     current: localizer.isConverged ? estimate?.position : nil)
    }

    /// ARKit 位姿。送进滤波器时返回新的估计。`tMs` 给了才会用蓝牙。
    @discardableResult
    public func pose(a: Point2, normal: Bool, tMs: Int64? = nil) -> MagneticEstimate? {
        guard normal else { lastA = nil; return nil }
        defer { lastA = a }
        guard let l = lastA else { return nil }
        let d = a - l
        guard d.length < 300 else { return nil }          // ARKit 坐标系重置
        accum = accum + d
        guard accum.length >= stepCm else { return nil }
        let step = accum
        accum = .zero
        let prev = estimate
        if let t = tMs { bleTick(t) }
        let e = localizer.step(delta: step, feature: latest, trust: 1)
        estimate = e
        estimateA = a
        if e.converged {
            // 连续：这一步估计挪动的距离和实际走的差不多
            let moved = prev.map { e.position.distance(to: $0.position) } ?? 0
            if prev?.converged == true && moved < step.length + 60 { stableCm += step.length } else { stableCm = 0 }
            rotFit.add(ar: a, map: e.position)
        } else {
            stableCm = 0
            rotFit.reset()
        }
        return e
    }
}

/// 地磁定位精度统计：参考轨迹（采集时 ARKit + 贴通道）和地磁定位的位置比。
public final class LocalizationEvaluator {
    public private(set) var errors: [Double] = []
    public private(set) var firstFixPathCm: Double?
    public private(set) var jumps = 0
    public private(set) var pathCm = 0.0
    private var lastRef: Point2?
    private var lastEst: Point2?

    public init() {}

    /// 每次地磁定位出结果时调用。没收敛的不算误差（实时定位页也不显示）。
    public func add(estimate e: MagneticEstimate, reference r: Point2) {
        if let l = lastRef { pathCm += r.distance(to: l) }
        lastRef = r
        guard e.converged else { lastEst = nil; return }
        if firstFixPathCm == nil { firstFixPathCm = pathCm }
        if let le = lastEst, e.position.distance(to: le) > 200 { jumps += 1 }
        lastEst = e.position
        errors.append(e.position.distance(to: r))
    }

    public func percentile(_ q: Double) -> Double? {
        guard !errors.isEmpty else { return nil }
        let s = errors.sorted()
        return s[min(Int(Double(s.count - 1) * q + 0.5), s.count - 1)]
    }

    /// 误差 ≤ 1 m 的比例
    public var within1m: Double? { errors.isEmpty ? nil : Double(errors.filter { $0 <= 100 }.count) / Double(errors.count) }

    public var summary: String {
        guard let m = percentile(0.5), let p = percentile(0.9) else {
            return pathCm > 0 ? "走了 \(Int(pathCm / 100)) m，还没定位成功" : "还没有数据"
        }
        return "中位 \(Int(m)) cm · P90 \(Int(p)) cm · ≤1 m \(Int((within1m ?? 0) * 100))% · 跳 \(jumps) 次 · 首次定位走了 \(Int((firstFixPathCm ?? 0) / 100)) m"
    }
}
