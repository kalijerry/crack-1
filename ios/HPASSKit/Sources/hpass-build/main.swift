import Foundation
import HPASSKit

// 云端融合建图：把一张地图的所有建图会话（可以是不同手机、不同天、不同分片）融合成一张磁场图 + 蓝牙指纹，
// 打成云端地图包，并出一份报告（各会话偏移、哪些分片没连上、覆盖率、测试会话精度）。
//
//   hpass-build --map map.json --sessions 目录1,目录2,… [--test 测试会话,…] [--esl-ids 价签名单.txt]
//               --id 地图编号 --name 名字 [--kind store|room] [--bearing 316]
//               [--esl-locations 价签位置表.csv（也打进包里）] --out 包.hpmp --report 报告.json [--runs 3]

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func list(_ s: String?) -> [URL] { (s ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) } }

struct Report: Encodable {
    var mapId: String
    var name: String
    var version: Int64
    var sessions: [MultiSessionFusion.SessionInfo]
    var components: Int
    var fieldCells: Int
    var bleTags: Int
    var coverage: Double?
    var coveredM2: Double?
    var walkableM2: Double?
    var unfinishedCorridors: [String]
    var tests: [EvalReport]
    var packageBytes: Int
    var warnings: [String]
    var eslMismatches: [String]
}

