import Foundation
import HPASSKit

// 离线回放：用采集到的会话重跑「惯导 + 地磁粒子滤波」，和位置真值比。
//
//   swift run hpass-replay --session <会话目录> --map map.json --truth truth.csv \
//        [--magmap magmap.json] [--cold] [--vio] [--depth depth_lateral.csv] [--out replay.csv]
//
// --vio：用 ARKit 位姿（arkit_pose.csv）当运动模型，与 App「实时定位」开视觉里程计时一致。
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

let useVIO = CommandLine.arguments.contains("--vio")

var fcfg = FusionConfig()
fcfg.useCorridorConstraint = !storeMap.crosses.isEmpty
fcfg.useMagneticHeading = false
let fusion = FusionEngine(corridors: storeMap.crosses, config: fcfg)
fusion.setInitialPosition(cold ? Point2(storeMap.width / 2, storeMap.height / 2) : start, headingRad: cold ? 0 : heading)

let extractor = MagneticFeatureExtractor()
// 磁场可信度：与 App 一样用原始磁力计发现系统重新校准（没有 mag_raw.csv 时只看精度）
let trustMon = MagneticTrustMonitor()
let rawMag: [(t: Int64, v: (Double, Double, Double))] = FileManager.default.fileExists(atPath: sessionDir + "/mag_raw.csv")
    ? rows(sessionDir + "/mag_raw.csv").compactMap { r in
        guard r.count >= 4, let t = Int64(r[0]), let x = Double(r[1]), let y = Double(r[2]), let z = Double(r[3]) else { return nil }
        return (t, (x, y, z)) }
    : []
let accuracyByT: [Int64: Int] = Dictionary(rows(sessionDir + "/imu.csv").compactMap { r -> (Int64, Int)? in
    guard r.count >= 11, let t = Int64(r[0]), let a = Int(r[10]) else { return nil }
    return (t, a) }, uniquingKeysWith: { a, _ in a })
var rawIdx = 0
var trustNow = 1.0
// 磁场来源与地图一致：地图是 raw（原始磁力计减偏置）时，这边也一样，偏置用开始以来的中位数（与 App 相同）
let mapSource: String = arg("--magmap").flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }.map(StoreDataLoader.loadMagSource) ?? "calibrated"
let useRaw = mapSource == "raw" && !rawMag.isEmpty && !CommandLine.arguments.contains("--calibrated")
let biasTracker = RawBiasTracker()
var featIdx = 0
/// 处理一个 IMU 样本，返回最新特征。raw 模式：特征按原始磁力计的时刻逐个算，重力方向来自加速度。
func featureStep(_ s: IMUSample) -> MagneticFeature? {
    guard useRaw else { return extractor.process(s) }
    extractor.updateGravity(s)
    if let r = rawMag.isEmpty ? nil : rawMag[min(rawIdx, rawMag.count - 1)], abs(r.t - s.tMs) <= 20 {
        biasTracker.add(tMs: s.tMs, raw: r.v, calibrated: (s.mx, s.my, s.mz))
    }
    guard biasTracker.isReady else { return extractor.process(magnetic: (s.mx, s.my, s.mz), tMs: s.tMs) }
    var f: MagneticFeature?
    while featIdx < rawMag.count && rawMag[featIdx].t <= s.tMs {
        if let m = biasTracker.corrected(rawMag[featIdx].v) { f = extractor.process(magnetic: m, tMs: rawMag[featIdx].t) }
        featIdx += 1
    }
    return f
}
func updateTrust(_ s: IMUSample) {
    while rawIdx + 1 < rawMag.count && rawMag[rawIdx + 1].t <= s.tMs { rawIdx += 1 }
    let raw = rawMag.isEmpty ? nil : (abs(rawMag[rawIdx].t - s.tMs) <= 20 ? rawMag[rawIdx].v : nil)
    trustNow = trustMon.update(tMs: s.tMs, calibrated: (s.mx, s.my, s.mz), raw: useRaw ? nil : raw, accuracy: accuracyByT[s.tMs] ?? 2)
}
var localizer: MagneticLocalizer?
if let f = field {
    var cfg = MagneticConfig()
    if cold { cfg.initialHeadingBiasSigmaDeg = 30 }
    if useVIO && !cold && CommandLine.arguments.contains("--tight") {
        cfg.initialHeadingBiasSigmaDeg = 5; cfg.headingBiasWalkDegPerM = 1; cfg.positionNoiseFraction = 0.04
        cfg.initialScaleSigma = 0.03; cfg.scaleWalkPerM = 0.003
    } else if !useVIO {
        cfg.initialScaleSigma = 0.15            // 计步的步长误差可能有三成
    }
    let walk = storeMap.crosses.isEmpty ? nil : WalkableMap(crosses: storeMap.crosses, widthCm: storeMap.width, heightCm: storeMap.height)
    localizer = MagneticLocalizer(field: f, walkable: walk, config: cfg)
    localizer?.reset(start: cold ? nil : start, spreadCm: 50, headingUnknown: cold)
    if cold, let l = localizer { print(String(format: "冷启动范围：有磁场数据的区域 %.0f m²", l.mappedAreaM2)) }
}

