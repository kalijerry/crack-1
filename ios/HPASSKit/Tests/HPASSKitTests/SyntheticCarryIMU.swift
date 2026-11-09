import Foundation
@testable import HPASSKit

// 合成「人 + 手机」刚体运动，产生 50 Hz 的 IMUSample（加速度含重力、陀螺、磁场、可选重力列 / 四元数）。
// 全部确定性，不依赖任何真实采集；用来证明携带模式切换后的航向找回、粒子不瞬移、摆臂的步幅平均等。
//
// 坐标系：
// - 世界系 F（右手）：f1 = 地图 +y，f2 = 地图 +x，f3 = 上。地图航向 θ（0 = +y，dx = sinθ）就是 F 平面里的极角：
//   行走方向在 F 里是 (cosθ, sinθ, 0)，绕 f3 逆时针 = θ 增大 = 引擎约定里的 ω_up > 0。
// - 身体系 B：b1 前、b2 左、b3 上。
// - 设备系 D：x 右、y 顶、z 屏幕法线（Android 约定；平放屏幕朝上时加速度 ≈ (0, 0, +9.81)）。

/// 3×3 旋转矩阵，行优先。`rows(r0, r1, r2)`：新坐标系的三个轴在旧坐标系里的表示 → v_new = R·v_old。
struct Rot3 {
    var m: [Double]

    init(_ m: [Double]) { self.m = m.count == 9 ? m : [1, 0, 0, 0, 1, 0, 0, 0, 1] }
    static let identity = Rot3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    static func rows(_ r0: FusionVec3, _ r1: FusionVec3, _ r2: FusionVec3) -> Rot3 {
        Rot3([r0.x, r0.y, r0.z, r1.x, r1.y, r1.z, r2.x, r2.y, r2.z])
    }
    subscript(r: Int, c: Int) -> Double { m[r * 3 + c] }
    func apply(_ v: FusionVec3) -> FusionVec3 {
        FusionVec3(self[0, 0] * v.x + self[0, 1] * v.y + self[0, 2] * v.z,
                   self[1, 0] * v.x + self[1, 1] * v.y + self[1, 2] * v.z,
                   self[2, 0] * v.x + self[2, 1] * v.y + self[2, 2] * v.z)
    }
    func mul(_ b: Rot3) -> Rot3 {
        var o = [Double](repeating: 0, count: 9)
        for r in 0..<3 { for c in 0..<3 { var s = 0.0; for k in 0..<3 { s += self[r, k] * b[k, c] }; o[r * 3 + c] = s } }
        return Rot3(o)
    }
    var transposed: Rot3 { Rot3([self[0, 0], self[1, 0], self[2, 0], self[0, 1], self[1, 1], self[2, 1], self[0, 2], self[1, 2], self[2, 2]]) }

    /// 把向量绕 `axis`（单位）转 `angle` 的主动旋转（Rodrigues）。
    static func axisAngle(_ axis: FusionVec3, _ angle: Double) -> Rot3 {
        let a = axis.normalized, c = cos(angle), s = sin(angle), t = 1 - c
        return Rot3([t * a.x * a.x + c, t * a.x * a.y - s * a.z, t * a.x * a.z + s * a.y,
                     t * a.x * a.y + s * a.z, t * a.y * a.y + c, t * a.y * a.z - s * a.x,
                     t * a.x * a.z - s * a.y, t * a.y * a.z + s * a.x, t * a.z * a.z + c])
    }

    /// 旋转向量（轴 × 角）：R = exp([v]×)。
    var rotationVector: FusionVec3 {
        let tr = self[0, 0] + self[1, 1] + self[2, 2]
        let c = FusionMath.clamp((tr - 1) / 2, -1, 1)
        let ang = acos(c)
        let v = FusionVec3(self[2, 1] - self[1, 2], self[0, 2] - self[2, 0], self[1, 0] - self[0, 1])
        if ang < 1e-9 { return v * 0.5 }
        if ang > Double.pi - 1e-6 {
            // 接近 180°：轴取对角元
            let ax = FusionVec3(max(self[0, 0] + 1, 0).squareRoot(), max(self[1, 1] + 1, 0).squareRoot(), max(self[2, 2] + 1, 0).squareRoot()) * (1 / 2.0.squareRoot())
            return ax.normalized * ang
        }
        return v * (ang / (2 * sin(ang)))
    }

