import Foundation

/// 从会话目录读「建图采集」需要的文件：imu.csv、mag_raw.csv、arkit_pose.csv、anchors.csv（格式见 docs/data-format.md）。
public enum SurveySessionLoader {

    public enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        public var description: String {
            switch self { case .missing(let f): return "会话里缺少 \(f)" }
        }
    }

    /// 是不是建图采集会话（有 ARKit 位姿和锚点）。
    public static func isSurvey(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("arkit_pose.csv").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("anchors.csv").path)
    }

    /// requireAnchors = false：实时定位记录没有 anchors.csv
    public static func load(_ dir: URL, requireAnchors: Bool = true) throws -> SurveySession {
        func rows(_ name: String, required: Bool = true) throws -> [[Substring]] {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                if required { throw LoadError.missing(name) }
                return []
            }
            return text.split(separator: "\n").dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false) }
        }
        let imu = try rows("imu.csv").compactMap { r -> IMUSample? in
            guard r.count >= 10, let t = Int64(r[0]) else { return nil }
            let v = r[1...9].map { Double($0) ?? 0 }
            return IMUSample(tMs: t, ax: v[0], ay: v[1], az: v[2], gx: v[3], gy: v[4], gz: v[5], mx: v[6], my: v[7], mz: v[8])
        }
        let raw = try rows("mag_raw.csv", required: false).compactMap { r -> (tMs: Int64, v: (Double, Double, Double))? in
            guard r.count >= 4, let t = Int64(r[0]), let x = Double(r[1]), let y = Double(r[2]), let z = Double(r[3]) else { return nil }
            return (t, (x, y, z))
        }
        let poses = try rows("arkit_pose.csv").compactMap { r -> SurveySession.Pose? in
            guard r.count >= 9, let t = Int64(r[0]), let x = Double(r[1]), let z = Double(r[3]) else { return nil }
            return SurveySession.Pose(tMs: t, a: Point2(x * 100, z * 100), normal: r[8] == "2")
        }
        let anchors = try rows("anchors.csv", required: requireAnchors).compactMap { r -> SurveySession.Anchor? in
            guard r.count >= 7, let t = Int64(r[0]), let mx = Double(r[2]), let my = Double(r[3]),
                  let ax = Double(r[4]), let az = Double(r[5]) else { return nil }
            return SurveySession.Anchor(tMs: t, kind: String(r[1]), map: Point2(mx, my), ar: Point2(ax, az),
                                        heading: Double(r[6]))
        }
        return SurveySession(name: dir.lastPathComponent, imu: imu, raw: raw, poses: poses, anchors: anchors)
    }
}
