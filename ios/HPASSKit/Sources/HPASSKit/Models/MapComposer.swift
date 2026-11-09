import Foundation

/// 多段扫描合成一张地图（确定性：同样的注册表和段数据，产出同样的 map.json）。
///
/// 规则：
/// 1. 按时间顺序处理启用的段；每段的元素用 `toMap` 变换到地图坐标（墙门窗按中心 + 旋转、家具先转中心再换回左上角、
///    多边形逐点）。
/// 2. `replace` 段先删掉自己足迹（本段单元外扩 30 cm）里的旧东西：墙按足迹裁掉里面那截，门窗 / 家具 / 其他元素按中心，
///    单元按质心；被替换的单元编号、类别、名字由新单元继承。足迹外的旧墙，凡是和本段某面新墙平行（≤ 5°）、
///    垂直距离 ≤ 60 cm 的，新墙沿线范围（两头各加 30 cm）里那截也裁掉（旧墙偏得多正是重扫的原因，不能留下两道平行墙）。
///    新墙和剩下的旧墙接上时以新墙为准（旧墙两端都离新墙的线 ≤ 25 cm 才接，接成新墙的线；否则各留各的）。
/// 3. 去重（只和更早的段比，同一段内部不动）：墙 = 平行 ≤ 5°、垂直距离 ≤ 25 cm、沿线区间重叠或间隙 ≤ 20 cm → 取区间并集；
///    门窗开口 = 同类、中心距 ≤ 40 cm、夹角 ≤ 20°；家具 = 同类、中心距 ≤ 40 cm、宽深各在 ±30% 内。
/// 4. 单元：同一房间（质心互含 + 面积比 0.5～2）继承编号；`append` 保留旧多边形，`replace` 用新的；
///    `append` 时没匹配上、但 ≥ 60% 面积落在已有单元里的新单元当作「站在旧房间里又扫了半个」丢掉（墙仍参与去重）。
///    全局编号在段第一次合成时分配并记进 `unitIds`，之后稳定；用户的类别 / 名字（`unitLabels`）最后套回去。
/// 5. 家具编号 `Room-类别-n` 按位置排序后全局重编；画布只增不减；内容伸到留白以外（x 或 y 小于 100 cm）时
///    整体平移 50 cm 的整数倍（`MapFrameShift`），所有段的 toMap、arAlign、累计偏移一起改。
/// 6. 根字段沿用第一段的（楼层名、来源、楼层序号、场馆），geoRef / geoAnchor 取第一个带它的段并换算到地图坐标，
///    arAlign = 注册表里基准 AR 坐标系 → 地图；最后 `RoomMapBuilder.applyUnits` 派生可走区域、连接体和标签。
public enum MapComposer {
    public struct Thresholds {
        public var wallAngleDeg = 5.0
        public var wallOffsetCm = 25.0
        public var wallGapCm = 20.0
        public var openingDistCm = 40.0
        public var openingAngleDeg = 20.0
        public var furnitureDistCm = 40.0
        public var furnitureSizeTol = 0.3
        public var unitMaxAreaRatio = 2.0
        /// replace：足迹外扩
        public var replaceMarginCm = 30.0
        /// append：没匹配上的新单元有这么多面积落在旧单元里就丢掉
        public var ghostUnitShare = 0.6
        /// replace：足迹外和新墙平行、离新墙这么近的旧墙，新墙沿线范围里那截算同一道墙的旧测量，裁掉
        public var replaceParallelCm = 60.0
        /// 墙被裁掉后剩下的小于这个长度就不要了
        public var minWallCm = 20.0
        /// 一致性检查：采样点离已有墙这么近才算重合
        public var consistencyMatchCm = 30.0
        public var consistencyAngleDeg = 10.0
        public var sampleStepCm = 20.0
        /// 合成结果的单元有这么多面积已经在旧图里 → 建议「替换这块」
        public var replaceSuggestShare = 0.6
        public var marginCm = RoomMapBuilder.marginCm
        public init() {}
    }