    /// 四元数 (w, x, y, z)，表示同一个主动旋转。
    var quaternion: (w: Double, x: Double, y: Double, z: Double) {
        let tr = self[0, 0] + self[1, 1] + self[2, 2]
        var w: Double, x: Double, y: Double, z: Double
        if tr > 0 {
            let s = (tr + 1).squareRoot() * 2
            w = 0.25 * s; x = (self[2, 1] - self[1, 2]) / s; y = (self[0, 2] - self[2, 0]) / s; z = (self[1, 0] - self[0, 1]) / s
        } else if self[0, 0] > self[1, 1] && self[0, 0] > self[2, 2] {
            let s = (1 + self[0, 0] - self[1, 1] - self[2, 2]).squareRoot() * 2
            w = (self[2, 1] - self[1, 2]) / s; x = 0.25 * s; y = (self[0, 1] + self[1, 0]) / s; z = (self[0, 2] + self[2, 0]) / s
        } else if self[1, 1] > self[2, 2] {
            let s = (1 + self[1, 1] - self[0, 0] - self[2, 2]).squareRoot() * 2
            w = (self[0, 2] - self[2, 0]) / s; x = (self[0, 1] + self[1, 0]) / s; y = 0.25 * s; z = (self[1, 2] + self[2, 1]) / s
        } else {
            let s = (1 + self[2, 2] - self[0, 0] - self[1, 1]).squareRoot() * 2
            w = (self[1, 0] - self[0, 1]) / s; x = (self[0, 2] + self[2, 0]) / s; y = (self[1, 2] + self[2, 1]) / s; z = 0.25 * s
        }
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        return (w / n, x / n, y / n, z / n)
    }

    /// 两个旋转之间的球面插值（t ∈ [0, 1]）：R(t) = exp(t·log(B·Aᵀ))·A。
    static func slerp(_ a: Rot3, _ b: Rot3, _ t: Double) -> Rot3 {
        let d = b.mul(a.transposed).rotationVector
        guard d.norm > 1e-12 else { return a }
        return Rot3.axisAngle(d.normalized, d.norm * t).mul(a)
    }
}

/// 携带姿态（手机相对身体），含该姿态特有的周期性运动。
enum CarryPosture: Equatable {
    /// 看屏：顶朝前、屏幕朝上后方，屏幕倾角 tiltDeg（0 = 平放）
    case texting(tiltDeg: Double)
    /// 竖持（AR 姿势）：屏幕对着自己，向后仰 backDeg
    case upright(backDeg: Double)
    /// 贴耳：长轴后仰 tiltDeg，右耳 / 左耳；头部转动 ±headTurnDeg
    case calling(tiltDeg: Double, rightEar: Bool, headTurnDeg: Double)
    /// 前裤兜：顶朝下、屏幕朝腿（向后）再绕竖直转 yawDeg；大腿按步幅频率前后摆 ±thighDeg
    case pocket(yawDeg: Double, thighDeg: Double)
    /// 右手自然下垂摆臂：手臂 ±armDeg、手腕偏航 ±wristYawDeg（步幅频率）
    case swinging(armDeg: Double, wristYawDeg: Double)
    /// 挎包：手机竖着塞在包里，绕竖直转 yawDeg、左右晃 ±swayDeg
    case bag(yawDeg: Double, swayDeg: Double)

    var carryMode: CarryMode {
        switch self {
        case .texting: return .texting
        case .upright: return .upright
        case .calling: return .calling
        case .pocket: return .pocket
        case .swinging: return .swinging
        case .bag: return .bag
        }
    }
}

/// 行走剧本：航向分段、速度、步频；姿态分段（切换用 1 s 球面插值过渡）。
struct CarryScript {
    struct HeadingSeg { var fromS: Double; var headingDeg: Double }
    struct PostureSeg { var fromS: Double; var posture: CarryPosture }
    struct Pause { var fromS: Double; var toS: Double }

