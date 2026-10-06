import Foundation

/// 货架的编码把它们分成三类。这家门店的地图里并不是每个 `MapShelf` 都是实物：
///
/// - **标准货架** `Shelf-001-08`：第一段是 3 位补零的区号，1...100（个别漏补零的写成 `Shelf-26-14`、`Shelf-73-08`），
///   第二段是位置。这些才是实物货架。
/// - **虚拟货架** `Virtual-Shelf-…`（含大小写变体）：贴着标准货架画的细条，不是实物，不挡路、不反射激光。
/// - **其他**：区号大于 100（`Shelf-107-…` 组合柜 / 堆头、`Shelf-401-…` 室外）、
///   单个数字区号（`Shelf-4-1284` 价签条）等。门店方确认它们不当实物看待。
public enum ShelfKind {
    case standard
    case virtual
    case other
}

public enum ShelfClassifier {

    public static func kind(code: String) -> ShelfKind {
        let lower = code.lowercased()
        if lower.hasPrefix("virtual") { return .virtual }
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "Shelf",
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(parts[1]) else { return .other }
        guard (1...100).contains(n) else { return .other }
        // 单个数字区号（Shelf-4-1284）不是标准编码；标准的 1~9 区都补成 3 位（001...009）
        if n < 10 && parts[1].count < 3 { return .other }
        return .standard
    }
}

extension ShelfRect {
    public var kind: ShelfKind { ShelfClassifier.kind(code: code) }
}

extension StoreMap {
    /// 实物货架（只有标准货架）。给 LiDAR 测距、碰撞这类需要「真有东西」的地方用。
    public var physicalShelves: [ShelfRect] { shelves.filter { $0.kind == .standard } }

    /// 所有货架整体平移 (dx, dy) cm 后的地图。通道不动：通道是准的，货架图层整体偏了。
    public func withShelfOffset(_ d: Point2) -> StoreMap {
        guard d.x != 0 || d.y != 0 else { return self }
        var m = self
        m.shelves = shelves.map { var s = $0; s.x += d.x; s.y += d.y; return s }
        return m
    }
}