    public enum ComposeError: Error, CustomStringConvertible {
        case missingScan(String)
        public var description: String {
            switch self { case .missingScan(let id): return "扫描段 \(id) 的地图数据不见了" }
        }
    }

    public struct Result {
        public var json: Data
        /// 更新过的注册表（单元编号、被替换的单元、画布、原点平移）
        public var registry: ScanRegistry
        /// 这次合成发生了原点平移（地图坐标整体 + 这个量）；App 据此平移旁注、清掉本机按格子存的定位数据
        public var originShift: Point2?
    }

    enum Kind { case wall, opening, furniture, other }

    struct Item {
        var kind: Kind
        var raw: [String: Any]
        var order: Int
        var seg: MapGeometry.Segment?
        var rect: MapGeometry.RectItem?
    }

    struct UnitW {
        var id: String
        var category: String
        var name: String?
        var poly: [Point2]
    }

    // MARK: 合成

    public static func compose(registry reg0: ScanRegistry, scans: [String: Data],
                               thresholds th: Thresholds = Thresholds()) throws -> Result {
        var reg = reg0
        let ordered = reg.ordered
        var roots: [String: [String: Any]] = [:]
        for s in ordered {
            if let d = scans[s.id] { roots[s.id] = try MapGeometry.root(d) } else if s.enabled { throw ComposeError.missingScan(s.id) }
        }
        var items: [Item] = []
        var units: [UnitW] = []
        var used = reg.reservedUnitIds

        for (k, rec) in ordered.enumerated() where rec.enabled {
            guard let root = roots[rec.id], let ri = reg.scans.firstIndex(where: { $0.id == rec.id }) else { continue }
            let t = rec.transform

            // 1. 单元：分配全局编号
            let priorEmpty = units.isEmpty
            var ids = rec.unitIds
            var thisScan: [UnitW] = []
            var taken = Set<String>()
            for u in MapGeometry.units(root) {
                let poly = u.polygon.map(t.toMap)
                var gid = ids[u.id]
                if gid == nil {
                    let c = MapGeometry.centroid(poly)
                    let match = units.filter { !taken.contains($0.id) && MapGeometry.sameRoom($0.poly, poly, maxAreaRatio: th.unitMaxAreaRatio) }
                        .min { MapGeometry.centroid($0.poly).distance(to: c) < MapGeometry.centroid($1.poly).distance(to: c) }
                    if let m = match { gid = m.id } else if priorEmpty && !used.contains(u.id) { gid = u.id } else { gid = ScanRegistry.nextUnitId(used: used) }
                }
                if taken.contains(gid!) { gid = ScanRegistry.nextUnitId(used: used.union(taken)) }
                ids[u.id] = gid!
                used.insert(gid!); taken.insert(gid!)
                // 同一个房间：类别、名字继承旧的
                var nu = UnitW(id: gid!, category: u.category, name: u.name, poly: poly)
                if let old = units.first(where: { $0.id == gid! }) { nu.category = old.category; nu.name = old.name ?? u.name }
                thisScan.append(nu)
            }
            reg.scans[ri].unitIds = ids

            // 2. 本段的元素（派生的标签 / 连接体不要，最后重新生成）
            let elements = (root["mapElementList"] as? [[String: Any]] ?? [])
                .filter { !MapGeometry.derivedTypes.contains($0["shapeType"] as? String ?? "") }
                .map { MapGeometry.transform(element: $0, by: t) }

            // 3. 替换：删掉足迹里的旧东西
            if rec.mode == .replace {
                var fp = thisScan.map(\.poly)
                if fp.isEmpty {
                    let hull = RoomMapBuilder.convexHull(elements.compactMap(MapGeometry.segment).flatMap { [$0.a, $0.b] })
                    if hull.count >= 3 { fp = [hull] }
                }
                func inFP(_ p: Point2) -> Bool { fp.contains { MapGeometry.isWithin($0, p, marginCm: th.replaceMarginCm) } }
                let newIds = Set(thisScan.map(\.id))
                var removed: [String] = []
                units.removeAll { u in
                    let hit = newIds.contains(u.id) || inFP(MapGeometry.centroid(u.poly))
                    if hit { removed.append(u.id) }
                    return hit
                }
                reg.scans[ri].replaces = removed.isEmpty ? nil : removed.sorted()
                var kept: [Item] = []
                for it in items {
                    if it.kind == .wall, let s = it.seg {
                        for piece in clip(s, inside: inFP, step: 5, minLen: th.minWallCm) {
                            var n = it
                            n.seg = piece
                            n.raw = piece == s ? it.raw : MapGeometry.element(piece, template: it.raw)
                            kept.append(n)
                        }
                    } else if let c = MapGeometry.center(it.raw), inFP(c) {
                        continue
                    } else {
                        kept.append(it)
                    }
                }
                items = kept
                // 足迹外的旧墙：和新墙平行又离得近的那截是同一道墙的旧测量（走廊墙、几个房间共用一长段的墙），裁掉
                let newWalls = elements.compactMap(MapGeometry.segment).filter { $0.type == "MapWall" }
                if !newWalls.isEmpty {
                    var out: [Item] = []
                    for it in items {
                        guard it.kind == .wall, it.order < k, let s = it.seg else { out.append(it); continue }
                        let near = newWalls.filter { MapGeometry.lineAngleDiffDeg($0.rotationDeg, s.rotationDeg) <= th.wallAngleDeg }
                        if near.isEmpty { out.append(it); continue }
                        func covered(_ p: Point2) -> Bool {
                            near.contains { n in
                                let u = n.param(of: p)
                                return u >= -th.replaceMarginCm && u <= n.length + th.replaceMarginCm
                                    && abs(n.offset(of: p)) <= th.replaceParallelCm
                            }
                        }
                        for piece in clip(s, inside: covered, step: 5, minLen: th.minWallCm) {
                            var n = it
                            n.seg = piece
                            n.raw = piece == s ? it.raw : MapGeometry.element(piece, template: it.raw)
                            out.append(n)
                        }
                    }
                    items = out
                }
            }

            // 4. 单元并入
            let prior = units
            for u in thisScan {
                if units.contains(where: { $0.id == u.id }) { continue }          // append：同一房间保留旧的
                if rec.mode == .append, !prior.isEmpty,
                   MapGeometry.shareInside(u.poly, prior.map(\.poly)) >= th.ghostUnitShare { continue }
                units.append(u)
            }

            // 5. 元素并入（去重只和更早的段比）
            for e in elements {
                if let s = MapGeometry.segment(e) {
                    if s.type == "MapWall" {
                        // 替换时旧墙在足迹边上被裁出一道缺口（外扩量），新墙要能跨过它接上
                        let gap = th.wallGapCm + (rec.mode == .replace ? th.replaceMarginCm : 0)
                        mergeWall(s, raw: e, order: k, into: &items, th, maxGap: gap, newerWins: rec.mode == .replace)
                    } else {
                        let dup = items.contains { it in
                            guard it.order < k, let o = it.seg, o.type == s.type else { return false }
                            return o.center.distance(to: s.center) <= th.openingDistCm
                                && MapGeometry.lineAngleDiffDeg(o.rotationDeg, s.rotationDeg) <= th.openingAngleDeg
                        }
                        if !dup { items.append(Item(kind: .opening, raw: e, order: k, seg: s, rect: nil)) }
                    }
                } else if MapGeometry.furnitureCategory(e) != nil, let r = MapGeometry.rect(e) {
                    let dup = items.contains { it in
                        guard it.order < k, it.kind == .furniture, let o = it.rect, o.category == r.category,
                              o.center.distance(to: r.center) <= th.furnitureDistCm else { return false }
                        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= th.furnitureSizeTol * max(a, b, 1) }
                        return (near(o.width, r.width) && near(o.height, r.height)) || (near(o.width, r.height) && near(o.height, r.width))
                    }
                    if !dup { items.append(Item(kind: .furniture, raw: e, order: k, seg: nil, rect: r)) }
                } else {
                    items.append(Item(kind: .other, raw: e, order: k, seg: nil, rect: nil))
                }
            }
        }

