import Foundation

/// 平面地图（cm，+x 向右、+y 向下）↔ WGS84 经纬度。
///
/// 和 `tools/venue/imdf_convert.py` 输出的 `geoRef` 同一格式，多一个旋转角 `rotationDeg`：
///
///     dx, dy = (x − marginCm) / 100, (y − marginCm) / 100        // 米
///     e = dx·cos r − dy·sin r                                     // 向东
///     s = dx·sin r + dy·cos r                                     // 向南
///     lon = lon0 + e / mPerDegLon,  lat = lat0 − s / mPerDegLat
///
/// r = rotationDeg：地图 +x 轴的方位角是 90° + r（从正北顺时针）；r = 0 时地图「上」是正北。
/// (lon0, lat0) 是地图点 (marginCm, marginCm) 的经纬度。等距圆柱近似，几百米的场馆误差厘米级。
/// Python 版 `tools/venue/georef.py`、网页版 `web/map-editor.html` 用同一套公式。
public struct GeoRef: Equatable {
    public static let earthRadius = 6378137.0
    public static let metersPerDegLat = Double.pi * earthRadius / 180

    public var lon0: Double
    public var lat0: Double
    public var marginCm: Double
    public var mPerDegLon: Double
    public var mPerDegLat: Double
    public var rotationDeg: Double

    public init(lon0: Double, lat0: Double, marginCm: Double = 0, rotationDeg: Double = 0, latRef: Double? = nil) {
        self.lon0 = lon0; self.lat0 = lat0; self.marginCm = marginCm; self.rotationDeg = rotationDeg
        mPerDegLat = Self.metersPerDegLat
        mPerDegLon = Self.metersPerDegLat * cos((latRef ?? lat0) * Double.pi / 180)
    }

    public init?(dict: [String: Any]?) {
        func n(_ k: String) -> Double? {
            if let v = dict?[k] as? Double { return v }
            if let v = dict?[k] as? NSNumber { return v.doubleValue }
            if let v = dict?[k] as? Int { return Double(v) }
            return nil
        }
        guard let lon0 = n("lon0"), let lat0 = n("lat0"), let mlon = n("mPerDegLon"), let mlat = n("mPerDegLat"),
              mlon > 0, mlat > 0 else { return nil }
        self.lon0 = lon0; self.lat0 = lat0; mPerDegLon = mlon; mPerDegLat = mlat
        marginCm = n("marginCm") ?? 0
        rotationDeg = n("rotationDeg") ?? 0
    }

    public var dict: [String: Any] {
        ["lon0": lon0, "lat0": lat0, "marginCm": marginCm, "mPerDegLon": mPerDegLon, "mPerDegLat": mPerDegLat,
         "rotationDeg": rotationDeg]
    }

    public func toLonLat(_ p: Point2) -> (lon: Double, lat: Double) {
        let r = rotationDeg * Double.pi / 180
        let dx = (p.x - marginCm) / 100, dy = (p.y - marginCm) / 100
        let e = dx * cos(r) - dy * sin(r)
        let s = dx * sin(r) + dy * cos(r)
        return (lon0 + e / mPerDegLon, lat0 - s / mPerDegLat)
    }

    public func toMap(lon: Double, lat: Double) -> Point2 {
        let r = rotationDeg * Double.pi / 180
        let e = (lon - lon0) * mPerDegLon
        let s = (lat0 - lat) * mPerDegLat
        let dx = e * cos(r) + s * sin(r)
        let dy = -e * sin(r) + s * cos(r)
        return Point2(dx * 100 + marginCm, dy * 100 + marginCm)
    }

    static func wrapDeg(_ d: Double) -> Double {
        var d = d
        while d <= -180 { d += 360 }
        while d > 180 { d -= 360 }
        return d
    }

    /// 入口处记一次 GPS + 真北朝向，算出 geoRef。
    /// - Parameters:
    ///   - mapPoint: 记录时手机在地图上的位置（cm）
    ///   - trueHeadingDeg: 手机朝向的方位角（CLHeading.trueHeading，从正北顺时针）
    ///   - mapDirectionDeg: 同一时刻手机朝向在地图里的方向角 atan2(dy, dx)（度，y 向下）
    public static func fromAnchor(mapPoint: Point2, lon: Double, lat: Double, trueHeadingDeg: Double,
                                  mapDirectionDeg: Double, marginCm: Double) -> GeoRef {
        var g = GeoRef(lon0: 0, lat0: 0, marginCm: marginCm,
                       rotationDeg: wrapDeg(trueHeadingDeg - 90 - mapDirectionDeg), latRef: lat)
        let base = g.toLonLat(mapPoint)
        g.lon0 = lon - base.lon
        g.lat0 = lat - base.lat
        return g
    }

    /// 两点对准：地图点 p1、p2（cm）分别对应经纬度 ll1、ll2。只解旋转 + 平移；
    /// 返回的 scale = 经纬度距离 / 地图距离，偏离 1 太多说明点选错了。两点重合返回 nil。
    public static func fromTwoPoints(_ p1: Point2, _ ll1: (lon: Double, lat: Double),
                                     _ p2: Point2, _ ll2: (lon: Double, lat: Double),
                                     marginCm: Double) -> (geoRef: GeoRef, scale: Double)? {
        var g = GeoRef(lon0: 0, lat0: 0, marginCm: marginCm, latRef: (ll1.lat + ll2.lat) / 2)
        let e = (ll2.lon - ll1.lon) * g.mPerDegLon
        let s = (ll1.lat - ll2.lat) * g.mPerDegLat
        let mx = (p2.x - p1.x) / 100, my = (p2.y - p1.y) / 100
        let dm = hypot(mx, my)
        guard dm > 1e-6 else { return nil }
        g.rotationDeg = wrapDeg((atan2(s, e) - atan2(my, mx)) * 180 / Double.pi)
        let base = g.toLonLat(p1)
        g.lon0 = ll1.lon - base.lon
        g.lat0 = ll1.lat - base.lat
        return (g, hypot(e, s) / dm)
    }
}