    var durationS: Double
    var headings: [HeadingSeg]
    var postures: [PostureSeg]
    var pauses: [Pause] = []
    var speedMS = 1.3
    var stepHz = 2.0
    var turnRampS = 1.0
    var transitionS = 1.0
    /// 起点（地图 cm）
    var startCm = Point2(300, 200)
    /// 是否写重力列 / 四元数（格式 v4）
    var v4 = true
}

/// 一个样本的真值。
struct CarryTruth {
    var tMs: Int64
    /// 身体位置（地图 cm）
    var position: Point2
    /// 行走航向（rad，地图约定）
    var headingRad: Double
    var posture: CarryPosture
    var walking: Bool
}

/// 刚体运动合成器。
struct CarrySim {
    static let g = FusionMath.gravity
    static let dtS = 0.02
    static let t0: Int64 = 1_700_000_000_000

    let script: CarryScript
    /// 世界系磁场（µT）：按地图位置给 (Bz, Bh)，水平分量指向固定方位 `fieldAzimuthRad`
    var field: (Point2) -> (vertical: Double, horizontal: Double) = { _ in (-42, 24) }
    var fieldAzimuthRad = 0.4
    var accNoise = 0.05, gyroNoise = 0.01, magNoise = 0.3
    private var seed: UInt64 = 0x9E3779B97F4A7C15

    init(script: CarryScript) { self.script = script }