        // 6. 用户的类别 / 名字
        for i in units.indices {
            guard let l = reg.unitLabels[units[i].id] else { continue }
            if let c = l.category, !c.isEmpty { units[i].category = c }
            if let n = l.name { units[i].name = n.isEmpty ? nil : n }
        }

        // 7. 家具编号全局重编（按类别、位置）
        renumberFurniture(&items)

        // 8. 范围、原点平移、画布
        var pts = items.flatMap { MapGeometry.extentPoints($0.raw) } + units.flatMap(\.poly)
        var shiftOut: Point2?
        if let minX = pts.map(\.x).min(), let minY = pts.map(\.y).min() {
            let s = MapFrameShift.requiredShift(minX: minX, minY: minY, marginCm: th.marginCm)
            if s != .zero {
                let t = MapARTransform(pRef: s, aRef: .zero, phi: 0)
                for i in items.indices {
                    items[i].raw = MapGeometry.transform(element: items[i].raw, by: t)
                    items[i].seg = items[i].seg?.transformed(by: t)
                }
                for i in units.indices { units[i].poly = units[i].poly.map { $0 + s } }
                reg = reg.shifted(by: s)
                pts = pts.map { $0 + s }
                shiftOut = s
            }
        }
        let maxX = pts.map(\.x).max() ?? 0, maxY = pts.map(\.y).max() ?? 0
        let oldW = (reg.canvasCm?.count ?? 0) >= 2 ? reg.canvasCm![0] : 0
        let oldH = (reg.canvasCm?.count ?? 0) >= 2 ? reg.canvasCm![1] : 0
        let w = MapGeometry.r1(max(oldW, pts.isEmpty ? 0 : maxX + th.marginCm))
        let h = MapGeometry.r1(max(oldH, pts.isEmpty ? 0 : maxY + th.marginCm))
        reg.canvasCm = [w, h]

