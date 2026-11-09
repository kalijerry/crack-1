import Foundation

/// 磁力计硬铁偏置的球面拟合：手机转过足够多的朝向时，原始读数落在以偏置为球心、|B| 为半径的球面上。
///
/// App 定位用不含磁力计的姿态参考系（`.xArbitraryZVertical`）时拿不到 iOS 校准后磁场，又没有本机偏置存档，
/// 就用它在线估偏置。室内 |B| 随位置变，球面只是近似：调用方要检查朝向覆盖、半径和残差再用。
public enum HardIronFit {
    /// 最小二乘球面拟合：|v − c|² = R²  ⇔  x² + y² + z² = 2c·v + (R² − |c|²)，对 (cx, cy, cz, k) 线性。
    public static func sphere(_ pts: [(Double, Double, Double)]) -> (center: (Double, Double, Double), radius: Double, rms: Double)? {
        guard pts.count >= 10 else { return nil }
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var atb = [Double](repeating: 0, count: 4)
        for p in pts {
            let row = [2 * p.0, 2 * p.1, 2 * p.2, 1]
            let y = p.0 * p.0 + p.1 * p.1 + p.2 * p.2
            for i in 0..<4 {
                atb[i] += row[i] * y
                for j in 0..<4 { ata[i][j] += row[i] * row[j] }
            }
        }
        guard let x = solve4(ata, atb) else { return nil }
        let c = (x[0], x[1], x[2])
        let r2 = x[3] + c.0 * c.0 + c.1 * c.1 + c.2 * c.2
        guard r2 > 0 else { return nil }
        let r = r2.squareRoot()
        var se = 0.0
        for p in pts {
            let d = ((p.0 - c.0) * (p.0 - c.0) + (p.1 - c.1) * (p.1 - c.1) + (p.2 - c.2) * (p.2 - c.2)).squareRoot() - r
            se += d * d
        }
        return (c, r, (se / Double(pts.count)).squareRoot())
    }

    /// 4×4 线性方程组（高斯消元，部分主元）。奇异时返回 nil。
    public static func solve4(_ a0: [[Double]], _ b0: [Double]) -> [Double]? {
        var a = a0, b = b0
        let n = 4
        // 奇异判定按矩阵量级取相对阈值（磁场平方和量级 1e5～1e7）
        let scale = max(1, a.flatMap { $0 }.map { abs($0) }.max() ?? 0)
        for col in 0..<n {
            var piv = col
            for r in col..<n where abs(a[r][col]) > abs(a[piv][col]) { piv = r }
            guard abs(a[piv][col]) > 1e-10 * scale else { return nil }
            if piv != col { a.swapAt(piv, col); b.swapAt(piv, col) }
            for r in 0..<n where r != col {
                let f = a[r][col] / a[col][col]
                if f == 0 { continue }
                for k in col..<n { a[r][k] -= f * a[col][k] }
                b[r] -= f * b[col]
            }
        }
        return (0..<n).map { b[$0] / a[$0][$0] }
    }
}
