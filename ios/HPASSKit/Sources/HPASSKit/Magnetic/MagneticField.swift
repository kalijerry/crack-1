import Foundation

/// 手动定的点位（地图 JSON 的 `markPoints`），单位 cm。
public struct MarkPoint: Hashable {
    public var id: String
    public var x: Double
    public var y: Double

    public init(id: String, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }

    public var position: Point2 { Point2(x, y) }
}

/// 网格化的地磁场地图：每格存三个特征的均值和标准差。坐标系与门店地图一致（cm，y 向下）。
///
/// JSON 里挂在地图根节点的 `magField` 下，由 `tools/magmap.py` 生成：
/// `{ "cellCm": 50, "cols": 20, "rows": 20, "cells": [[|B|,Bz,Bh] | null, …], "sigma": [[…] | null, …] }`
/// 数组按行优先，下标 = row * cols + col。
public struct MagneticFieldMap {
    public let widthCm: Double
    public let heightCm: Double
    public let cellCm: Double
    public let cols: Int
    public let rows: Int
    let cells: [MagneticFeature?]
    let sigmas: [MagneticFeature?]

    public init(widthCm: Double, heightCm: Double, cellCm: Double,
                cells: [MagneticFeature?], sigmas: [MagneticFeature?]) {
        precondition(cellCm > 0 && widthCm > 0 && heightCm > 0)
        self.widthCm = widthCm
        self.heightCm = heightCm
        self.cellCm = cellCm
        self.cols = Int((widthCm / cellCm).rounded(.up))
        self.rows = Int((heightCm / cellCm).rounded(.up))
        precondition(cells.count == cols * rows && sigmas.count == cols * rows,
                     "magField 的格子数与 cols×rows 不一致")
        self.cells = cells
        self.sigmas = sigmas
    }

    /// 有数据的格子数。
    public var coveredCells: Int { cells.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
    public var totalCells: Int { cols * rows }

    public func contains(_ p: Point2) -> Bool {
        p.x >= 0 && p.x <= widthCm && p.y >= 0 && p.y <= heightCm
    }

    /// 在 p 处做双线性插值（以格子中心为采样点）。周围有效格子的权重不足 0.25 时返回 nil。
    public func sample(at p: Point2) -> (mean: MagneticFeature, sigma: MagneticFeature)? {
        guard contains(p) else { return nil }
        let fx = p.x / cellCm - 0.5
        let fy = p.y / cellCm - 0.5
        let i0 = Int(fx.rounded(.down)), j0 = Int(fy.rounded(.down))
        let tx = fx - Double(i0), ty = fy - Double(j0)

        var wsum = 0.0
        var mean = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
        var sig = MagneticFeature(total: 0, vertical: 0, horizontal: 0)
        for (di, wx) in [(0, 1 - tx), (1, tx)] {
            for (dj, wy) in [(0, 1 - ty), (1, ty)] {
                let w = wx * wy
                guard w > 0 else { continue }
                let i = min(max(i0 + di, 0), cols - 1)
                let j = min(max(j0 + dj, 0), rows - 1)
                let k = j * cols + i
                guard let m = cells[k], let s = sigmas[k] else { continue }
                mean = mean + m * w
                sig = sig + s * w
                wsum += w
            }
        }
        guard wsum >= 0.25 else { return nil }
        return (mean * (1 / wsum), sig * (1 / wsum))
    }
}

// MARK: - 解析

extension StoreDataLoader {

    /// 从地图 JSON 读地磁场。没有 `magField` 返回 nil；有但格式不对则抛错。
    public static func loadMagneticField(_ data: Data) throws -> MagneticFieldMap? {
        guard let root = try unwrap(data) as? [String: Any] else {
            throw StoreDataError.unsupportedFormat("地图根节点不是对象")
        }
        guard let mf = root["magField"] as? [String: Any] else { return nil }
        guard let w = num(root["width"]), let h = num(root["height"]), w > 0, h > 0 else {
            throw StoreDataError.unsupportedFormat("地图缺少 width / height")
        }
        guard let cell = num(mf["cellCm"]), cell > 0 else {
            throw StoreDataError.unsupportedFormat("magField 缺少 cellCm")
        }
        func feats(_ key: String) throws -> [MagneticFeature?] {
            guard let arr = mf[key] as? [Any] else {
                throw StoreDataError.unsupportedFormat("magField 缺少 \(key) 数组")
            }
            return try arr.map { item -> MagneticFeature? in
                if item is NSNull { return nil }
                guard let v = item as? [Any], v.count == 3,
                      let a = num(v[0]), let b = num(v[1]), let c = num(v[2]) else {
                    throw StoreDataError.unsupportedFormat("magField.\(key) 的元素必须是 [|B|, Bz, Bh] 或 null")
                }
                return MagneticFeature(total: a, vertical: b, horizontal: c)
            }
        }
        let cells = try feats("cells")
        let sigmas = try feats("sigma")
        let cols = Int((w / cell).rounded(.up)), rows = Int((h / cell).rounded(.up))
        guard cells.count == cols * rows, sigmas.count == cols * rows else {
            throw StoreDataError.unsupportedFormat("magField 格子数 \(cells.count) 与 \(cols)×\(rows) 不一致")
        }
        return MagneticFieldMap(widthCm: w, heightCm: h, cellCm: cell, cells: cells, sigmas: sigmas)
    }

    /// 从地图 JSON 读手动定的点位（`markPoints`）。没有就返回空数组。
    public static func loadMarkPoints(_ data: Data) throws -> [MarkPoint] {
        guard let root = try unwrap(data) as? [String: Any] else {
            throw StoreDataError.unsupportedFormat("地图根节点不是对象")
        }
        let list = root["markPoints"] as? [[String: Any]] ?? []
        return list.compactMap { e in
            guard let id = e["id"].map({ str($0) }), let x = num(e["x"]), let y = num(e["y"]) else { return nil }
            return MarkPoint(id: id, x: x, y: y)
        }
    }
}