        // 9. 根字段
        let recomputed: Set<String> = ["mapElementList", "units", "floorPolygons", "obstaclePolygons", "connectors", "width", "height",
                                       "geoRef", "geoAnchor", "arAlign", "rotatedDeg", "scans", "frameId", "originOffsetCm", "geometryVersion"]
        var root: [String: Any] = [:]
        if let first = ordered.first, let br = roots[first.id] {
            for (k, v) in br where !recomputed.contains(k) { root[k] = v }
        }
        for key in ["ordinal", "venueId", "venueName"] where root[key] == nil {
            if let v = ordered.lazy.compactMap({ roots[$0.id]?[key] }).first { root[key] = v }
        }
        if let n = reg.name, !n.isEmpty { root["floorName"] = n }
        if let o = reg.ordinal { root["ordinal"] = o }
        if root["floorName"] == nil { root["floorName"] = reg.mapId }
        if root["source"] == nil { root["source"] = "roomplan" }
        // geoRef：先找启用的段
        let geoOrder = ordered.filter(\.enabled) + ordered.filter { !$0.enabled }
        for rec in geoOrder {
            guard let r = roots[rec.id], let g = GeoRef(dict: r["geoRef"] as? [String: Any]),
                  let cur = reg.scans.first(where: { $0.id == rec.id }) else { continue }
            let t = cur.transform
            root["geoRef"] = g.transformed(by: t).dict
            if var a = r["geoAnchor"] as? [String: Any], let x = MapGeometry.num(a["x"]), let y = MapGeometry.num(a["y"]) {
                let p = t.toMap(Point2(x, y))
                a["x"] = MapGeometry.r1(p.x); a["y"] = MapGeometry.r1(p.y)
                root["geoAnchor"] = a
            }
            break
        }
        if let f = reg.frameAlign {
            root["arAlign"] = MapGeometry.alignDict(f.transform)
            root["rotatedDeg"] = MapGeometry.r1(MapARTransform.wrapDeg(-f.phi * 180 / Double.pi))
        }
        root["width"] = w
        root["height"] = h
        root["mapElementList"] = items.map(\.raw)
        root["units"] = units.map { MapGeometry.unitDict(.init(id: $0.id, category: $0.category, name: $0.name, polygon: $0.poly)) }
        root["frameId"] = reg.frameId
        root["originOffsetCm"] = reg.originOffsetCm
        root["geometryVersion"] = reg.geometryVersion
        root["scans"] = reg.summary
        RoomMapBuilder.applyUnits(&root)
        return Result(json: try MapGeometry.data(root), registry: reg, originShift: shiftOut)
    }

    // MARK: 墙

    static func canMerge(_ base: MapGeometry.Segment, _ s: MapGeometry.Segment, _ th: Thresholds, maxGap: Double) -> MapGeometry.Segment? {
        guard MapGeometry.lineAngleDiffDeg(base.rotationDeg, s.rotationDeg) <= th.wallAngleDeg,
              abs(base.offset(of: s.center)) <= th.wallOffsetCm else { return nil }
        return MapGeometry.unionOnLine(base, s, maxGapCm: maxGap)
    }

    /// 以新墙为准合并：旧墙两端都离新墙的线不超过 `wallOffsetCm`、方向差 ≤ `wallAngleDeg` 才接，接成新墙的线
    /// （只看中心会把一长段斜一点的旧走廊墙整条转到新线上，远端挪得太多）
    static func canMergeNewer(_ new: MapGeometry.Segment, _ old: MapGeometry.Segment, _ th: Thresholds, maxGap: Double) -> MapGeometry.Segment? {
        guard MapGeometry.lineAngleDiffDeg(new.rotationDeg, old.rotationDeg) <= th.wallAngleDeg,
              abs(new.offset(of: old.a)) <= th.wallOffsetCm, abs(new.offset(of: old.b)) <= th.wallOffsetCm else { return nil }
        return MapGeometry.unionOnLine(new, old, maxGapCm: maxGap)
    }

    /// 新墙并进已有的墙。append：旧墙为准（新墙只补长度）；replace（`newerWins`）：新墙为准，接上的旧墙改到新墙的线上
    static func mergeWall(_ s: MapGeometry.Segment, raw: [String: Any], order k: Int, into items: inout [Item], _ th: Thresholds,
                          maxGap: Double, newerWins: Bool = false) {
        func isOld(_ i: Int) -> Bool { items[i].kind == .wall && items[i].order < k }
        func merge(_ base: MapGeometry.Segment, _ other: MapGeometry.Segment, _ gap: Double) -> MapGeometry.Segment? {
            newerWins ? canMergeNewer(base, other, th, maxGap: gap) : canMerge(base, other, th, maxGap: gap)
        }
        var mi: Int?
        for i in items.indices where isOld(i) {
            let u = newerWins ? canMergeNewer(s, items[i].seg!, th, maxGap: maxGap) : canMerge(items[i].seg!, s, th, maxGap: maxGap)
            if let u {
                items[i].seg = u; items[i].raw = MapGeometry.element(u, template: items[i].raw); mi = i
                break
            }
        }
        guard var m = mi else {
            items.append(Item(kind: .wall, raw: raw, order: k, seg: s, rect: nil))
            return
        }
        // 并集变长以后可能又和别的旧墙接上了
        var changed = true
        while changed {
            changed = false
            for j in items.indices where j != m && isOld(j) {
                if let u = merge(items[m].seg!, items[j].seg!, th.wallGapCm) {
                    items[m].seg = u; items[m].raw = MapGeometry.element(u, template: items[m].raw)
                    items.remove(at: j)
                    if j < m { m -= 1 }
                    changed = true
                    break
                }
            }
        }
    }

    /// 把墙在区域里的部分裁掉，返回留下的几截
    static func clip(_ s: MapGeometry.Segment, inside: (Point2) -> Bool, step: Double, minLen: Double) -> [MapGeometry.Segment] {
        let n = max(Int((s.length / step).rounded(.up)), 1)
        let h = s.length / Double(n)
        let flags = (0..<n).map { inside(s.a + s.direction * (h * (Double($0) + 0.5))) }
        guard flags.contains(true) else { return [s] }
        var out: [MapGeometry.Segment] = []
        var i = 0
        while i < n {
            if flags[i] { i += 1; continue }
            var j = i
            while j + 1 < n && !flags[j + 1] { j += 1 }
            let a = s.a + s.direction * (h * Double(i)), b = s.a + s.direction * (h * Double(j + 1))
            if a.distance(to: b) >= minLen {
                var p = s
                p.center = (a + b) * 0.5
                p.length = a.distance(to: b)
                out.append(p)
            }
            i = j + 1
        }
        return out
    }

    static func renumberFurniture(_ items: inout [Item]) {
        var byCat: [String: [Int]] = [:]
        for i in items.indices where items[i].kind == .furniture {
            if let c = items[i].rect?.category { byCat[c, default: []].append(i) }
        }
        for (cat, idx) in byCat {
            let sorted = idx.sorted { a, b in
                let p = items[a].rect!.center, q = items[b].rect!.center
                let py = (p.y / 10).rounded(), qy = (q.y / 10).rounded()
                if py != qy { return py < qy }
                let px = (p.x / 10).rounded(), qx = (q.x / 10).rounded()
                if px != qx { return px < qx }
                return a < b
            }
            for (n, i) in sorted.enumerated() { items[i].raw["code"] = "Room-\(cat)-\(n + 1)" }
        }
    }

    // MARK: 合并前的核对

    /// 新段（按 toMap 放进来）和已有地图的墙体一致性：重合长度、平均 / 最大垂直偏差。
    /// 合并预览和「视觉重定位后的核对」用：重合太少或偏差大，要用户确认或改手动对齐。
    public static func consistency(new: Data, toMap t: MapARTransform, existing: Data,
                                   thresholds th: Thresholds = Thresholds()) throws -> ScanRegistry.Quality {
        let src = MapGeometry.segments(try MapGeometry.root(new), types: ["MapWall"]).map { $0.transformed(by: t) }
        let dst = MapGeometry.segments(try MapGeometry.root(existing), types: ["MapWall"])
        var overlap = 0.0, sum = 0.0, mx = 0.0
        for s in src {
            let pts = s.samples(step: th.sampleStepCm)
            let h = s.length / Double(max(pts.count, 1))
            for p in pts {
                var best = Double.infinity
                for d in dst where MapGeometry.lineAngleDiffDeg(d.rotationDeg, s.rotationDeg) <= th.consistencyAngleDeg {
                    let u = d.param(of: p)
                    guard u >= -10, u <= d.length + 10 else { continue }
                    best = min(best, abs(d.offset(of: p)))
                }
                if best <= th.consistencyMatchCm { overlap += h; sum += best * h; mx = max(mx, best) }
            }
        }
        return ScanRegistry.Quality(overlapCm: overlap.rounded(), residualCm: overlap > 0 ? (sum / overlap * 10).rounded() / 10 : 0,
                                    maxResidualCm: overlap > 0 ? (mx * 10).rounded() / 10 : nil)
    }

    /// 新段的单元面积有多大比例已经在旧图的单元里（按 toMap 放进来）
    public static func shareInsideExisting(new: Data, toMap t: MapARTransform, existing: Data) throws -> Double {
        let newPolys = MapGeometry.units(try MapGeometry.root(new)).map { $0.polygon.map(t.toMap) }
        let old = MapGeometry.units(try MapGeometry.root(existing)).map(\.polygon)
        let total = newPolys.reduce(0) { $0 + MapGeometry.area($1) }
        guard total > 0 else { return 0 }
        return newPolys.reduce(0) { $0 + MapGeometry.area($1) * MapGeometry.shareInside($1, old) } / total
    }

    /// 建议的合成方式：新段大部分落在旧图里 → 替换这块（重扫 / 精细化），否则追加（接着扫）
    public static func suggestedMode(new: Data, toMap t: MapARTransform, existing: Data,
                                     thresholds th: Thresholds = Thresholds()) throws -> ScanRegistry.Mode {
        try shareInsideExisting(new: new, toMap: t, existing: existing) >= th.replaceSuggestShare ? .replace : .append
    }
}
