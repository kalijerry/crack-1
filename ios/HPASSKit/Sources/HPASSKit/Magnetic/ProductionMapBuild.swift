import Foundation

/// 云端出图的整条磁场建图流水线（hpass-build 和评估 SessionEvaluator.buildMaps(.fusion) 共用同一份代码，
/// 评估量到的就是云端地图包里的那张图）：
///
/// 1. 第 1 遍融合：各会话原样对齐（起点 + 贴通道），解整体偏移；
/// 2. 有标签位置表或货架标签时，TagTrajectoryCorrector 把每条轨迹拉向标签锚点；
/// 3. 第 2 遍融合（带修正），SessionQualityGate 按 10 秒一段用标签 / 磁场（和别的会话比）检查，
///    不合格的段丢掉，整体不可信或太短的会话整个不用；
/// 4. 第 3 遍融合：只用合格的会话和合格的段；
/// 5. 分成多个连通分量时（有的会话和主体重叠不够，整体偏移对不齐），磁场图只用主体（分量 0）重新融合，
///    其余会话不进磁场图（它们的蓝牙读数照用）。云端出图一定做这一步；评估可以用 mainComponentOnly = false
///    保留所有分量（各分量各自对齐，分量之间不对齐），这时 offMain 里列出云端会排除的会话。
extension MultiSessionFusion {
    public struct ProductionBuild {
        /// 磁场图用的融合结果（只有主体分量的会话；只有一个分量时就是 all）
        public var magnetic: Result
        /// 第 3 遍融合结果：所有合格会话（含和主体连不上的），轨迹给蓝牙指纹、地图朝向用
        public var all: Result
        /// 合格会话在输入里的下标（和 all.tracks / keptBLE 一一对应）
        public var keptIndices: [Int]
        /// 合格会话的蓝牙读数（已按质量筛选去掉不合格的段）
        public var keptBLE: [[BLESample]]
        /// 质量合格但和主体连不上、磁场图没用的会话（mainComponentOnly = false 时为空）
        public var magExcluded: [String]
        /// 质量合格但不在主体分量里的会话（不管 mainComponentOnly，云端出图会把它们排除在磁场图外）
        public var offMain: [String]
        public var quality: [SessionQualityGate.Report]
        public var corrections: [String: TagTrajectoryCorrector.Stats]
        /// 第 3 遍融合的连通分量数
        public var components: Int { all.components }
        /// 质量筛选用的门（地图自愈并入实时记录时用同一套标准）
        public var gate: SessionQualityGate
        /// 用上的货架标签观测次数
        public var signObservations: Int
    }

    /// 云端出图流水线（见类型说明）。没有合格会话时返回 nil（云端不出图）。
    /// - ble / signs: 和 sessions 一一对应（缺的当空）
    /// - tagPositions: 标签位置表（标签 id → 地图位置）；空 = 没有表
    /// - mainComponentOnly: 磁场图只用主体分量（云端出图 = true）
    public func buildProduction(_ sessions: [SurveySession], ble: [[BLESample]], signs: [[SignSample]] = [],
                                tagPositions: [String: Point2] = [:], mainComponentOnly: Bool = true) -> ProductionBuild? {
        let n = sessions.count
        func bleOf(_ k: Int) -> [BLESample] { k < ble.count ? ble[k] : [] }
        // 第 1 遍：各会话原样对齐
        let r1 = fuse(sessions)
        // 货架标签：每条换成「人应该在那段货架前」的区域
        let shelfSigns = ShelfSigns(map: map, walkable: SessionEvaluator.walkable(map))
        let signObs: [[TagTrajectoryCorrector.SignObservation]] = (0..<n).map { k in
            (k < signs.count ? signs[k] : []).compactMap { x in
                shelfSigns.sign(for: x.text).map { sg in .init(tMs: x.tMs, region: { shelfSigns.nearestValid(sg, to: $0) }) }
            }
        }
        let signDist: [[(tMs: Int64, distanceTo: (Point2) -> Double)]] = (0..<n).map { k in
            (k < signs.count ? signs[k] : []).compactMap { x in
                shelfSigns.sign(for: x.text).map { sg in (x.tMs, { shelfSigns.distance(sg, from: $0) }) }
            }
        }
        let nSigns = signObs.reduce(0) { $0 + $1.count }
        // 标签锚定修正
        var corrections: [((Int64) -> Point2)?] = Array(repeating: nil, count: n)
        var corrStats: [String: TagTrajectoryCorrector.Stats] = [:]
        if (!tagPositions.isEmpty || nSigns > 0) && !map.crosses.isEmpty {
            let corr = TagTrajectoryCorrector(tagPositions: tagPositions)
            for (k, s) in sessions.enumerated() {
                guard let (fn, st) = corr.solve(track: r1.tracks[k], ble: bleOf(k), signs: signObs[k]) else { continue }
                corrections[k] = fn
                corrStats[s.name] = st
            }
        }
        // 第 2 遍：带修正对齐，做质量检查
        let r2 = fuse(sessions, corrections: corrections)
        let gate = SessionQualityGate(tagPositions: tagPositions)
        if map.crosses.isEmpty { gate.minPathCm = 500; gate.minGoodSamples = 150 }   // 房间小，走几米就够
        var quality: [SessionQualityGate.Report] = []
        var filters: [((Int64) -> Bool)?] = []
        var keepIdx: [Int] = []
        for (k, s) in sessions.enumerated() {
            let others = MagneticFieldBuilder(widthCm: map.width, heightCm: map.height, cellCm: cellCm)
            var any = false
            for (j, ss) in r2.samples.enumerated() where j != k { for x in ss { _ = others.add(position: x.p, feature: x.f); any = true } }
            let v = gate.evaluate(name: s.name, track: r2.tracks[k], ble: bleOf(k), mag: r2.samples[k],
                                  others: any ? others.snapshot() : nil, othersBuilder: any ? others : nil,
                                  signs: signDist[k])
            quality.append(v.report)
            if let keep = v.keep { filters.append(keep); keepIdx.append(k) }
        }
        guard !keepIdx.isEmpty else { return nil }
        // 第 3 遍：只用合格的会话和合格的段
        let kept = keepIdx.map { sessions[$0] }
        let keptCorr = keepIdx.map { corrections[$0] }
        let keptBLE = keepIdx.enumerated().map { j, k in bleOf(k).filter { filters[j]!($0.tMs) } }
        let r = fuse(kept, filters: filters, corrections: keptCorr)
        // 和主体连不上的会话：整体偏移对不齐（可能差 10～16 µT），磁场图只用主体（分量 0）
        var rm = r
        let offMain = r.sessions.filter { $0.component != 0 }.map(\.name)
        var excluded: [String] = []
        if r.components > 1 && mainComponentOnly {
            let main = r.sessions.indices.filter { r.sessions[$0].component == 0 }
            excluded = offMain
            rm = fuse(main.map { kept[$0] }, filters: main.map { filters[$0] }, corrections: main.map { keptCorr[$0] })
        }
        return ProductionBuild(magnetic: rm, all: r, keptIndices: keepIdx, keptBLE: keptBLE, magExcluded: excluded, offMain: offMain,
                               quality: quality, corrections: corrStats, gate: gate, signObservations: nSigns)
    }
}
