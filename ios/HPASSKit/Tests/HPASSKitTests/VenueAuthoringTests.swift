import Foundation
import XCTest
@testable import HPASSKit

/// RoomPlan 扫描 → 场馆地图 → IMDF：多房间单元、类别 / 名字、geoRef、楼层、导出。
///
/// 合成一栋两层小楼（和 tools/tests/test_imdf_export.py 同一套平面，米，+x 东、+y 南，原点西北角）：
///     会议室 (0,0)-(8,4)  卫生间 (8,0)-(12,4)  电梯 (14,0)-(16,2)  库房（非公共）(16,0)-(20,4)  走廊 (0,4)-(20,7)
/// 可走 = 32 + 16 + 4 + 60 = 112 m²。两层分别扫描：每层的 ARKit 世界系朝向、原点都不一样（像真的分两次扫）。
final class VenueAuthoringTests: XCTestCase {
    static let lonW = 121.4737, latN = 31.2304
    static let mLat = GeoRef.metersPerDegLat
    static var mLon: Double { mLat * cos(latN * Double.pi / 180) }

    /// 楼里的点（米）→ 经纬度
    static func ll(_ w: Point2) -> (lon: Double, lat: Double) { (lonW + w.x / mLon, latN - w.y / mLat) }

    /// 一次扫描的 ARKit 世界系：+x 轴的方位角 beta（度），原点在楼里的 origin（米）
    struct ARFrame {
        var beta: Double
        var origin: Point2
        var xAxis: Point2 { let b = beta * Double.pi / 180; return Point2(sin(b), -cos(b)) }
        var zAxis: Point2 { let b = beta * Double.pi / 180; return Point2(cos(b), sin(b)) }
        func ar(_ w: Point2) -> Point2 {
            let d = w - origin
            return Point2(d.x * xAxis.x + d.y * xAxis.y, d.x * zAxis.x + d.y * zAxis.y)
        }
        /// 楼里的方向 → ARKit (x, z) 平面里的 yaw
        func yaw(_ d: Point2) -> Double { atan2(d.x * zAxis.x + d.y * zAxis.y, d.x * xAxis.x + d.y * xAxis.y) }
    }

    static let rooms: [(id: String, cat: String, rect: (Double, Double, Double, Double))] = [
        ("office", "room", (0, 0, 8, 4)), ("wc", "restroom", (8, 0, 12, 4)), ("lift", "elevator", (14, 0, 16, 2)),
        ("store", "nonpublic", (16, 0, 20, 4)), ("hall", "walkway", (0, 4, 20, 7)),
    ]

    static func input(_ f: ARFrame, ordinal: Int, names: [String: String], withGeo: Bool = true) -> RoomMapBuilder.Input {
        var inp = RoomMapBuilder.Input()
        func wall(_ a: Point2, _ b: Point2) -> RoomMapBuilder.Item {
            .init(category: "wall", center: f.ar((a + b) * 0.5), width: a.distance(to: b), depth: 0, height: 2.8, yaw: f.yaw(b - a))
        }
        inp.walls = [wall(Point2(0, 0), Point2(20, 0)), wall(Point2(20, 0), Point2(20, 7)),
                     wall(Point2(20, 7), Point2(0, 7)), wall(Point2(0, 7), Point2(0, 0))]
        inp.doors = [.init(category: "door", center: f.ar(Point2(3.5, 4)), width: 1, depth: 0, height: 2.1, yaw: f.yaw(Point2(1, 0)))]
        inp.objects = [.init(category: "table", center: f.ar(Point2(3, 1.5)), width: 2, depth: 1, height: 0.75, yaw: f.yaw(Point2(1, 0)))]
        inp.rooms = Self.rooms.map { r -> RoomMapBuilder.Room in
            let (x0, y0, x1, y1) = r.rect
            let poly: [Point2] = [Point2(x0, y0), Point2(x1, y0), Point2(x1, y1), Point2(x0, y1)].map { f.ar($0) }
            return RoomMapBuilder.Room(id: r.id, floor: poly, category: r.cat, name: names[r.id])
        }
        inp.ordinal = ordinal
        inp.venueId = "V1"
        inp.venueName = "合成办公楼"
        if withGeo {
            // 入口在走廊 (1, 6)，手机朝正东（方位角 90°）
            let p = Point2(1, 6), g = ll(p)
            inp.geoAnchor = .init(arPosition: f.ar(p), arYaw: f.yaw(Point2(1, 0)), lon: g.lon, lat: g.lat, trueHeadingDeg: 90)
        }
        return inp
    }

