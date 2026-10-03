import Foundation

/// 3×3 矩阵，行优先。只在融合模块内部使用（不引入 simd）。
struct FusionMat3 {
    /// 9 个元素，行优先。构造时长度不对会退化成零矩阵（不崩）。
    private(set) var m: [Double]

    init(_ v: [Double]) {
        m = v.count == 9 ? v : [Double](repeating: 0, count: 9)
    }

    static var zero: FusionMat3 { FusionMat3([Double](repeating: 0, count: 9)) }
    static var identity: FusionMat3 { FusionMat3([1, 0, 0, 0, 1, 0, 0, 0, 1]) }

    subscript(r: Int, c: Int) -> Double {
        get {
            let i = r * 3 + c
            return (i >= 0 && i < 9) ? m[i] : 0
        }
        set {
            let i = r * 3 + c
            if i >= 0 && i < 9 { m[i] = newValue }
        }
    }

    func mul(_ b: FusionMat3) -> FusionMat3 {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += self[r, k] * b[k, c] }
                out[r * 3 + c] = s
            }
        }
        return FusionMat3(out)
    }

    var transposed: FusionMat3 {
        FusionMat3([self[0, 0], self[1, 0], self[2, 0],
                    self[0, 1], self[1, 1], self[2, 1],
                    self[0, 2], self[1, 2], self[2, 2]])
    }
}

/// 扩展卡尔曼滤波器，状态 **[x, y, θ]**：
/// - x, y 单位 **米**，地图系（调用边界上再换算成 cm）；
/// - θ 单位 rad，地图系，0 = +y，dx = L·sinθ，dy = L·cosθ（约定见 FusionTypes.swift）。
///
/// 为什么选 EKF 而不是粒子滤波：
/// 1. 本问题的非线性只来自「航向 → 位移」的三角函数，单步 0.6 m、航向 1σ 几度，
///    一阶线性化误差远小于定位噪声（1–3 m），EKF 完全够用；
/// 2. 输出 3 Hz、输入 50 Hz，手机上要长时间常驻，EKF 的常数级开销比几百个粒子省电得多；
/// 3. EKF 有解析的新息协方差 S，可以直接做卡方/马氏门限剔除野点；粒子滤波要额外设计；
/// 4. 通道约束在这里是「硬投影」而不是「多假设」。只有需要在平行通道之间做多假设跟踪时，
///    粒子滤波才有明显优势 —— 那是后续可以换的方向。
///
/// 线程约定：值类型，由 FusionEngine 独占持有，在同一串行队列上使用。
struct FusionEKFState {
    var x: Double = 0
    var y: Double = 0
    var th: Double = 0
    /// 协方差，顺序 [x, y, θ]，单位 m² / m·rad / rad²。
    var p: FusionMat3 = FusionMat3.identity

    /// 位置 1σ（m）：两个位置对角元的均方根。
    var posSigmaM: Double {
        let v = 0.5 * (p[0, 0] + p[1, 1])
        return v > 0 ? v.squareRoot() : 0
    }

    mutating func reset(posSigmaM: Double, headSigmaRad: Double) {
        x = 0; y = 0; th = 0
        p = FusionMat3.zero
        p[0, 0] = posSigmaM * posSigmaM
        p[1, 1] = posSigmaM * posSigmaM
        p[2, 2] = headSigmaRad * headSigmaRad
    }

    mutating func setPosition(_ xm: Double, _ ym: Double, sigmaM: Double) {
        x = xm; y = ym
        p[0, 0] = sigmaM * sigmaM
        p[1, 1] = sigmaM * sigmaM
        p[0, 1] = 0; p[1, 0] = 0
        // 位置被强制重置，和航向之间原有的相关性不再成立
        p[0, 2] = 0; p[2, 0] = 0
        p[1, 2] = 0; p[2, 1] = 0
    }

    mutating func setHeading(_ t: Double, sigmaRad: Double) {
        th = FusionMath.wrapTwoPi(t)
        p[2, 2] = sigmaRad * sigmaRad
        p[0, 2] = 0; p[2, 0] = 0
        p[1, 2] = 0; p[2, 1] = 0
    }

