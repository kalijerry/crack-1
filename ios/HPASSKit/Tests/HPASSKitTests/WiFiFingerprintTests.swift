import Foundation
import XCTest
@testable import HPASSKit

/// Wi-Fi 指纹（kNN）、wifi.csv 读取和 Wi-Fi 冷启动（只在评估 `--wifi` 时用）。
final class WiFiFingerprintTests: XCTestCase {

    /// 40 m × 10 m 的场地，AP 每 8 m 一个、两排；信号按对数距离衰减，-95 dBm 以下听不到。
    private let aps: [(String, Point2)] = (0..<12).map { k in
        ("00:00:00:00:00:\(String(format: "%02x", k))", Point2(200 + Double(k % 6) * 800, k < 6 ? 100 : 900))
    }

    private func scan(at p: Point2, t: Int64 = 0) -> WiFiScan {
        var r: [String: Double] = [:]
        for (b, q) in aps {
            let v = -40 - 25 * log10(max(p.distance(to: q), 100) / 100)
            if v > -95 { r[b] = v }
        }
        return WiFiScan(tMs: t, rssi: r)
    }

    /// 建图：沿 y = 300、500、700 三条线来回走，每 2 s（约 2.4 m）扫一次
    private func builtMap() -> WiFiFingerprintMap {
        let b = WiFiFingerprintBuilder()
        for (n, y) in [300.0, 500, 700].enumerated() {
            var track: [(tMs: Int64, p: Point2)] = []
            var scans: [WiFiScan] = []
            for i in 0...330 {
                let t = Int64(n * 1_000_000 + i * 100)
                let p = Point2(150 + Double(i) * 12, y)
                track.append((t, p))
                if i % 20 == 0 { scans.append(scan(at: p, t: t)) }
            }
            XCTAssertEqual(b.add(scans: scans, track: track), scans.count)
        }
        return b.build()
    }

    func testGroupMergesSameTimeAndKeepsStrongest() {
        let g = WiFiScan.group([
            WiFiSample(tMs: 2000, bssid: "a", rssi: -70),
            WiFiSample(tMs: 1000, bssid: "a", rssi: -60),
            WiFiSample(tMs: 1000, bssid: "b", rssi: -80),
            WiFiSample(tMs: 1000, bssid: "a", rssi: -55),
        ])
        XCTAssertEqual(g.map(\.tMs), [1000, 2000])
        XCTAssertEqual(g[0].rssi, ["a": -55, "b": -80])
        XCTAssertEqual(g[1].rssi, ["a": -70])
    }