    static func level(_ f: ARFrame, ordinal: Int, names: [String: String]) throws -> [String: Any] {
        let (json, _) = try RoomMapBuilder.build(input(f, ordinal: ordinal, names: names), name: "\(ordinal + 1)F")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    static let frame0 = ARFrame(beta: 70, origin: Point2(5, 5))
    static let frame1 = ARFrame(beta: -130, origin: Point2(12, 2))

    func testMultiRoomUnitsWalkableAndConnectors() throws {
        let inp = Self.input(Self.frame0, ordinal: 0, names: ["office": "会议室 A", "lift": "1 号电梯"])
        let (json, map) = try RoomMapBuilder.build(inp, name: "1F")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual((root["units"] as? [Any])?.count, 5)
        XCTAssertEqual((root["floorPolygons"] as? [Any])?.count, 4)       // 库房不可走
        XCTAssertEqual((root["obstaclePolygons"] as? [Any])?.count, 1)
        XCTAssertEqual(root["ordinal"] as? Int, 0)
        XCTAssertEqual(root["venueId"] as? String, "V1")
        let conns = try XCTUnwrap(root["connectors"] as? [[String: Any]])
        XCTAssertEqual(conns.count, 1)
        XCTAssertEqual(conns[0]["category"] as? String, "elevator")
        let els = try XCTUnwrap(root["mapElementList"] as? [[String: Any]])
        let labels = els.filter { $0["shapeType"] as? String == "MapLabel" }.compactMap { $0["text"] as? String }
        XCTAssertEqual(Set(labels), ["会议室 A", "1 号电梯"])
        XCTAssertEqual(els.filter { $0["shapeType"] as? String == "MapConnector" }.count, 1)
        // 加载后：可走区域 = 4 个单元，112 m²（墙是外墙，没有家具以外的障碍；家具放宽后扣掉一些）
        XCTAssertEqual(map.floor.count, 4)
        let area = map.floor.reduce(0) { $0 + abs(IMDFExporter.signedArea($1)) } / 1e4
        XCTAssertEqual(area, 112, accuracy: 0.2)
        // 转正之后墙横平竖直，地图 20 m × 7 m + 留白
        XCTAssertEqual(max(map.width, map.height), 2000 + 10 + 200, accuracy: 3)
        XCTAssertEqual(min(map.width, map.height), 700 + 10 + 200, accuracy: 3)
    }

    func testSingleRoomStillGetsAUnit() throws {
        var inp = RoomMapBuilder.Input()
        inp.walls = [
            .init(category: "wall", center: Point2(2, 0), width: 4, depth: 0, height: 2.6, yaw: 0),
            .init(category: "wall", center: Point2(2, 3), width: 4, depth: 0, height: 2.6, yaw: .pi),
            .init(category: "wall", center: Point2(0, 1.5), width: 3, depth: 0, height: 2.6, yaw: .pi / 2),
            .init(category: "wall", center: Point2(4, 1.5), width: 3, depth: 0, height: 2.6, yaw: -.pi / 2),
        ]
        let (json, map) = try RoomMapBuilder.build(inp, name: "单间")
        let units = RoomMapBuilder.units(json)
        XCTAssertEqual(units.map(\.id), ["R1"])
        XCTAssertEqual(units[0].category, "room")
        XCTAssertEqual(map.floor.count, 1)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNil(root["geoRef"])
    }

    func testRelabelUpdatesDerivedFields() throws {
        let (json, _) = try RoomMapBuilder.build(Self.input(Self.frame0, ordinal: 0, names: [:]), name: "1F")
        var j = try RoomMapBuilder.relabel(json, unitId: "hall", name: "  东走廊 ")
        j = try RoomMapBuilder.relabel(j, unitId: "office", category: "stairs")
        j = try RoomMapBuilder.relabel(j, unitId: "wc", category: "nonpublic")
        let units = Dictionary(uniqueKeysWithValues: RoomMapBuilder.units(j).map { ($0.id, $0) })
        XCTAssertEqual(units["hall"]?.name, "东走廊")
        XCTAssertEqual(units["office"]?.category, "stairs")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: j) as? [String: Any])
        XCTAssertEqual((root["floorPolygons"] as? [Any])?.count, 3)
        XCTAssertEqual((root["obstaclePolygons"] as? [Any])?.count, 2)
        let cats = (root["connectors"] as? [[String: Any]] ?? []).compactMap { $0["category"] as? String }.sorted()
        XCTAssertEqual(cats, ["elevator", "stairs"])
        // 名字删掉
        j = try RoomMapBuilder.relabel(j, unitId: "hall", name: "")
        XCTAssertNil(RoomMapBuilder.units(j).first { $0.id == "hall" }?.name)
        // 改楼层序号：连接体跟着改
        j = try RoomMapBuilder.update(j) { $0["ordinal"] = 3 }
        let r2 = try XCTUnwrap(try JSONSerialization.jsonObject(with: j) as? [String: Any])
        XCTAssertEqual((r2["connectors"] as? [[String: Any]])?.first?["ordinal"] as? Int, 3)
        // 点选：点在会议室中心 → 会议室
        let office = try XCTUnwrap(units["office"])
        XCTAssertTrue(RoomMapBuilder.polygonContains(office.polygon, RoomMapBuilder.polygonCentroid(office.polygon)))
        XCTAssertFalse(RoomMapBuilder.polygonContains(office.polygon, Point2(-1e5, -1e5)))
    }

    func testGeoRefConventions() {
        var g = GeoRef(lon0: 120, lat0: 30, marginCm: 100)
        var p = g.toLonLat(Point2(1100, 100))                          // 地图 +x 10 m → 正东
        XCTAssertEqual((p.lon - 120) * g.mPerDegLon, 10, accuracy: 1e-6)
        XCTAssertEqual(p.lat, 30, accuracy: 1e-9)
        g.rotationDeg = 90                                              // 地图 +x → 正南
        p = g.toLonLat(Point2(1100, 100))
        XCTAssertEqual((30 - p.lat) * g.mPerDegLat, 10, accuracy: 1e-6)
        g.rotationDeg = 33
        let q = g.toMap(lon: g.toLonLat(Point2(523.4, -77)).lon, lat: g.toLonLat(Point2(523.4, -77)).lat)
        XCTAssertEqual(q.x, 523.4, accuracy: 1e-4)
        XCTAssertEqual(q.y, -77, accuracy: 1e-4)
        XCTAssertEqual(GeoRef(dict: g.dict), g)
        XCTAssertNil(GeoRef(dict: ["lon0": 1]))
    }

    func testTwoPointAlign() throws {
        let truth = GeoRef(lon0: 121.47, lat0: 31.23, marginCm: 100, rotationDeg: -40)
        let a = Point2(300, 400), b = Point2(2500, 1300)
        let (g, scale) = try XCTUnwrap(GeoRef.fromTwoPoints(a, truth.toLonLat(a), b, truth.toLonLat(b), marginCm: 100))
        XCTAssertEqual(scale, 1, accuracy: 1e-4)
        XCTAssertEqual(g.rotationDeg, -40, accuracy: 1e-3)
        let c = Point2(1234, 567), u = g.toLonLat(c), v = truth.toLonLat(c)
        XCTAssertLessThan(hypot((u.lon - v.lon) * g.mPerDegLon, (u.lat - v.lat) * g.mPerDegLat), 0.01)
        XCTAssertNil(GeoRef.fromTwoPoints(a, truth.toLonLat(a), a, truth.toLonLat(b), marginCm: 0))
    }

    /// 入口记的 GPS + 朝向：地图上任何一点换回经纬度，都应该落在楼里的真实位置（< 2 cm）
    func testGeoAnchorPutsScanOnTheGlobe() throws {
        for f in [Self.frame0, Self.frame1] {
            let doc = try Self.level(f, ordinal: 0, names: [:])
            let g = try XCTUnwrap(GeoRef(dict: doc["geoRef"] as? [String: Any]))
            let align = try XCTUnwrap(try StoreDataLoader.loadMap(JSONSerialization.data(withJSONObject: doc)).arAlign)
            for w in [Point2(0, 0), Point2(20, 7), Point2(15, 1)] {
                let a = f.ar(w)
                let m = align.toMap(Point2(a.x * 100, a.y * 100))
                let got = g.toLonLat(m), want = Self.ll(w)
                XCTAssertLessThan(hypot((got.lon - want.lon) * Self.mLon, (got.lat - want.lat) * Self.mLat), 0.02, "\(f.beta) \(w)")
            }
        }
    }

    func testUUID5MatchesPython() {
        // python: uuid.uuid5(uuid.NAMESPACE_DNS, "python.org")
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(IMDFExporter.uuid5(dns, "python.org"), "886313e1-3b8a-5372-9b90-0c9aee199e5d")
    }

    func twoLevels() throws -> [[String: Any]] {
        [try Self.level(Self.frame0, ordinal: 0, names: ["office": "会议室 A", "wc": "卫生间", "lift": "1 号电梯"]),
         try Self.level(Self.frame1, ordinal: 1, names: ["office": "研发部"])]
    }

    func testExportFeatures() throws {
        let feats = try IMDFExporter.features(try twoLevels())
        XCTAssertEqual(feats["level"]?.count, 2)
        XCTAssertEqual(feats["unit"]?.count, 10)
        XCTAssertEqual(feats["opening"]?.count, 2)
        XCTAssertEqual(feats["fixture"]?.count, 2)
        XCTAssertEqual(feats["anchor"]?.count, 10)
        XCTAssertEqual(feats["occupant"]?.count, 2)            // 会议室 A、研发部（room 类别）
        XCTAssertEqual(feats["venue"]?.count, 1)
        XCTAssertEqual(feats["footprint"]?.count, 1)
        XCTAssertEqual(feats["building"]?.count, 1)
        let ordinals = (feats["level"] ?? []).compactMap { ($0["properties"] as? [String: Any])?["ordinal"] as? Int }
        XCTAssertEqual(ordinals.sorted(), [0, 1])
        for k in ["unit", "level", "venue", "footprint", "fixture"] {
            for f in feats[k] ?? [] {
                XCTAssertEqual(f["feature_type"] as? String, k)
                XCTAssertNotNil(UUID(uuidString: f["id"] as? String ?? ""))
                let ring = try XCTUnwrap(((f["geometry"] as? [String: Any])?["coordinates"] as? [[[Double]]])?.first)
                XCTAssertEqual(ring.first, ring.last)
                XCTAssertGreaterThan(IMDFExporter.signedArea(ring.dropLast().map { Point2($0[0], $0[1]) }), 0, "外环要逆时针")
            }
        }
        // 两层分别扫描，电梯在经纬度上应该重合（< 5 cm）
        let lifts = (feats["unit"] ?? []).filter { ($0["properties"] as? [String: Any])?["category"] as? String == "elevator" }
        XCTAssertEqual(lifts.count, 2)
        let pts = lifts.compactMap { (($0["properties"] as? [String: Any])?["display_point"] as? [String: Any])?["coordinates"] as? [Double] }
        XCTAssertEqual(pts.count, 2)
        XCTAssertLessThan(hypot((pts[0][0] - pts[1][0]) * Self.mLon, (pts[0][1] - pts[1][1]) * Self.mLat), 0.05)
        // 没有 geoRef 的楼层：明确报错
        var noGeo = try twoLevels()
        noGeo[1].removeValue(forKey: "geoRef")
        XCTAssertThrowsError(try IMDFExporter.features(noGeo))
    }

    /// 读回自己写的 zip：中央目录、CRC、文件名
    func testZipArchiveIsReadable() throws {
        let zip = try IMDFExporter.archive(try twoLevels())
        let entries = try Self.readZip(zip)
        XCTAssertEqual(Set(entries.keys), Set(["manifest.json"] + IMDFExporter.featureFiles.map { "\($0).geojson" }))
        let unit = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(entries["unit.geojson"])) as? [String: Any])
        XCTAssertEqual((unit["features"] as? [Any])?.count, 10)
        let man = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(entries["manifest.json"])) as? [String: Any])
        XCTAssertEqual(man["version"] as? String, "1.0.0")
    }

    /// 用 Python 的 imdf_convert 读 Swift 导出的 IMDF（macOS 上有 python3 时）：两边对得上
    func testPythonImdfConvertReadsSwiftExport() throws {
        #if os(macOS)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("tools/venue/imdf_convert.py")
        guard FileManager.default.fileExists(atPath: script.path) else { throw XCTSkip("找不到 \(script.path)") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("imdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zipURL = tmp.appendingPathComponent("venue.zip")
        try IMDFExporter.archive(try twoLevels()).write(to: zipURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, zipURL.path, tmp.appendingPathComponent("out").path]
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw XCTSkip("没有 python3：\(error)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("python3 imdf_convert 运行失败（\(p.terminationStatus)）") }
        let venue = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: tmp.appendingPathComponent("out/venue.json"))) as? [String: Any])
        let levels = try XCTUnwrap(venue["levels"] as? [[String: Any]])
        XCTAssertEqual(levels.compactMap { $0["ordinal"] as? Int }, [0, 1])
        for lv in levels {
            XCTAssertEqual((lv["walkableM2"] as? NSNumber)?.doubleValue ?? 0, 112, accuracy: 0.3)
            XCTAssertEqual(lv["openings"] as? Int, 1)
            XCTAssertEqual(lv["connectors"] as? Int, 1)
        }
        let groups = try XCTUnwrap(venue["connectorGroups"] as? [[String: Any]])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?["category"] as? String, "elevator")
        #else
        throw XCTSkip("只在 macOS 上跑")
        #endif
    }

    /// 极简 zip 读取（只认「存储」方式）：校验每个文件的 CRC
    static func readZip(_ d: Data) throws -> [String: Data] {
        let b = [UInt8](d)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard b.count >= 22, let eocd = stride(from: b.count - 22, through: 0, by: -1).first(where: { u32($0) == 0x0605_4B50 }) else {
            throw StoreDataError.unsupportedFormat("没有 zip 结尾记录")
        }
        let n = u16(eocd + 10)
        var p = u32(eocd + 16)
        var out: [String: Data] = [:]
        for _ in 0..<n {
            guard u32(p) == 0x0201_4B50 else { throw StoreDataError.unsupportedFormat("中央目录坏了") }
            let crc = UInt32(u32(p + 16)), size = u32(p + 20), nameLen = u16(p + 28)
            let extra = u16(p + 30), comment = u16(p + 32), local = u32(p + 42)
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            guard u32(local) == 0x0403_4B50 else { throw StoreDataError.unsupportedFormat("本地头坏了") }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let data = Data(b[start..<(start + size)])
            guard ZipWriter.crc32(data) == crc else { throw StoreDataError.unsupportedFormat("\(name) CRC 不对") }
            out[name] = data
            p += 46 + nameLen + extra + comment
        }
        return out
    }
}
