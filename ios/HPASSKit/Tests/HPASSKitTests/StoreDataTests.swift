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
}