var pdrErr: [Double] = [], pfErr: [Double] = []
var convergedAtMs: Int64?
var out = ["t_ms,truth_x,truth_y,pdr_x,pdr_y,pf_x,pf_y,pdr_err,pf_err,unc,conf"]
var latestFeature: MagneticFeature?
var lastPDR: Point2?
var pdrPos: Point2 = start

func record(_ t: Int64, _ shownPDR: Point2, _ pf: MagneticEstimate?) {
    guard let tr = truthAt(t) else { return }
    let pe = shownPDR.distance(to: tr)
    let fe = pf.map { $0.position.distance(to: tr) }
    if let e = pf, e.converged, convergedAtMs == nil { convergedAtMs = t }
    // 门控：滤波器没把握（未收敛 / 丢失）时 App 不显示位置，这里也不计入误差
    if localizer == nil || pf?.converged == true {
        pdrErr.append(pe)
        if let fe { pfErr.append(fe) }
    }
    out.append([String(t), Fmt.f1(tr.x), Fmt.f1(tr.y), Fmt.f1(shownPDR.x), Fmt.f1(shownPDR.y),
                pf.map { Fmt.f1($0.position.x) } ?? "", pf.map { Fmt.f1($0.position.y) } ?? "",
                Fmt.f1(pe), fe.map(Fmt.f1) ?? "", pf.map { Fmt.f1($0.uncertaintyCm) } ?? "",
                pf.map { String(format: "%.2f", $0.confidence) } ?? ""].joined(separator: ","))
}

if useVIO {
    // 视觉里程计做运动模型：已知起点用对齐器（朝向取真值前 1.5 m），冷启动直接用 ARKit 原始位移（旋转由粒子去猜）
    struct Pose { var t: Int64; var a: Point2; var ok: Bool }
    let poses = rows(sessionDir + "/arkit_pose.csv").compactMap { r -> Pose? in
        guard r.count >= 9, let t = Int64(r[0]), let x = Double(r[1]), let z = Double(r[3]) else { return nil }
        return Pose(t: t, a: Point2(x * 100, z * 100), ok: r[8] == "2")
    }.filter { $0.t >= truth[0].t }
    let aligner = VisualOdometryAligner()
    var anchored = false
    var lastA: Point2?
    var accum = Point2.zero
    var k = 0
    for p in poses {
        while k < imu.count && imu[k].tMs <= p.t { updateTrust(imu[k]); latestFeature = featureStep(imu[k]) ?? latestFeature; k += 1 }
        var delta = Point2.zero
        if cold {
            if let la = lastA, p.ok { delta = p.a - la }
            lastA = p.a
        } else {
            if !anchored, p.ok { aligner.anchor(map: start, ar: p.a, headingRad: heading); anchored = true; continue }
            if case .aligned(let pos, let d) = aligner.process(ar: p.a, trackingNormal: p.ok) { delta = d; pdrPos = pos }
        }
        accum = accum + delta
        guard accum.length >= 20 else { continue }
        if cold { pdrPos = pdrPos + accum }
        let est = localizer?.step(delta: accum, feature: latestFeature, trust: trustNow)
        accum = .zero
        record(p.t, pdrPos, est)
    }
} else {
    for s in imu {
        updateTrust(s)
        if let f = featureStep(s) { latestFeature = f }
        let feat = latestFeature
        guard let o = fusion.process(s) else { continue }
        let delta = lastPDR.map { o.position - $0 } ?? .zero
        lastPDR = o.position
        let est = localizer?.step(delta: delta, feature: feat, trust: trustNow)
        record(o.tMs, o.position, est)
    }
}

enum Fmt { static func f1(_ v: Double) -> String { String(format: "%.1f", v) } }

func stats(_ name: String, _ e: [Double]) {
    guard !e.isEmpty else { print("\(name)：没有数据"); return }
    let s = e.sorted()
    print(String(format: "%@：n=%d  中位 %.0f cm  P90 %.0f cm  最大 %.0f cm  最后 %.0f cm", name, s.count,
                 s[s.count / 2], s[Int(Double(s.count) * 0.9)], s[s.count - 1], e[e.count - 1]))
}
print("会话 \(sessionDir)，IMU \(imu.count) 个样本，真值 \(truth.count) 点，\(cold ? "冷启动" : "已知起点")，运动模型 \(useVIO ? "视觉里程计" : "计步")")
stats(useVIO ? "视觉里程计（无地磁）" : "惯导（通道约束）", pdrErr)
if localizer != nil {
    stats("地磁粒子滤波  ", pfErr)
    if cold { print(convergedAtMs.map { "冷启动在第 \(Double($0 - truth[0].t) / 1000) 秒收敛" } ?? "冷启动没有收敛") }
}
// 激光雷达横向距离核对：用真值轨迹的行进方向，在地图货架上射线投射，与实测的左右货架距离比
if let depthPath = arg("--depth"), !storeMap.physicalShelves.isEmpty {
    let rc = ShelfRaycaster(shelves: storeMap.physicalShelves, widthCm: storeMap.width, heightCm: storeMap.height)
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
print("磁场可信度：发现系统重新校准 \(trustMon.jumpCount) 次；磁场来源 \(useRaw ? "原始磁力计减偏置" : "iOS 校准后")")
if let path = arg("--out") { try? out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