    private mutating func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let u1 = Double((seed >> 11) & 0x000F_FFFF_FFFF_FFFF) / Double(1 << 52)
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let u2 = Double((seed >> 11) & 0x000F_FFFF_FFFF_FFFF) / Double(1 << 52)
        return (-2 * log(max(u1, 1e-12))).squareRoot() * cos(2 * Double.pi * u2)
    }

    // MARK: 身体

    func walking(at t: Double) -> Bool { !script.pauses.contains { t >= $0.fromS && t < $0.toS } }

    /// 行走航向（rad），分段 + 线性过渡
    func heading(at t: Double) -> Double {
        var h = FusionMath.radians(script.headings.first?.headingDeg ?? 0)
        for (i, seg) in script.headings.enumerated() where i > 0 {
            let target = FusionMath.radians(seg.headingDeg)
            if t >= seg.fromS + script.turnRampS { h = target }
            else if t > seg.fromS {
                let u = (t - seg.fromS) / script.turnRampS
                h = FusionMath.wrapTwoPi(h + FusionMath.wrapPi(target - h) * u)
                break
            } else { break }
        }
        return FusionMath.wrapTwoPi(h)
    }

    /// 身体参考点（骨盆）在 F 里的位置（m），含步行的竖直起伏、前后速度起伏、左右摆动。粗网格积分 + 解析起伏。
    private func bodyPositions(dt: Double, steps: Int) -> [FusionVec3] {
        var out: [FusionVec3] = []
        out.reserveCapacity(steps)
        var p = FusionVec3(script.startCm.y / 100, script.startCm.x / 100, 0)   // F: (地图 y, 地图 x, 上)
        let fs = script.stepHz, fstride = fs / 2
        for i in 0..<steps {
            let t = Double(i) * dt
            let h = heading(at: t)
            let dir = FusionVec3(cos(h), sin(h), 0)
            let left = FusionVec3(-sin(h), cos(h), 0)
            var q = p
            if walking(at: t) {
                let v = script.speedMS * (1 + 0.08 * sin(2 * Double.pi * fs * t + 0.3))
                p = p + dir * (v * dt)
                q = p + FusionVec3(0, 0, 0.018 * sin(2 * Double.pi * fs * t)) + left * (0.03 * sin(2 * Double.pi * fstride * t))
            }
            out.append(q)
        }
        return out
    }

    // MARK: 手机相对身体

    /// 姿态分段 + 过渡
    private func postureBlend(at t: Double) -> (a: CarryPosture, b: CarryPosture, u: Double) {
        var cur = script.postures.first?.posture ?? .texting(tiltDeg: 40)
        for (i, seg) in script.postures.enumerated() where i > 0 {
            if t >= seg.fromS + script.transitionS { cur = seg.posture }
            else if t >= seg.fromS {
                let u = (t - seg.fromS) / script.transitionS
                return (cur, seg.posture, u * u * (3 - 2 * u))
            } else { break }
        }
        return (cur, cur, 0)
    }

    /// 设备轴在身体系里的表示（R_DB：v_D = R·v_B）和手机相对身体参考点的位置（m，身体系）。
    private func devicePose(_ p: CarryPosture, t: Double, walking: Bool) -> (rot: Rot3, offset: FusionVec3) {
        let fstride = script.stepHz / 2
        let osc = walking ? 1.0 : 0.0
        func frame(y: FusionVec3, z: FusionVec3) -> Rot3 {
            let yn = y.normalized
            let zn = (z - yn * z.dot(yn)).normalized
            let xn = yn.cross(zn)
            return Rot3.rows(xn, yn, zn)
        }
        switch p {
        case .texting(let tilt):
            let r = FusionMath.radians(tilt)
            // 手里有一点自然抖动（±2.5° 俯仰，步频）
            let jitter = FusionMath.radians(2.5) * sin(2 * Double.pi * script.stepHz * t + 1) * osc
            let fr = frame(y: FusionVec3(cos(r + jitter), 0, sin(r + jitter)), z: FusionVec3(-sin(r + jitter), 0, cos(r + jitter)))
            return (fr, FusionVec3(0.3, 0, 0.3))
        case .upright(let back):
            let r = FusionMath.radians(back)
            let fr = frame(y: FusionVec3(-sin(r), 0, cos(r)), z: FusionVec3(-cos(r), 0, -sin(r)))
            return (fr, FusionVec3(0.35, 0, 0.45))
        case .calling(let tilt, let right, let headTurn):
            let r = FusionMath.radians(tilt)
            let side: Double = right ? 1 : -1
            let base = frame(y: FusionVec3(-sin(r), 0, cos(r)), z: FusionVec3(0, side, 0))
            // 头部左右转动：绕竖直轴，慢一点（0.3 Hz）
            let yaw = FusionMath.radians(headTurn) * sin(2 * Double.pi * 0.3 * t) * osc
            let rot = base.mul(Rot3.axisAngle(FusionVec3(0, 0, 1), -yaw))
            return (rot, FusionVec3(0.05, -side * 0.1, 0.65))
        case .pocket(let yawDeg, let thighDeg):
            // 基础：顶朝下，屏幕朝后（贴大腿）；大腿绕 b2 前后摆；骨盆 ±5° 偏航
            let base = frame(y: FusionVec3(0, 0, -1), z: FusionVec3(-1, 0, 0))
            let phi = FusionMath.radians(thighDeg) * sin(2 * Double.pi * fstride * t) * osc
            let pelvis = FusionMath.radians(5) * sin(2 * Double.pi * fstride * t + 0.5) * osc
            let yaw = FusionMath.radians(yawDeg) + pelvis
            // 轴在 B 里：先俯仰再偏航 → 设备轴 = Ryaw·Rpitch·基础轴 ⇒ R_DB = base·Rpitchᵀ·Ryawᵀ
            let rot = base.mul(Rot3.axisAngle(FusionVec3(0, 1, 0), -phi)).mul(Rot3.axisAngle(FusionVec3(0, 0, 1), -yaw))
            // 手机在大腿中段，跟着大腿（= 旋转后的 −y 方向）一起摆
            let thigh = FusionVec3(-sin(phi), 0, -cos(phi)) * 0.25
            return (rot, FusionVec3(0.05, -0.12, -0.1) + thigh)
        case .swinging(let armDeg, let wristDeg):
            let alpha = FusionMath.radians(armDeg) * sin(2 * Double.pi * fstride * t) * osc
            let wrist = FusionMath.radians(wristDeg) * sin(2 * Double.pi * fstride * t + 0.6) * osc
            let armDir = FusionVec3(sin(alpha), 0, -cos(alpha))
            let base = frame(y: armDir, z: FusionVec3(0, 1, 0))
            let rot = base.mul(Rot3.axisAngle(FusionVec3(0, 0, 1), -wrist))
            return (rot, FusionVec3(0, -0.2, 0.4) + armDir * 0.6)
        case .bag(let yawDeg, let swayDeg):
            let base = frame(y: FusionVec3(0.1, 0, 1), z: FusionVec3(0, -1, 0))
            let sway = FusionMath.radians(swayDeg) * sin(2 * Double.pi * fstride * t + 0.2) * osc
            let rot = base.mul(Rot3.axisAngle(FusionVec3(1, 0, 0), -sway)).mul(Rot3.axisAngle(FusionVec3(0, 0, 1), -FusionMath.radians(yawDeg)))
            // 包随步伐多颠一点
            let bounce = FusionVec3(0, 0, 0.01 * sin(2 * Double.pi * script.stepHz * t + 0.9)) * osc
            return (rot, FusionVec3(-0.1, -0.25, -0.2) + bounce)
        }
    }

    private func deviceInBody(at t: Double) -> (rot: Rot3, offset: FusionVec3) {
        let w = walking(at: t)
        let b = postureBlend(at: t)
        let pa = devicePose(b.a, t: t, walking: w)
        if b.u <= 0 { return pa }
        let pb = devicePose(b.b, t: t, walking: w)
        return (Rot3.slerp(pa.rot, pb.rot, b.u), pa.offset + (pb.offset - pa.offset) * b.u)
    }

    /// R_BF(θ)：F → B
    private func bodyRot(_ h: Double) -> Rot3 {
        Rot3.rows(FusionVec3(cos(h), sin(h), 0), FusionVec3(-sin(h), cos(h), 0), FusionVec3(0, 0, 1))
    }

    // MARK: 生成

    /// 生成整段的样本和真值。
    mutating func generate() -> (samples: [IMUSample], truth: [CarryTruth]) {
        let fine = 0.005                       // 细网格做差分
        let n = Int(script.durationS / fine) + 3
        let body = bodyPositions(dt: fine, steps: n)
        // 手机在 F 里的位置与姿态（细网格）
        var phonePos: [FusionVec3] = [], rots: [Rot3] = []
        phonePos.reserveCapacity(n); rots.reserveCapacity(n)
        for i in 0..<n {
            let t = Double(i) * fine
            let h = heading(at: t)
            let rbf = bodyRot(h)
            let (rdb, off) = deviceInBody(at: t)
            rots.append(rdb.mul(rbf))
            phonePos.append(body[i] + rbf.transposed.apply(off))
        }
        var samples: [IMUSample] = [], truth: [CarryTruth] = []
        let stride = Int((CarrySim.dtS / fine).rounded())
        var i = stride
        while i + stride < n {
            let t = Double(i) * fine
            let r = rots[i]
            // 加速度：二阶中心差分 + 重力（Android 约定：静止时读 +g 向上）
            let acc = (phonePos[i + 1] - phonePos[i] * 2 + phonePos[i - 1]) * (1 / (fine * fine))
            let aF = acc + FusionVec3(0, 0, CarrySim.g)
            let aD = r.apply(aF)
            // 角速度：R(t+h)·R(t−h)ᵀ = exp(−[ω·2h]×)
            let dR = rots[i + 1].mul(rots[i - 1].transposed)
            let w = dR.rotationVector * (-1 / (2 * fine))
            // 磁场
            let p = body[i]
            let mapPos = Point2(p.y * 100, p.x * 100)
            let f = field(mapPos)
            let bF = FusionVec3(f.horizontal * cos(fieldAzimuthRad), f.horizontal * sin(fieldAzimuthRad), f.vertical)
            let mD = r.apply(bF)
            let gD = r.apply(FusionVec3(0, 0, CarrySim.g))
            let q = r.transposed.quaternion          // 设备 → 世界
            var s = IMUSample(tMs: CarrySim.t0 + Int64((t * 1000).rounded()),
                              ax: aD.x + noise() * accNoise, ay: aD.y + noise() * accNoise, az: aD.z + noise() * accNoise,
                              gx: w.x + noise() * gyroNoise, gy: w.y + noise() * gyroNoise, gz: w.z + noise() * gyroNoise,
                              mx: mD.x + noise() * magNoise, my: mD.y + noise() * magNoise, mz: mD.z + noise() * magNoise)
            if script.v4 {
                s.gravity = (gD.x, gD.y, gD.z)
                s.attitude = q
            }
            samples.append(s)
            truth.append(CarryTruth(tMs: s.tMs, position: mapPos, headingRad: heading(at: t),
                                    posture: postureBlend(at: t).b, walking: walking(at: t)))
            i += stride
        }
        return (samples, truth)
    }
}
