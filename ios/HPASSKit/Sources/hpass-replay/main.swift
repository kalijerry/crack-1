import Foundation
import HPASSKit

// 离线回放：用采集到的会话重跑「惯导 + 地磁粒子滤波」，和位置真值比。
//
//   swift run hpass-replay --session <会话目录> --map map.json --truth truth.csv \
//        [--magmap magmap.json] [--cold] [--depth depth_lateral.csv] [--out replay.csv]
//
// truth.csv 由 `tools/magmap.py --truth-dir` 导出。不给 --magmap 时只回放惯导（通道约束），
// 用来看惯导本身的漂移；给了就同时输出地磁滤波的结果，两者对比能看出地磁纠偏带来多少。

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(1)
}
guard let sessionDir = arg("--session"), let mapPath = arg("--map"), let truthPath = arg("--truth") else {
    fail("用法：hpass-replay --session <目录> --map map.json --truth truth.csv [--magmap magmap.json] [--cold] [--out replay.csv]")
}
let cold = CommandLine.arguments.contains("--cold")

func rows(_ path: String) -> [[String]] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("读不到 \(path)") }
    return text.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
}

let storeMap: StoreMap
do { storeMap = try StoreDataLoader.loadMap(Data(contentsOf: URL(fileURLWithPath: mapPath))) } catch { fail("地图解析失败：\(error)") }
var field: MagneticFieldMap?
if let mp = arg("--magmap") {
    do { field = try StoreDataLoader.loadMagneticField(Data(contentsOf: URL(fileURLWithPath: mp))) } catch { fail("磁场图解析失败：\(error)") }
}

struct TruthPoint { var t: Int64; var p: Point2 }
let truth = rows(truthPath).compactMap { r -> TruthPoint? in
    guard r.count >= 3, let t = Int64(r[0]), let x = Double(r[1]), let y = Double(r[2]) else { return nil }
    return TruthPoint(t: t, p: Point2(x, y))
}
guard truth.count > 10 else { fail("真值太少") }

func truthAt(_ t: Int64) -> Point2? {
    guard t >= truth[0].t, t <= truth[truth.count - 1].t else { return nil }
    var lo = 0, hi = truth.count - 1
    while hi - lo > 1 { let m = (lo + hi) / 2; if truth[m].t <= t { lo = m } else { hi = m } }
    let a = truth[lo], b = truth[hi]
    let f = b.t > a.t ? Double(t - a.t) / Double(b.t - a.t) : 0
    return Point2(a.p.x + (b.p.x - a.p.x) * f, a.p.y + (b.p.y - a.p.y) * f)
}

let imu = rows(sessionDir + "/imu.csv").compactMap { r -> IMUSample? in
    guard r.count >= 10, let t = Int64(r[0]) else { return nil }
    let v = r[1...9].map { Double($0) ?? 0 }
    return IMUSample(tMs: t, ax: v[0], ay: v[1], az: v[2], gx: v[3], gy: v[4], gz: v[5], mx: v[6], my: v[7], mz: v[8])
}.filter { $0.tMs >= truth[0].t - 3000 }

// 起点和朝向：真值的第一个点，以及前 1.5 m 的行进方向
let start = truth[0].p
var heading: Double?
if let far = truth.first(where: { $0.p.distance(to: start) >= 150 }) {
    heading = atan2(far.p.x - start.x, far.p.y - start.y)
}

var fcfg = FusionConfig()
fcfg.useCorridorConstraint = !storeMap.crosses.isEmpty
fcfg.useMagneticHeading = false
let fusion = FusionEngine(corridors: storeMap.crosses, config: fcfg)
fusion.setInitialPosition(cold ? Point2(storeMap.width / 2, storeMap.height / 2) : start, headingRad: cold ? nil : heading)

let extractor = MagneticFeatureExtractor()
var localizer: MagneticLocalizer?
if let f = field {
    var cfg = MagneticConfig()
    if cold { cfg.initialHeadingBiasSigmaDeg = 30 }
    let walk = storeMap.crosses.isEmpty ? nil : WalkableMap(crosses: storeMap.crosses, widthCm: storeMap.width, heightCm: storeMap.height)
    localizer = MagneticLocalizer(field: f, walkable: walk, config: cfg)
    localizer?.reset(start: cold ? nil : start, spreadCm: 50)
}

