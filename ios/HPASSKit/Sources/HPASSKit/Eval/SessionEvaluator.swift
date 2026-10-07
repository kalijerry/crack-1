import Foundation

/// 一次测试会话的定位精度。参考轨迹 = 这个会话自己的采集轨迹（ARKit + 贴通道），定位 = 冷启动地磁（+ 蓝牙），
/// 磁场图和蓝牙指纹只用「建图会话」生成，测试会话不参与（不是自己考自己）。
public struct EvalReport: Codable {
    public var session: String
    public var medianCm: Double?
    public var p90Cm: Double?
    public var within1m: Double?
    public var jumps: Int
    public var firstFixM: Double?
    public var pathM: Double
    public var points: Int
    public var usedBLE: Bool
    /// 有把握时误差超过 5 m 的比例（「定错了还很自信」，最伤人的情况）
    public var wrongFixShare: Double?
    /// 蓝牙交叉检验判错、重新找的次数
    public var crossCheckResets: Int = 0
    /// 只算参考位置在磁场图覆盖范围内（离有数据的格子 1.5 m 内）的点：去掉「走到建图没走过的地方」的影响
    public var inMapMedianCm: Double?
    public var inMapP90Cm: Double?
    public var inMapWithin1m: Double?
    /// 参考轨迹有多少比例在磁场图覆盖范围内
    public var inMapShare: Double?

    public var line: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
        return "\(session)\t中位 \(f(medianCm)) cm\tP90 \(f(p90Cm)) cm\t≤1m \(within1m.map { "\(Int($0 * 100))%" } ?? "—")"
            + "\t跳 \(jumps)\t首次定位 \(firstFixM.map { String(format: "%.1f m", $0) } ?? "没定到")\t走了 \(Int(pathM)) m"
            + "\t错定 \(wrongFixShare.map { "\(Int($0 * 100))%" } ?? "—")"
            + (usedBLE ? "\t+蓝牙（交叉检验重找 \(crossCheckResets) 次）" : "")
            + "\n    └ 只看建图覆盖到的地方（占 \(inMapShare.map { "\(Int($0 * 100))%" } ?? "—")）：中位 \(f(inMapMedianCm)) cm\tP90 \(f(inMapP90Cm)) cm\t≤1m \(inMapWithin1m.map { "\(Int($0 * 100))%" } ?? "—")"
    }
}

private func pct(_ a: [Double], _ q: Double) -> Double? {
    guard !a.isEmpty else { return nil }
    let s = a.sorted()
    return s[min(Int(Double(s.count - 1) * q + 0.5), s.count - 1)]
}

public enum SessionEvaluator {
    /// 用建图会话生成磁场图 + 蓝牙指纹（和手机上「生成磁场图」同一套）
    public static func buildMaps(sessions: [URL], map: StoreMap) throws -> (field: MagneticFieldMap, ble: BLEFingerprintMap?, reports: [SurveySessionReport]) {
        let b = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses)
        let bb = BLEFingerprintBuilder(widthCm: map.width, heightCm: map.height)
        var reps: [SurveySessionReport] = []
        for u in sessions {
            let s = try SurveySessionLoader.load(u)
            let r = b.add(s)
            _ = bb.add(samples: SurveySessionLoader.loadBLE(u), track: r.track)
            reps.append(r)
        }
        let ble = bb.build()
        return (b.build(), ble.tags.count >= 20 ? ble : nil, reps)
    }

    public static func walkable(_ map: StoreMap) -> WalkableMap? {
        if !map.crosses.isEmpty { return WalkableMap(crosses: map.crosses, widthCm: map.width, heightCm: map.height) }
        if !map.floor.isEmpty {
            return WalkableMap(floor: map.floor, obstacles: map.physicalShelves, widthCm: map.width, heightCm: map.height)
        }
        return nil
    }

    /// 回放一个测试会话：按时间顺序送 IMU、原始磁力计、蓝牙、ARKit 位姿，和参考轨迹比
    public static func evaluate(dir: URL, map: StoreMap, field: MagneticFieldMap, ble: BLEFingerprintMap?,
                                walkable: WalkableMap?, crossCheck: Bool = true,
                                configure: ((inout MagneticConfig) -> Void)? = nil, seed: UInt64 = 1) throws -> EvalReport {
        let s = try SurveySessionLoader.load(dir)
        // 参考轨迹：这个会话自己的对齐结果（只用它的锚点和贴通道，不用磁场）
        let refB = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses)
        let ref = refB.add(s).track
        func refAt(_ t: Int64) -> Point2? {
            var lo = 0, hi = ref.count - 1
            guard hi > 0, t >= ref[0].tMs, t <= ref[hi].tMs else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if ref[m].tMs <= t { lo = m } else { hi = m } }
            return ref[lo].tMs - t > 300 ? nil : ref[lo].p
        }
        let sh = ShadowLocalizer(field: field, walkable: walkable, useRawMag: !s.raw.isEmpty, configure: configure, seed: seed)
        sh.bleMap = ble
        sh.crossCheckEnabled = crossCheck
        let bleSamples = ble == nil ? [] : SurveySessionLoader.loadBLE(dir)
        enum Ev { case imu(IMUSample), raw(Int64, (Double, Double, Double)), ble(BLESample), pose(SurveySession.Pose) }
        var evs: [(Int64, Int, Ev)] = []
        evs.reserveCapacity(s.imu.count + s.raw.count + s.poses.count + bleSamples.count)
        for x in s.imu { evs.append((x.tMs, 0, .imu(x))) }
        for x in s.raw { evs.append((x.tMs, 1, .raw(x.tMs, x.v))) }
        for x in bleSamples { evs.append((x.tMs, 2, .ble(x))) }
        for x in s.poses { evs.append((x.tMs, 3, .pose(x))) }
        evs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let ev = LocalizationEvaluator()
        var inMapErr: [Double] = []
        var refTotal = 0, refInMap = 0
        for (_, _, e) in evs {
            switch e {
            case .imu(let x): sh.imu(x)
            case .raw(let t, let v): sh.rawMag(tMs: t, v)
            case .ble(let b): sh.bleReading(tMs: b.tMs, id: b.id, rssi: b.rssi)
            case .pose(let p):
                guard let est = sh.pose(a: p.a, normal: p.normal, tMs: p.tMs), let r = refAt(p.tMs) else { continue }
                ev.add(estimate: est, reference: r)
                let covered = field.sample(at: r) != nil
                refTotal += 1
                if covered { refInMap += 1 }
                if covered && est.converged { inMapErr.append(est.position.distance(to: r)) }
            }
        }
        return EvalReport(session: dir.lastPathComponent, medianCm: ev.percentile(0.5), p90Cm: ev.percentile(0.9),
                          within1m: ev.within1m, jumps: ev.jumps, firstFixM: ev.firstFixPathCm.map { $0 / 100 },
                          pathM: ev.pathCm / 100, points: ev.errors.count, usedBLE: ble != nil,
                          wrongFixShare: ev.errors.isEmpty ? nil : Double(ev.errors.filter { $0 > 500 }.count) / Double(ev.errors.count),
                          crossCheckResets: sh.crossCheckResets,
                          inMapMedianCm: pct(inMapErr, 0.5), inMapP90Cm: pct(inMapErr, 0.9),
                          inMapWithin1m: inMapErr.isEmpty ? nil : Double(inMapErr.filter { $0 <= 100 }.count) / Double(inMapErr.count),
                          inMapShare: refTotal > 0 ? Double(refInMap) / Double(refTotal) : nil)
    }
}
