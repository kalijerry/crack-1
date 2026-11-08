// 过渡用：App 改用新名字后删除。

import Foundation

public typealias EslLocation = TagLocation
public typealias EslLocations = TagLocations
public typealias EslItem = TagItem
public typealias EslTrajectoryCorrector = TagTrajectoryCorrector

extension StoreDataLoader {
    public static func eslToShelf(_ items: [TagItem]) -> [String: String] {
        tagToShelf(items)
    }
}

extension FingerprintPositioner {
    public convenience init(points: [FingerprintPoint], eslToShelf: [String: String], config: PositioningConfig = .init()) {
        self.init(points: points, tagToShelf: eslToShelf, config: config)
    }
}

extension RSSICalibrator {
    public static func fit(readingsByPoint: [String: [BLEReading]], points: [FingerprintPoint],
                           eslToShelf: [String: String], fitScale: Bool = false) -> RSSICalibration {
        fit(readingsByPoint: readingsByPoint, points: points, tagToShelf: eslToShelf, fitScale: fitScale)
    }

    public static func fitBlind(readings: [BLEReading], points: [FingerprintPoint],
                                eslToShelf: [String: String], windowMs: Int64 = 1500) -> RSSICalibration {
        fitBlind(readings: readings, points: points, tagToShelf: eslToShelf, windowMs: windowMs)
    }
}

extension MapPackage.Contents {
    public var eslCSV: Data? {
        get { tagCSV }
        set { tagCSV = newValue }
    }
}
