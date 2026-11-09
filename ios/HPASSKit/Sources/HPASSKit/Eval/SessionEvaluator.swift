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
    /// 每个已定位点的误差（cm），汇总多个会话时用
    public var errorsCm: [Double] = []
    /// 参考轨迹上的点数（含没定到位的），算「定位覆盖率」
    public var refPoints: Int = 0

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
    /// 建图方式
    public enum MapBuild {
        /// 和云端出图（hpass-build）完全一样：MultiSessionFusion.buildProduction —— 三遍融合（全局解偏移，和会话顺序无关）、
        /// 有标签位置表 / 货架标签时的轨迹锚定修正、质量筛选（不合格的段 / 会话不用）、磁场图只用主体连通分量
        case production
        /// 同一条流水线（同一份代码）的融合核心：全局解偏移 + 有标签时的轨迹锚定修正，**不做**质量筛选、
        /// **不排除**和主体连不上的分量（各分量各自对齐，分量之间不对齐）。评估默认用这个。
        /// 原因（公开数据集实测，夜间 Lab）：建图轨迹不是按「分片之间要有重叠」采的，101 条分成 23～33 个连通分量，
        /// 只用主体会从图里去掉约 36% 的格子；质量筛选拿「别的会话」比磁场，而别的会话分在互相没对齐的分量里，
        /// 101 条里 36 条整条被判不合格。两者量到的都是采集方式，而不是定位。
        /// 云端会排除哪些会话见 BuiltMaps.offMain（hpass-eval 打印）；要量云端地图包本身用 .production
        case fusion
        /// 手机上「生成磁场图」那套：会话按顺序一个个加，每个只和已经加进去的数据对齐偏移（结果和顺序有关）
        case sequential
    }

    public struct BuiltMaps {
        public var field: MagneticFieldMap
        public var ble: BLEFingerprintMap?
        /// Wi-Fi 指纹（只有 buildMaps 传 withWiFi 才建；会话里没有 wifi.csv 时为 nil）
        public var wifi: WiFiFingerprintMap?
        /// 进了磁场图的会话的建图说明（production：只有主体分量里合格的会话）
        public var reports: [SurveySessionReport]
        /// 合格会话分成几个连通分量（sequential 恒为 1）
        public var components: Int = 1
        /// 质量筛选没通过、不用的会话（名字 + 原因；只有 production 做质量筛选）
        public var rejected: [(name: String, reason: String)] = []
        /// 质量合格但和主体连不上、磁场图没用的会话（只有 .production 会排除）
        public var magExcluded: [String] = []
        /// 质量合格但不在主体分量里的会话（云端出图会排除的）
        public var offMain: [String] = []
    }

    public enum BuildError: Error { case noUsableSession }

    /// 用建图会话生成磁场图 + 蓝牙指纹。默认和云端出图同一份流水线（见 MapBuild.production / .fusion 的区别），蓝牙指纹用合格会话
    /// （含和主体连不上的）对齐后的轨迹和筛过的读数，和 hpass-build 一样。
    /// - tagPositions: 标签位置表（hpass-build --tag-locations 同一份）；空 = 没有表
    /// - withWiFi: 同时用各会话的 wifi.csv 建 Wi-Fi 指纹（位置取和蓝牙指纹同一条对齐好的轨迹）
    public static func buildMaps(sessions: [URL], map: StoreMap, mode: MapBuild = .fusion,
                                 tagPositions: [String: Point2] = [:], withWiFi: Bool = false) throws -> BuiltMaps {
        let bb = BLEFingerprintBuilder(widthCm: map.width, heightCm: map.height)
        let wb = WiFiFingerprintBuilder()
        func wifiMap() -> WiFiFingerprintMap? { withWiFi && wb.count > 0 ? wb.build() : nil }
        switch mode {
        case .sequential:
            let b = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses)
            var reps: [SurveySessionReport] = []
            for u in sessions {
                let s = try SurveySessionLoader.load(u)
                let r = b.add(s)
                _ = bb.add(samples: SurveySessionLoader.loadBLE(u), track: r.track)
                if withWiFi { wb.add(scans: WiFiScan.group(SurveySessionLoader.loadWiFi(u)), track: r.track) }
                reps.append(r)
            }
            let ble = bb.build()
            return BuiltMaps(field: b.build(), ble: ble.tags.count >= 20 ? ble : nil, wifi: wifiMap(), reports: reps)
        case .production, .fusion:
            var loaded: [SurveySession] = [], bles: [[BLESample]] = [], signs: [[SignSample]] = []
            for u in sessions {
                loaded.append(try SurveySessionLoader.load(u))
                bles.append(SurveySessionLoader.loadBLE(u))
                signs.append(SignSample.load(u))
            }
            guard let pb = MultiSessionFusion(map: map).buildProduction(loaded, ble: bles, signs: signs, tagPositions: tagPositions,
                                                                     options: mode == .production ? MultiSessionFusion.ProductionOptions.cloud
                                                                         : MultiSessionFusion.ProductionOptions(qualityGate: false, mainComponentOnly: false)) else {
                throw BuildError.noUsableSession
            }
            for (k, track) in pb.all.tracks.enumerated() where k < pb.keptBLE.count { _ = bb.add(samples: pb.keptBLE[k], track: track) }
            if withWiFi {
                for (k, track) in pb.all.tracks.enumerated() where k < pb.keptIndices.count {
                    wb.add(scans: WiFiScan.group(SurveySessionLoader.loadWiFi(sessions[pb.keptIndices[k]])), track: track)
                }
            }
            let ble = bb.build()
            return BuiltMaps(field: pb.magnetic.field, ble: ble.tags.count >= 20 ? ble : nil, wifi: wifiMap(), reports: pb.magnetic.reports,
                             components: pb.components,
                             rejected: pb.quality.filter { !$0.kept }.map { ($0.name, $0.reason ?? "") },
                             magExcluded: pb.magExcluded, offMain: pb.offMain)
        }
    }

    /// - Parameter rooms: 地图有单元（房间 / 走廊）时用房间约束版（墙挡住、门打通、带房间编号，见 `RoomGraph`）
    public static func walkable(_ map: StoreMap, rooms: Bool = false) -> WalkableMap? {
        if rooms, map.crosses.isEmpty, let w = WalkableMap(roomsOf: map) { return w }
        if !map.crosses.isEmpty { return WalkableMap(crosses: map.crosses, widthCm: map.width, heightCm: map.height) }
        if !map.floor.isEmpty {
            return WalkableMap(floor: map.floor, obstacles: map.physicalShelves, widthCm: map.width, heightCm: map.height)
        }
        return nil
    }

    /// 读 truth.csv（t_ms,x_cm,y_cm）。没有返回 nil
    static func loadTruth(_ dir: URL) -> [(tMs: Int64, p: Point2)]? {
        guard let text = try? String(contentsOf: dir.appendingPathComponent("truth.csv"), encoding: .utf8) else { return nil }
        let out = text.split(separator: "\n").dropFirst().compactMap { l -> (tMs: Int64, p: Point2)? in
            let r = l.split(separator: ",")
            guard r.count >= 3, let t = Int64(r[0]), let x = Double(r[1]), let y = Double(r[2]) else { return nil }
            return (t, Point2(x, y))
        }
        return out.count > 1 ? out.sorted { $0.tMs < $1.tMs } : nil
    }

    /// 回放一个测试会话：按时间顺序送 IMU、原始磁力计、蓝牙、ARKit 位姿，和参考轨迹比
    /// 已知起点（`oracleStart`）跟踪用的配置：产品的跟踪配置档 + 命令行覆盖。冷启动收敛门只属于冷启动，
    /// 这里总是关掉（就算命令行的覆盖打开了它）。
    public static func oracleTrackingConfig(odometry: OdometrySource,
                                            configure: ((inout MagneticConfig) -> Void)? = nil) -> MagneticConfig {
        var cfg = MagneticConfig.tracking(odometry: odometry, headingKnown: true)
        configure?(&cfg)
        cfg.clearColdStartGate()
        return cfg
    }

    public static func evaluate(dir: URL, map: StoreMap, field: MagneticFieldMap, ble: BLEFingerprintMap?,
                                walkable: WalkableMap?, crossCheck: Bool = true,
                                configure: ((inout MagneticConfig) -> Void)? = nil, seed: UInt64 = 1,
                                refTagPositions: [String: Point2]? = nil, oracleStart: Bool = false,
                                odometry: OdometrySource = .pdr, coldStartGate: Bool = false,
                                wifi: WiFiFingerprintMap? = nil) throws -> EvalReport {
        let s = try SurveySessionLoader.load(dir)
        // 参考轨迹：这个会话自己的对齐结果（只用它的锚点和贴通道，不用磁场）；给了标签位置时再用标签锚定修正一遍
        // （采集轨迹中途偏航时，不修正的参考本身就是错的）
        let refB = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses)
        // 公开数据集基准：会话里有 truth.csv（t_ms,x_cm,y_cm）就直接当参考轨迹（位姿是合成的，不能再对齐）
        let truth = Self.loadTruth(dir)
        var ref = truth ?? refB.add(s).track
        if truth == nil, let tp = refTagPositions, !map.crosses.isEmpty,
           let (fn, _) = TagTrajectoryCorrector(tagPositions: tp).solve(track: ref, ble: SurveySessionLoader.loadBLE(dir)) {
            let b2 = SurveyMapBuilder(widthCm: map.width, heightCm: map.height, crosses: map.crosses)
            b2.correction = fn
            ref = b2.prepare(s).0.track
        }
        func refAt(_ t: Int64) -> Point2? {
            var lo = 0, hi = ref.count - 1
            guard hi > 0, t >= ref[0].tMs, t <= ref[hi].tMs else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if ref[m].tMs <= t { lo = m } else { hi = m } }
            return t - ref[lo].tMs > 300 ? nil : ref[lo].p  // 参考点比查询时刻旧 300 ms 以上就不算
        }
        let sh = ShadowLocalizer(field: field, walkable: walkable, useRawMag: !s.raw.isEmpty, configure: configure, seed: seed,
                                coldStartGate: coldStartGate)
        sh.bleMap = ble
        sh.crossCheckEnabled = crossCheck
        // 已知起点 + 已知朝向的「跟踪」模式（基准用，不含冷启动）：
        // 用参考轨迹前 8 m 把位姿坐标系转到地图坐标系，粒子从真实起点出发。
        // 配置用和实时定位页同一份跟踪配置档（MagneticConfig.tracking，按运动来源），起点撒开也一样
        // （TrackingProfile.startSpreadCm），量到的就是产品的跟踪行为；命令行的 configure 照样最后套上
        var poseRot = (c: 1.0, s: 0.0)
        if oracleStart, let r0 = ref.first, let pi0 = s.poses.firstIndex(where: { $0.tMs >= r0.tMs }) {
            let a0 = s.poses[pi0].a
            if let pj = s.poses[pi0...].firstIndex(where: { $0.a.distance(to: a0) >= 800 }),
               let rj = ref.first(where: { $0.tMs >= s.poses[pj].tMs }) {
                let da = s.poses[pj].a - a0, dm = rj.p - r0.p
                let phi = atan2(dm.y, dm.x) - atan2(da.y, da.x)
                poseRot = (cos(phi), sin(phi))
                sh.localizer.config = oracleTrackingConfig(odometry: odometry, configure: configure)
                sh.localizer.reset(start: r0.p, spreadCm: TrackingProfile.startSpreadCm, headingUnknown: false)
            }
        }
        // Wi-Fi 冷启动（--wifi，只有 Android 能扫）：和已知起点不同时用
        var wifiScans: [WiFiScan] = []
        if let w = wifi, !oracleStart {
            sh.enableWiFi(w, odometry: odometry, configure: configure)
            wifiScans = WiFiScan.group(SurveySessionLoader.loadWiFi(dir))
        }
        let bleSamples = ble == nil ? [] : SurveySessionLoader.loadBLE(dir)
        enum Ev { case imu(IMUSample), raw(Int64, (Double, Double, Double)), ble(BLESample), wifi(WiFiScan), pose(SurveySession.Pose) }
        var evs: [(Int64, Int, Ev)] = []
        evs.reserveCapacity(s.imu.count + s.raw.count + s.poses.count + bleSamples.count + wifiScans.count)
        for x in s.imu { evs.append((x.tMs, 0, .imu(x))) }
        for x in s.raw { evs.append((x.tMs, 1, .raw(x.tMs, x.v))) }
        for x in bleSamples { evs.append((x.tMs, 2, .ble(x))) }
        for x in wifiScans { evs.append((x.tMs, 2, .wifi(x))) }
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
            case .wifi(let w): sh.wifiScan(w)
            case .pose(let p):
                let pa = Point2(p.a.x * poseRot.c - p.a.y * poseRot.s, p.a.x * poseRot.s + p.a.y * poseRot.c)
                guard let est = sh.pose(a: pa, normal: p.normal, tMs: p.tMs), let r = refAt(p.tMs) else { continue }
                ev.add(estimate: est, reference: r)
                let covered = field.sample(at: r) != nil
                refTotal += 1
                if covered { refInMap += 1 }
                if covered && est.converged { inMapErr.append(est.position.distance(to: r)) }
            }
        }
        var rep = EvalReport(session: dir.lastPathComponent, medianCm: ev.percentile(0.5), p90Cm: ev.percentile(0.9),
                          within1m: ev.within1m, jumps: ev.jumps, firstFixM: ev.firstFixPathCm.map { $0 / 100 },
                          pathM: ev.pathCm / 100, points: ev.errors.count, usedBLE: ble != nil,
                          wrongFixShare: ev.errors.isEmpty ? nil : Double(ev.errors.filter { $0 > 500 }.count) / Double(ev.errors.count),
                          crossCheckResets: sh.crossCheckResets,
                          inMapMedianCm: pct(inMapErr, 0.5), inMapP90Cm: pct(inMapErr, 0.9),
                          inMapWithin1m: inMapErr.isEmpty ? nil : Double(inMapErr.filter { $0 <= 100 }.count) / Double(inMapErr.count),
                          inMapShare: refTotal > 0 ? Double(refInMap) / Double(refTotal) : nil)
        rep.errorsCm = ev.errors
        rep.refPoints = refTotal
        return rep
    }

    /// 诊断：测试会话里每走 `everyCm` 取一次实测特征（和定位用的同一条流水线），和地图在参考位置的值比。
    /// 用来按「实际残差」标定跟踪档的观测噪声（见 MagneticConfig.trackingLikelihood）。只用有 truth.csv 的会话。
    public struct ResidualSample {
        public var tMs: Int64
        public var pathCm: Double
        public var feature: MagneticFeature
        /// 地图在参考位置的均值 / 标准差；nil = 那里没数据
        public var mean: MagneticFeature?
        public var sigma: MagneticFeature?
    }

    public static func residualSamples(dir: URL, field: MagneticFieldMap, everyCm: Double = 50) throws -> [ResidualSample] {
        let s = try SurveySessionLoader.load(dir)
        guard let ref = Self.loadTruth(dir) else { return [] }
        func refAt(_ t: Int64) -> Point2? {
            var lo = 0, hi = ref.count - 1
            guard hi > 0, t >= ref[0].tMs, t <= ref[hi].tMs else { return nil }
            while hi - lo > 1 { let m = (lo + hi) / 2; if ref[m].tMs <= t { lo = m } else { hi = m } }
            return t - ref[lo].tMs > 300 ? nil : ref[lo].p
        }
        let sh = ShadowLocalizer(field: field, walkable: nil, useRawMag: !s.raw.isEmpty)
        enum Ev { case imu(IMUSample), raw(Int64, (Double, Double, Double)), pose(SurveySession.Pose) }
        var evs: [(Int64, Int, Ev)] = []
        for x in s.imu { evs.append((x.tMs, 0, .imu(x))) }
        for x in s.raw { evs.append((x.tMs, 1, .raw(x.tMs, x.v))) }
        for x in s.poses { evs.append((x.tMs, 3, .pose(x))) }
        evs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var out: [ResidualSample] = []
        var lastA: Point2?, path = 0.0, nextAt = everyCm
        for (_, _, e) in evs {
            switch e {
            case .imu(let x): sh.imu(x)
            case .raw(let t, let v): sh.rawMag(tMs: t, v)
            case .pose(let p):
                guard p.normal else { lastA = nil; continue }
                if let l = lastA, p.a.distance(to: l) < 300 { path += p.a.distance(to: l) }
                lastA = p.a
                guard path >= nextAt else { continue }
                nextAt = path + everyCm
                guard let f = sh.latestFeature, let r = refAt(p.tMs) else { continue }
                let m = field.sample(at: r)
                out.append(ResidualSample(tMs: p.tMs, pathCm: path, feature: f, mean: m?.mean, sigma: m?.sigma))
            }
        }
        return out
    }
}
