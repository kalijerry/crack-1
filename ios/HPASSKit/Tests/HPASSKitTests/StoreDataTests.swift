import XCTest
@testable import HPASSKit

final class StoreDataTests: XCTestCase {

    private let inner: [String: Any] = [
        "width": 1000, "height": 500, "floorId": 7,
        "mapElementList": [
            ["shapeType": "MapShelf", "code": "S-1", "x": 100, "y": 100, "width": 200, "height": 40, "rotation": 90],
            ["shapeType": "MapCross", "code": "C-1", "points": [0, 50, 900, 50], "lineWidth": 140],
        ],
    ]

    /// 服务端统一信封 { code, message, success, data: {...} }。
    func testMapInsideServerEnvelope() throws {
        let envelope: [String: Any] = ["code": "200", "message": "success", "success": true, "data": inner]
        let map = try StoreDataLoader.loadMap(JSONSerialization.data(withJSONObject: envelope))
        XCTAssertEqual(map.width, 1000)
        XCTAssertEqual(map.shelves.count, 1)
        XCTAssertEqual(map.crosses.count, 1)
        XCTAssertEqual(map.floorId, 7)
    }

    /// data 字段本身又是一层 JSON 字符串。
    func testMapEnvelopeWithStringData() throws {
        let innerText = String(data: try JSONSerialization.data(withJSONObject: inner), encoding: .utf8)!
        let envelope: [String: Any] = ["code": "200", "success": true, "data": innerText]
        let map = try StoreDataLoader.loadMap(JSONSerialization.data(withJSONObject: envelope))
        XCTAssertEqual(map.shelves.count, 1)
    }

    /// 没有信封的普通地图不受影响；地图里自带的 data 字段（不带 success/code/message）也不会被误拆。
    func testPlainMapStillWorks() throws {
        var plain = inner
        plain["data"] = ["unrelated": 1]
        let map = try StoreDataLoader.loadMap(JSONSerialization.data(withJSONObject: plain))
        XCTAssertEqual(map.width, 1000)
        XCTAssertEqual(map.crosses.count, 1)
    }

    /// 货架的 (x, y) 是左上角，旋转绕左上角：90° 的货架应当朝下长出去，而不是以 (x, y) 为中心。
    func testShelfAnchorIsTopLeftRotatedAboutCorner() throws {
        let map = try StoreDataLoader.loadMap(JSONSerialization.data(withJSONObject: inner))
        let s = try XCTUnwrap(map.shelves.first)
        // 宽 200、高 40、旋转 90°：u = (0, 1)，v = (−1, 0)；中心 = (100, 100) + u·100 + v·20 = (80, 200)
        XCTAssertEqual(s.x, 80, accuracy: 1e-6)
        XCTAssertEqual(s.y, 200, accuracy: 1e-6)
        XCTAssertEqual(s.rotation, 90)
        let legacy = try StoreDataLoader.loadMap(JSONSerialization.data(withJSONObject: inner), rectAnchor: .center)
        XCTAssertEqual(legacy.shelves[0].x, 100, accuracy: 1e-6)
    }

    /// 圆和路点是中心，不能被当成左上角平移；桌台、方块按左上角。
    func testOtherElementsAnchors() throws {
        var m = inner
        m["mapElementList"] = [
            ["shapeType": "Circle", "x": 500, "y": 500, "width": 120, "height": 120, "rotation": 0],
            ["shapeType": "MapTableFeature", "x": 300, "y": 300, "width": 100, "height": 20, "rotation": 0],
        ]
        let map = try StoreDataLoader.loadMap(JSONSerialization.data(withJSONObject: m))
        let circle = try XCTUnwrap(map.others.first { $0.shapeType == "Circle" })
        let table = try XCTUnwrap(map.others.first { $0.shapeType == "MapTableFeature" })
        XCTAssertEqual(circle.x, 500, accuracy: 1e-6)
        XCTAssertEqual(table.x, 350, accuracy: 1e-6)
        XCTAssertEqual(table.y, 310, accuracy: 1e-6)
    }
}