    func testLoaderParsesRowsAndSkipsBadOnes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wifi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 没有 wifi.csv：空
        XCTAssertEqual(SurveySessionLoader.loadWiFi(dir), [])
        let text = """
        t_ms,bssid,rssi,freq
        1000,A8:0C:CA:03:9D:D7,-49,2422
        1000,74:ee:2a:cd:eb:43,-71,5785
        oops,74:ee:2a:cd:eb:44,-71,5785
        1200,,-60,2412
        1300,04:33:89:79:fc:7c,-80
        1400,04:33:89:79:fc:7d,bad,2412
        """
        try text.write(to: dir.appendingPathComponent("wifi.csv"), atomically: true, encoding: .utf8)
        let s = SurveySessionLoader.loadWiFi(dir)
        XCTAssertEqual(s, [
            WiFiSample(tMs: 1000, bssid: "a8:0c:ca:03:9d:d7", rssi: -49, freqMHz: 2422),
            WiFiSample(tMs: 1000, bssid: "74:ee:2a:cd:eb:43", rssi: -71, freqMHz: 5785),
            WiFiSample(tMs: 1300, bssid: "04:33:89:79:fc:7c", rssi: -80, freqMHz: 0),
        ])
        XCTAssertEqual(WiFiScan.group(s).count, 2)
    }

    func testDistanceUsesUnionWithMissingValue() {
        // a 听到 0、1，b 听到 1、2：并集 {0,1,2}，差 = (-60+100, -70+75, -100+80) = (40, 5, -20)
        let d = WiFiFingerprintMap.distance([(0, -60), (1, -70)], [(1, -75), (2, -80)], missing: -100)
        let sq: Double = 1600 + 25 + 400
        XCTAssertEqual(d, (sq / 3).squareRoot(), accuracy: 1e-9)
        // 指纹库里没有的 AP 也算进并集
        let e = WiFiFingerprintMap.distance([(0, -60)], [(0, -60)], missing: -100, extra: (sum: 900, n: 1))
        XCTAssertEqual(e, (900.0 / 2).squareRoot(), accuracy: 1e-9)
    }

    func testKNNLocatesWithinAFewMetres() {
        let m = builtMap()
        XCTAssertEqual(m.entries.count, 3 * 17)
        for p in [Point2(600, 500), Point2(2100, 350), Point2(3700, 650)] {
            let f = m.locate(scan(at: p), k: 5)
            XCTAssertNotNil(f)
            XCTAssertLessThan(f!.position.distance(to: p), 250, "\(p)")
        }
        // 完全一样的扫描：最近的一条权重最大，结果就在它附近
        let exact = m.entries[20].position
        XCTAssertLessThan(m.locate(scan(at: exact), k: 5)!.position.distance(to: exact), 150)
    }

    func testKNNRejectsTooFewOrUnknownAPs() {
        let m = builtMap()
        XCTAssertNil(m.locate(WiFiScan(tMs: 0, rssi: ["00:00:00:00:00:00": -50, "00:00:00:00:00:01": -60])))
        XCTAssertNil(m.locate(WiFiScan(tMs: 0, rssi: ["x1": -50, "x2": -60, "x3": -70])))
    }

    func testBuilderSkipsScansOffTheTrack() {
        let b = WiFiFingerprintBuilder()
        let track: [(tMs: Int64, p: Point2)] = [(1000, Point2(0, 0)), (2000, Point2(100, 0))]
        let s = scan(at: .zero)
        XCTAssertEqual(b.add(scans: [WiFiScan(tMs: 1500, rssi: s.rssi), WiFiScan(tMs: 9000, rssi: s.rssi)], track: track), 1)
        XCTAssertEqual(b.build().entries[0].position.x, 50, accuracy: 1e-9)
    }

    func testRobustPriorPullsParticlesAndSpreadShrinks() {
        let f = flatField()
        let loc = MagneticLocalizer(field: f, walkable: nil)
        loc.reset(start: Point2(2000, 500), spreadCm: 800, headingUnknown: true)
        let before = loc.weightedSpread()
        XCTAssertGreaterThan(before.spreadCm, 600)
        XCTAssertGreaterThan(before.headingSpreadDeg, 60)
        for _ in 0..<5 { loc.applyRobustPositionPrior(Point2(1500, 500), sigmaCm: 300) }
        let after = loc.weightedSpread()
        XCTAssertLessThan(after.mean.distance(to: Point2(1500, 500)), 150)
        XCTAssertLessThan(after.spreadCm, before.spreadCm / 2)
    }

    /// Wi-Fi 冷启动：第一次扫描之前不报位置；位姿坐标系转了 90°（朝向不知道），一路有 Wi-Fi，走一段之后报的位置在真值附近
    func testColdStartSeedsAtFirstFixAndConverges() {
        let m = builtMap()
        let sh = ShadowLocalizer(field: flatField(), walkable: nil, useRawMag: false)
        sh.enableWiFi(m, odometry: .pdr)
        XCTAssertEqual(sh.localizer.config.convergedMagWeight, WiFiColdStartProfile.magneticWeight)
        var a = Point2.zero
        var t: Int64 = 0
        var last: MagneticEstimate?
        var lastTruth = Point2.zero
        var reportedBeforeScan = false
        // 来回走两趟 y = 500，每步 20 cm、约 0.17 s；每 2 s 一次扫描
        var path: [Point2] = []
        for i in 0...170 { path.append(Point2(300 + Double(i) * 20, 500)) }
        for i in 0...170 { path.append(Point2(3700 - Double(i) * 20, 500)) }
        var nextScan: Int64 = 1000
        for p in path {
            t += 170
            a = Point2(-(p.y - 500), p.x - 300)          // 位姿坐标系 = 地图转 90°
            if t >= nextScan { sh.wifiScan(scan(at: p, t: t)); nextScan += 2000 }
            if let e = sh.pose(a: a, normal: true, tMs: t) {
                if !sh.wifiSeeded && e.converged { reportedBeforeScan = true }
                last = e; lastTruth = p
            }
        }
        XCTAssertFalse(reportedBeforeScan)
        XCTAssertTrue(sh.wifiSeeded)
        XCTAssertGreaterThan(sh.wifiFixes, 20)
        XCTAssertNotNil(last)
        XCTAssertTrue(last!.converged)
        XCTAssertLessThan(last!.position.distance(to: lastTruth), 300)
    }

    /// 第一次 Wi-Fi 定位是离群值（离真值 34 m，起点撒开的 4σ 外）：之后连续几次定位都离粒子很远 → 重新撒粒子，最后报的位置回到真值附近。
    /// 另外：Wi-Fi 冷启动不用蓝牙；换运动来源也不把钉死的地磁权重改回去。
    func testOutlierFirstFixIsReseededAndBLEIgnored() {
        let m = builtMap()
        let sh = ShadowLocalizer(field: flatField(), walkable: nil, useRawMag: false)
        sh.enableWiFi(m, odometry: .pdr)
        // 蓝牙底图：一片标签在 x = 35 m（离走的路很远），一直「听到」它；Wi-Fi 模式下不该有任何蓝牙判丢
        sh.bleMap = BLEFingerprintMap(cellCm: 200, cells: [], tags: ["far": .init(x: 3500, y: 500, maxRssi: -60, samples: 50),
                                                                      "far2": .init(x: 3600, y: 500, maxRssi: -60, samples: 50)])
        var t: Int64 = 0
        var last: MagneticEstimate?
        var lastTruth = Point2.zero
        var nextScan: Int64 = 1000
        var first = true
        // 来回走两趟 y = 500
        var path: [Point2] = []
        for i in 0...170 { path.append(Point2(300 + Double(i) * 20, 500)) }
        for i in 0...170 { path.append(Point2(3700 - Double(i) * 20, 500)) }
        for p in path {
            t += 170
            sh.bleReading(tMs: t, id: "far", rssi: -60)
            sh.bleReading(tMs: t, id: "far2", rssi: -62)
            if t >= nextScan {
                sh.wifiScan(scan(at: first ? Point2(3700, 500) : p, t: t))     // 第一次：离真值 34 m
                first = false
                nextScan += 2000
            }
            if let e = sh.pose(a: p, normal: true, tMs: t) { last = e; lastTruth = p }
        }
        XCTAssertGreaterThanOrEqual(sh.wifiReseeds, 1)
        XCTAssertEqual(sh.crossCheckResets, 0)
        XCTAssertTrue(last?.converged == true)
        XCTAssertLessThan(last!.position.distance(to: lastTruth), 300)
        sh.localizer.setOdometry(.vio)
        XCTAssertEqual(sh.localizer.config.convergedMagWeight, WiFiColdStartProfile.magneticWeight)
        // 没钉死的跟踪档：换来源照常换权重
        let tr = MagneticLocalizer(field: flatField(), config: .tracking(odometry: .pdr), seed: 1)
        tr.setOdometry(.vio)
        XCTAssertEqual(tr.config.convergedMagWeight, 0.1)
    }

    private func flatField() -> MagneticFieldMap {
        let w = 4000.0, h = 1000.0, cell = 50.0
        let n = Int(w / cell) * Int(h / cell)
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell,
                                cells: [MagneticFeature?](repeating: MagneticFeature(total: 50, vertical: 40, horizontal: 30), count: n),
                                sigmas: [MagneticFeature?](repeating: MagneticFeature(total: 1, vertical: 1, horizontal: 1), count: n))
    }
}