var lastPos: Point2?
var pdrErr: [Double] = [], pfErr: [Double] = []
var convergedAtMs: Int64?
var out = ["t_ms,truth_x,truth_y,pdr_x,pdr_y,pf_x,pf_y,pdr_err,pf_err,unc,conf"]
for s in imu {
    let feat = extractor.process(s)
    guard let o = fusion.process(s) else { continue }
    let delta = lastPos.map { o.position - $0 } ?? .zero
    lastPos = o.position
    var pf: MagneticEstimate?
    if let loc = localizer { pf = loc.step(delta: delta, feature: feat) }
    guard let tr = truthAt(o.tMs) else { continue }
    let pe = o.position.distance(to: tr)
    let fe = pf.map { $0.position.distance(to: tr) }
    if let e = pf, e.converged, convergedAtMs == nil { convergedAtMs = o.tMs }
    if !cold || pf?.converged == true || localizer == nil {
        pdrErr.append(pe)
        if let fe { pfErr.append(fe) }
    }
    out.append([String(o.tMs), Fmt.f1(tr.x), Fmt.f1(tr.y), Fmt.f1(o.position.x), Fmt.f1(o.position.y),
                pf.map { Fmt.f1($0.position.x) } ?? "", pf.map { Fmt.f1($0.position.y) } ?? "",
                Fmt.f1(pe), fe.map(Fmt.f1) ?? "", pf.map { Fmt.f1($0.uncertaintyCm) } ?? "",
                pf.map { String(format: "%.2f", $0.confidence) } ?? ""].joined(separator: ","))
}

enum Fmt { static func f1(_ v: Double) -> String { String(format: "%.1f", v) } }

func stats(_ name: String, _ e: [Double]) {
    guard !e.isEmpty else { print("\(name)：没有数据"); return }
    let s = e.sorted()
    print(String(format: "%@：n=%d  中位 %.0f cm  P90 %.0f cm  最大 %.0f cm  最后 %.0f cm", name, s.count,
                 s[s.count / 2], s[Int(Double(s.count) * 0.9)], s[s.count - 1], e[e.count - 1]))
}
print("会话 \(sessionDir)，IMU \(imu.count) 个样本，真值 \(truth.count) 点，\(cold ? "冷启动" : "已知起点")")
stats("惯导（通道约束）", pdrErr)
if localizer != nil {
    stats("地磁粒子滤波  ", pfErr)
    if cold { print(convergedAtMs.map { "冷启动在第 \(Double($0 - truth[0].t) / 1000) 秒收敛" } ?? "冷启动没有收敛") }
}
// 激光雷达横向距离核对：用真值轨迹的行进方向，在地图货架上射线投射，与实测的左右货架距离比
if let depthPath = arg("--depth"), !storeMap.shelves.isEmpty {
    let rc = ShelfRaycaster(shelves: storeMap.shelves, widthCm: storeMap.width, heightCm: storeMap.height)
    var errL: [Double] = [], errR: [Double] = [], gapMeasured: [Double] = [], gapPredicted: [Double] = []
    for r in rows(depthPath) {
        guard r.count >= 5, let t = Int64(r[0]), let p = truthAt(t),
              let a = truthAt(t - 500), let b = truthAt(t + 500), a.distance(to: b) > 40 else { continue }
        let heading = atan2(b.x - a.x, b.y - a.y)
        let (pl, pr) = rc.lateral(from: p, headingRad: heading, maxCm: 450)
        let ml = Double(r[1]), mr = Double(r[2])
        if let ml, let pl { errL.append(abs(ml - pl)) }
        if let mr, let pr { errR.append(abs(mr - pr)) }
        if let ml, let mr, let pl, let pr { gapMeasured.append(ml + mr); gapPredicted.append(pl + pr) }
    }
    print("\n激光雷达横向距离 vs 地图货架（沿真值轨迹）")
    stats("  左侧距离误差", errL)
    stats("  右侧距离误差", errR)
    stats("  通道净宽误差 ", zip(gapMeasured, gapPredicted).map { abs($0 - $1) })
    print("  判读：中位误差在 30 cm 以内，且样本数足够，才适合把「激光雷达」切到「参与定位」；")
    print("        误差很大说明深度换算、货架摆放与地图不一致，先不要打开。")
}
if let path = arg("--out") { try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
