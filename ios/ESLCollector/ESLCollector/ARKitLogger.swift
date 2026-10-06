import ARKit
import Foundation

/// 建图采集用的视觉里程计记录：ARKit 世界跟踪（16 Pro 上带 LiDAR 辅助），
/// 30 Hz 写 `arkit_pose.csv`，同时把平面位置回调给界面。
///
/// ARKit 世界系：重力对齐，x 右、y 上、z 朝向观察者。俯视（从 +y 往下看）时 x 向右、z 向下，
/// 与门店地图的 x 向右、y 向下是同一个手性，所以 (x, z) → 地图 (x, y) 只需要一次平面旋转加平移。
final class ARKitLogger: NSObject, ARSessionDelegate {

    /// 回调：Unix 毫秒、x 厘米、z 厘米、跟踪状态（0 不可用 1 受限 2 正常）。在内部串行队列上调用。
    var onPose: (@Sendable (Int64, Double, Double, Int) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    private let session = ARSession()
    private let queue = DispatchQueue(label: "arkit.logger", qos: .userInitiated)
    private var writer: CSVWriter?
    private var frameCounter = 0
    private let epochOffset = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
    }

    func start(dir: URL) throws {
        writer = try CSVWriter(url: dir.appendingPathComponent("arkit_pose.csv"),
                               header: "t_ms,x_m,y_m,z_m,qx,qy,qz,qw,tracking,limited_reason")
        frameCounter = 0
        let cfg = ARWorldTrackingConfiguration()
        cfg.worldAlignment = .gravity
        cfg.planeDetection = []
        cfg.environmentTexturing = .none
        session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        queue.sync {
            writer?.close()
            writer = nil
        }
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        frameCounter += 1
        guard frameCounter % 2 == 0 else { return }          // 60 Hz → 30 Hz
        let t = Int64(((epochOffset + frame.timestamp) * 1000).rounded())
        let m = frame.camera.transform
        let p = m.columns.3
        let q = simd_quatf(m)
        var state = 0
        var reason = 0
        switch frame.camera.trackingState {
        case .normal: state = 2
        case .limited(let r):
            state = 1
            switch r {
            case .initializing: reason = 1
            case .excessiveMotion: reason = 2
            case .insufficientFeatures: reason = 3
            case .relocalizing: reason = 4
            @unknown default: reason = 9
            }
        case .notAvailable: state = 0
        }
        writer?.append([
            "\(t)", Fmt.f(Double(p.x), 4), Fmt.f(Double(p.y), 4), Fmt.f(Double(p.z), 4),
            Fmt.f(Double(q.vector.x), 5), Fmt.f(Double(q.vector.y), 5), Fmt.f(Double(q.vector.z), 5),
            Fmt.f(Double(q.vector.w), 5), "\(state)", "\(reason)",
        ].joined(separator: ","))
        onPose?(t, Double(p.x) * 100, Double(p.z) * 100, state)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onError?("ARKit 出错：\(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onError?("ARKit 被打断（来电、切后台等），位置不可信，请回到最近的已知点长按修正")
    }
}
