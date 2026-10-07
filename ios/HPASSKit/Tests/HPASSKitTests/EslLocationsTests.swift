import Foundation
import XCTest
@testable import HPASSKit

final class EslLocationsTests: XCTestCase {
    func testParseAndSeed() {
        let map = StoreMap(width: 5000, height: 3000, shelves: [
            ShelfRect(code: "Shelf-002-07", x: 1000, y: 500, width: 120, height: 60, rotation: 0),
            ShelfRect(code: "Shelf-26-14", x: 2000, y: 800, width: 120, height: 60, rotation: 0),
        ], crosses: [])
        let csv = "\u{FEFF}ESL_ID,位置 configuredPlanogramName,Aisle,Bay,Shelf,ShelfSeq,商品条码 productCode,货架图 planoName\r\n"
            + "88-A7-20-91,A002 - 07 - LM - 1023,A002,07,LM,1023,5011914204953,PET CARE\r\n"
            + "88-A9-D9-91,,,,,,5059340722313,\r\n"
            + "9B-00-00-91,A026 - 14 - LM - 1,A026,14,LM,1,123,\"PAINT, WHITE\"\r\n"
        let locs = EslLocations.parse(csv, map: map)
        XCTAssertEqual(locs.count, 3)
        XCTAssertEqual(locs[0].shelfCode, "Shelf-002-07")
        XCTAssertEqual(locs[0].position?.x, 1000)
        XCTAssertNil(locs[1].position)
        XCTAssertEqual(locs[2].shelfCode, "Shelf-26-14")          // 漏补零的地图编号
        XCTAssertEqual(locs[2].plano, "PAINT, WHITE")
        // 底图：表优先；学到的和表差得远（且读数够）才替换；表里没有的用学到的
        let learned = BLEFingerprintMap(cellCm: 200, cells: [], tags: [
            "88-A7-20-91": .init(x: 1200, y: 500, maxRssi: -60, samples: 30),     // 差 2 m：还用表
            "9B-00-00-91": .init(x: 4000, y: 2500, maxRssi: -60, samples: 30),    // 差 > 10 m：用学到的
            "FF-FF-FF-FF": .init(x: 10, y: 10, maxRssi: -60, samples: 3),
        ])
        let m = EslLocations.seededBLEMap(locs, learned: learned)
        XCTAssertEqual(m.tags["88-A7-20-91"]?.x, 1000)
        XCTAssertEqual(m.tags["9B-00-00-91"]?.x, 4000)
        XCTAssertNotNil(m.tags["FF-FF-FF-FF"])
        XCTAssertEqual(EslLocations.mismatches(locs, learned: learned).map(\.id), ["9B-00-00-91"])
    }
}