    /// 航向增量（来自姿态互补滤波的陀螺积分），均值直接叠加，不确定度由 propagateTime 负责。
    mutating func addHeadingDelta(_ d: Double) {
        guard d.isFinite else { return }
        th = FusionMath.wrapTwoPi(th + d)
    }

    mutating func inflatePosition(addVarM2: Double) {
        p[0, 0] += max(addVarM2, 0)
        p[1, 1] += max(addVarM2, 0)
    }

    /// 时间推进：位置与航向的随机游走。rate 单位分别是 m/√s 和 rad/√s。
    mutating func propagateTime(dt: Double, posRate: Double, headRate: Double) {
        guard dt > 0 else { return }
        p[0, 0] += posRate * posRate * dt
        p[1, 1] += posRate * posRate * dt
        p[2, 2] += headRate * headRate * dt
    }

    /// 检出一步时的状态推进（PDR 航位推算）。
    /// - Parameters:
    ///   - lengthApplied: 实际加到均值上的位移（m）。两步之间已经内插过的部分要扣掉。
    ///   - lengthForNoise: 本步的完整步长（m），用于雅可比和过程噪声 —— 协方差要反映整步的影响。
    ///   - sigmaLenRel: 步长相对误差（1σ）。
    ///   - sigmaHeadStep: 单步内的航向误差（1σ，rad）。
    mutating func propagateStep(lengthApplied: Double, lengthForNoise: Double,
                                sigmaLenRel: Double, sigmaHeadStep: Double) {
        let s = sin(th)
        let c = cos(th)
        let la = lengthApplied.isFinite ? max(lengthApplied, 0) : 0
        let ln = lengthForNoise.isFinite ? max(lengthForNoise, 0.05) : 0.05

        x += la * s
        y += la * c

        // F = ∂f/∂[x,y,θ]；用整步长度，保证位置-航向相关性与实际走过的距离一致。
        var f = FusionMat3.identity
        f[0, 2] = ln * c
        f[1, 2] = -ln * s
        p = f.mul(p).mul(f.transposed)

        // 控制噪声 V·M·Vᵀ，M = diag(σ_L², σ_θ²)，V = [[sinθ, L·cosθ], [cosθ, −L·sinθ], [0, 1]]
        let sl = max(sigmaLenRel, 0) * ln
        let st = max(sigmaHeadStep, 0)
        addOuter(sl, s, c, 0)
        addOuter(st, ln * c, -ln * s, 1)
        symmetrize()
    }

    /// 位置观测的马氏距离平方（2 自由度），用于卡方门限。
    func positionMahalanobis(zx: Double, zy: Double, r: Double) -> Double {
        let s00 = p[0, 0] + r
        let s01 = p[0, 1]
        let s11 = p[1, 1] + r
        let det = s00 * s11 - s01 * s01
        guard det > 1e-12 else { return 0 }
        let nx = zx - x
        let ny = zy - y
        let i00 = s11 / det
        let i01 = -s01 / det
        let i11 = s00 / det
        let d2 = nx * (i00 * nx + i01 * ny) + ny * (i01 * nx + i11 * ny)
        return d2.isFinite ? max(d2, 0) : 0
    }

