import Foundation
import HPASSKit

// 定位精度评估：建图会话生成磁场图 + 蓝牙指纹，测试会话冷启动回放，和各自的采集轨迹比。
//
//   swift run -c release hpass-eval --map map.json --build s1,s2 --test t1,t2 [--no-ble] [--json report.json]
//
// 会话目录里要有 imu.csv、arkit_pose.csv、anchors.csv（建图采集会话的格式），mag_raw.csv / ble.csv 可选。

func arg(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}
func list(_ s: String?) -> [URL] { (s ?? "").split(separator: ",").map { URL(fileURLWithPath: String($0)) } }

guard let mapPath = arg("--map") else {
    print("用法：hpass-eval --map map.json --build 会话1,会话2 --test 会话3,会话4 [--no-ble] [--json 输出.json]")
    exit(2)
}
do {
    let map = try StoreDataLoader.loadMap(Data(contentsOf: URL(fileURLWithPath: mapPath)))
    let build = list(arg("--build")), test = list(arg("--test"))
    guard !build.isEmpty, !test.isEmpty else { print("--build 和 --test 都要给"); exit(2) }
    let overlap = Set(build.map(\.standardizedFileURL)).intersection(test.map(\.standardizedFileURL))
    if !overlap.isEmpty { print("⚠️ 有会话同时在建图和测试里：\(overlap.map(\.lastPathComponent))，结果会偏乐观") }
    let (field, bleMap, reps) = try SessionEvaluator.buildMaps(sessions: build, map: map)
    for r in reps { print("建图 \(r.name)：样本 \(r.samplesUsed)" + (r.warnings.isEmpty ? "" : "，⚠️ \(r.warnings.joined(separator: "；"))")) }
    print("磁场图：有数据 \(field.coveredCells) 格；蓝牙指纹：\(bleMap.map { "\($0.tags.count) 个价签" } ?? "无")")
    let ble = CommandLine.arguments.contains("--no-ble") ? nil : bleMap
    let walk = SessionEvaluator.walkable(map)
    var out: [EvalReport] = []
    // 粒子滤波有随机性（加上字典遍历顺序每次不同），单次结果波动很大：--runs N 跑 N 次（不同随机种子），报中位和范围
    let runs = max(Int(arg("--runs") ?? "1") ?? 1, 1)
    for t in test {
        var rs: [EvalReport] = []
        for k in 0..<runs {
            let r = try SessionEvaluator.evaluate(dir: t, map: map, field: field, ble: ble, walkable: walk,
                                                  crossCheck: !CommandLine.arguments.contains("--no-crosscheck"), configure: { cfg in
                if CommandLine.arguments.contains("--offset") { cfg.offsetInvariant = true }
                if CommandLine.arguments.contains("--hybrid") { cfg.hybridOffset = true }
                if CommandLine.arguments.contains("--absolute") { cfg.offsetInvariant = false }
                if let w = arg("--abs").flatMap(Double.init) { cfg.absoluteWeight = w }
                if let w = arg("--win").flatMap(Double.init) { cfg.offsetWindowUpdates = w }
            }, seed: UInt64(k + 1))
            if runs == 1 { print(r.line) }
            rs.append(r)
        }
        if runs > 1 {
            func summary(_ xs: [Double?], unit: String = " cm") -> String {
                let v = xs.compactMap { $0 }.sorted()
                guard !v.isEmpty else { return "—" }
                return String(format: "%.0f%@（%.0f～%.0f）", v[v.count / 2], unit, v.first!, v.last!)
            }
            print("\(t.lastPathComponent)  \(runs) 次：中位 \(summary(rs.map(\.medianCm)))  P90 \(summary(rs.map(\.p90Cm)))"
                  + "  首次定位 \(summary(rs.map(\.firstFixM), unit: " m"))  跳 \(summary(rs.map { Double($0.jumps) }, unit: ""))")
            print("    └ 只看建图覆盖到的地方：中位 \(summary(rs.map(\.inMapMedianCm)))  P90 \(summary(rs.map(\.inMapP90Cm)))"
                  + "  ≤1m \(summary(rs.map { $0.inMapWithin1m.map { $0 * 100 } }, unit: "%"))")
        }
        out.append(contentsOf: rs)
    }
    let all = out.compactMap(\.medianCm)
    if all.count > 1 { print(String(format: "测试会话中位误差的中位：%.0f cm", all.sorted()[all.count / 2])) }
    if let j = arg("--json") {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(out).write(to: URL(fileURLWithPath: j))
    }
} catch {
    print("出错：\(error)")
    exit(1)
}