guard let mapPath = arg("--map"), let out = arg("--out"), let id = arg("--id") else {
    print("用法：hpass-build --map map.json --sessions 会话1,会话2 --id 地图编号 --name 名字 --out 包.hpmp --report 报告.json")
    exit(2)
}
do {
    let mapData = try Data(contentsOf: URL(fileURLWithPath: mapPath))
    let map = try StoreDataLoader.loadMap(mapData)
    let dirs = list(arg("--sessions"))
    guard !dirs.isEmpty else { print("没有建图会话"); exit(2) }
    var sessions: [SurveySession] = []
    var bleSamples: [[BLESample]] = []
    for d in dirs {
        do { sessions.append(try SurveySessionLoader.load(d)); bleSamples.append(SurveySessionLoader.loadBLE(d)) }
        catch { print("⚠️ 跳过 \(d.lastPathComponent)：\(error)") }
    }
    let t0 = Date()
    let fusion = MultiSessionFusion(map: map)
    let r = fusion.fuse(sessions)
    print("融合 \(sessions.count) 个会话，\(r.components) 个连通分量，磁场 \(r.field.coveredCells) 格（\(Int(Date().timeIntervalSince(t0))) 秒）")
    for s in r.sessions {
        print(String(format: "  %@：样本 %d，格 %d，偏移 |B| %+.1f Bz %+.1f Bh %+.1f µT，分量 %d，重叠 %@",
                     s.name, s.samples, s.cells, s.offset[0], s.offset[1], s.offset[2], s.component,
                     s.overlaps.isEmpty ? "无" : s.overlaps.map { "\($0.key.suffix(6))×\($0.value)" }.joined(separator: " ")))
        for w in s.warnings { print("    ⚠️ \(w)") }
    }
    // 蓝牙指纹
    let bb = BLEFingerprintBuilder(widthCm: map.width, heightCm: map.height)
    if let p = arg("--esl-ids"), let t = try? String(contentsOfFile: p, encoding: .utf8) { bb.whitelist = BLEFingerprintBuilder.parseIdList(t) }
    for (k, track) in r.tracks.enumerated() where k < bleSamples.count { _ = bb.add(samples: bleSamples[k], track: track) }
    let learnedBLE = bb.build()
    print("蓝牙指纹（采集学到）：\(learnedBLE.tags.count) 个价签" + (bb.rejectedMoving.isEmpty ? "" : "（\(bb.rejectedMoving.count) 个移动设备不算）"))
    // 价签位置表：当蓝牙底图（全店都有），学到的只在表明显不对时替换
    var bleMap = learnedBLE
    var eslMismatches: [String] = []
    var eslCSV: Data?
    if let p = arg("--esl-locations"), let t = try? String(contentsOfFile: p, encoding: .utf8) {
        eslCSV = Data(t.utf8)
        let locs = EslLocations.parse(t, map: map)
        bleMap = EslLocations.seededBLEMap(locs, learned: learnedBLE)
        eslMismatches = EslLocations.mismatches(locs, learned: learnedBLE).map { "\($0.id) \($0.shelf) 差 \(Int($0.distanceCm / 100)) m" }
        print("价签位置表：\(locs.count) 个，对上货架 \(locs.filter { $0.position != nil }.count) 个；合并后 \(bleMap.tags.count) 个；表里可能不对 \(eslMismatches.count) 个")
    }
    let ble: BLEFingerprintMap? = bleMap.tags.count >= 20 ? bleMap : nil
    // 覆盖率：按所有会话的轨迹涂色
    var coverage: Double?, covered: Double?, walkableM2: Double?
    var unfinished: [String] = []
    let walk = SessionEvaluator.walkable(map)
    let paint: CoveragePaint? = !map.crosses.isEmpty
        ? CoveragePaint(crosses: map.crosses, widthCm: map.width, heightCm: map.height)
        : walk.map { CoveragePaint(walkable: $0) }
    if let p = paint {
        for track in r.tracks { p.breakStroke(); for tp in track { p.paint(at: tp.p) } }
        coverage = p.fraction; covered = p.paintedAreaM2; walkableM2 = p.walkableAreaM2
        for (i, c) in map.crosses.enumerated() where c.a.distance(to: c.b) > 500 && c.lineWidth >= 50 {
            let f = p.fraction(corridor: i)
            if f > 0 && f < 0.5 { unfinished.append("\(c.code) \(Int(f * 100))%") }
        }
        print(String(format: "覆盖：%.1f%%（%.0f / %.0f m²），没涂完一半的通道 %d 条", (coverage ?? 0) * 100, covered ?? 0, walkableM2 ?? 0, unfinished.count))
    }
    // 测试会话
    var tests: [EvalReport] = []
    let runs = max(Int(arg("--runs") ?? "3") ?? 3, 1)
    for t in list(arg("--test")) {
        for k in 0..<runs {
            if let e = try? SessionEvaluator.evaluate(dir: t, map: map, field: r.field, ble: ble, walkable: walk, seed: UInt64(k + 1)) {
                tests.append(e)
                if k == 0 { print("测试 " + e.line) }
            }
        }
    }
    // 打包
    var meta = MapPackage.Meta(id: id, name: arg("--name") ?? id, kind: arg("--kind") ?? (map.crosses.isEmpty ? "room" : "store"),
                               version: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
                               source: "云端融合 \(sessions.count) 个会话", mapUpBearingDeg: arg("--bearing").flatMap(Double.init),
                               magSource: "raw")
    meta.fieldCells = r.field.coveredCells
    meta.origin = "cloud"
    meta.sessions = sessions.count
    meta.bleTags = ble?.tags.count
    let pkg = try MapPackage.encode(meta: meta, mapJSON: mapData, field: r.field, ble: ble, worldMap: nil, paint: paint?.serialized(), eslCSV: eslCSV)
    try pkg.write(to: URL(fileURLWithPath: out))
    print("地图包 \(pkg.count / 1024) KB → \(out)")
    var warnings: [String] = []
    if r.components > 1 { warnings.append("有 \(r.components - 1) 组会话和主体没连上（没有足够重叠），它们的磁场偏移没法对齐") }
    if let rp = arg("--report") {
        let rep = Report(mapId: id, name: meta.name, version: meta.version, sessions: r.sessions, components: r.components,
                         fieldCells: r.field.coveredCells, bleTags: ble?.tags.count ?? 0, coverage: coverage, coveredM2: covered,
                         walkableM2: walkableM2, unfinishedCorridors: unfinished, tests: tests, packageBytes: pkg.count, warnings: warnings,
                         eslMismatches: eslMismatches)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rep).write(to: URL(fileURLWithPath: rp))
    }
    for w in warnings { print("⚠️ \(w)") }
} catch {
    print("出错：\(error)")
    exit(1)
}