    /// 位置观测更新。H = [[1,0,0],[0,1,0]]，R = r·I。
    mutating func updatePosition(zx: Double, zy: Double, r: Double) {
        guard zx.isFinite && zy.isFinite else { return }
        let s00 = p[0, 0] + r
        let s01 = p[0, 1]
        let s11 = p[1, 1] + r
        let det = s00 * s11 - s01 * s01
        guard det > 1e-12 else { return }
        let i00 = s11 / det
        let i01 = -s01 / det
        let i11 = s00 / det

        // C = P·Hᵀ（P 的前两列），K = C·S⁻¹
        let c00 = p[0, 0], c01 = p[0, 1]
        let c10 = p[1, 0], c11 = p[1, 1]
        let c20 = p[2, 0], c21 = p[2, 1]
        let k00 = c00 * i00 + c01 * i01, k01 = c00 * i01 + c01 * i11
        let k10 = c10 * i00 + c11 * i01, k11 = c10 * i01 + c11 * i11
        let k20 = c20 * i00 + c21 * i01, k21 = c20 * i01 + c21 * i11

        let nx = zx - x
        let ny = zy - y
        x += k00 * nx + k01 * ny
        y += k10 * nx + k11 * ny
        th = FusionMath.wrapTwoPi(th + k20 * nx + k21 * ny)

        // P ← P − K·(H·P)，H·P 是 P 的前两行；先取出，避免原地修改时被污染。
        let a0 = p[0, 0], a1 = p[0, 1], a2 = p[0, 2]
        let b0 = p[1, 0], b1 = p[1, 1], b2 = p[1, 2]
        p[0, 0] -= k00 * a0 + k01 * b0
        p[0, 1] -= k00 * a1 + k01 * b1
        p[0, 2] -= k00 * a2 + k01 * b2
        p[1, 0] -= k10 * a0 + k11 * b0
        p[1, 1] -= k10 * a1 + k11 * b1
        p[1, 2] -= k10 * a2 + k11 * b2
        p[2, 0] -= k20 * a0 + k21 * b0
        p[2, 1] -= k20 * a1 + k21 * b1
        p[2, 2] -= k20 * a2 + k21 * b2
        symmetrize()
        clampDiagonal()
    }

    /// 航向标量观测更新。H = [0,0,1]。
    mutating func updateHeading(z: Double, r: Double) {
        guard z.isFinite else { return }
        let s = p[2, 2] + r
        guard s > 1e-12 else { return }
        let k0 = p[0, 2] / s
        let k1 = p[1, 2] / s
        let k2 = p[2, 2] / s
        let nu = FusionMath.wrapPi(z - th)
        x += k0 * nu
        y += k1 * nu
        th = FusionMath.wrapTwoPi(th + k2 * nu)

        let c0 = p[2, 0], c1 = p[2, 1], c2 = p[2, 2]
        p[0, 0] -= k0 * c0; p[0, 1] -= k0 * c1; p[0, 2] -= k0 * c2
        p[1, 0] -= k1 * c0; p[1, 1] -= k1 * c1; p[1, 2] -= k1 * c2
        p[2, 0] -= k2 * c0; p[2, 1] -= k2 * c1; p[2, 2] -= k2 * c2
        symmetrize()
        clampDiagonal()
    }

    // MARK: - 内部

    /// P += σ²·v⊗v
    private mutating func addOuter(_ sigma: Double, _ v0: Double, _ v1: Double, _ v2: Double) {
        let s2 = sigma * sigma
        guard s2 > 0 else { return }
        p[0, 0] += s2 * v0 * v0
        p[0, 1] += s2 * v0 * v1
        p[0, 2] += s2 * v0 * v2
        p[1, 0] += s2 * v1 * v0
        p[1, 1] += s2 * v1 * v1
        p[1, 2] += s2 * v1 * v2
        p[2, 0] += s2 * v2 * v0
        p[2, 1] += s2 * v2 * v1
        p[2, 2] += s2 * v2 * v2
    }

    private mutating func symmetrize() {
        let a = 0.5 * (p[0, 1] + p[1, 0]); p[0, 1] = a; p[1, 0] = a
        let b = 0.5 * (p[0, 2] + p[2, 0]); p[0, 2] = b; p[2, 0] = b
        let c = 0.5 * (p[1, 2] + p[2, 1]); p[1, 2] = c; p[2, 1] = c
    }

    /// 数值误差可能把对角元压成负数，钳到一个很小的正数。
    private mutating func clampDiagonal() {
        let floorPos = 1e-6      // (1 mm)²
        let floorAng = 1e-8      // ≈ (0.006°)²
        if !(p[0, 0] > floorPos) { p[0, 0] = floorPos }
        if !(p[1, 1] > floorPos) { p[1, 1] = floorPos }
        if !(p[2, 2] > floorAng) { p[2, 2] = floorAng }
    }
}
