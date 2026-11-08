import Foundation

/// 同一时间只让一个页面占用运动传感器、蓝牙扫描和摄像头。
///
/// 采集、蓝牙定位、地磁定位、建图采集各自有一套传感器，同时开会互相抢（降频、发热、ARKit 只能有一个会话）。
/// 谁开始就申请；如果别人正在用，先让它停下。
@MainActor
final class SensorArbiter {
    static let shared = SensorArbiter()

    private var owner: String?
    private var stopOwner: (() -> Void)?

    /// 当前占用者（给界面提示用）。
    var current: String? { owner }

    /// 申请占用。别人正在用就先让它停下，返回被停下的那个名字。
    @discardableResult
    func claim(_ name: String, stop: @escaping () -> Void) -> String? {
        var stopped: String?
        if let o = owner, o != name {
            stopped = o
            let s = stopOwner
            owner = nil
            stopOwner = nil
            s?()
            AppLog.w("传感器", "「\(name)」开始，已自动停止「\(o)」，避免两路传感器互相抢")
        }
        owner = name
        stopOwner = stop
        return stopped
    }

    func release(_ name: String) {
        guard owner == name else { return }
        owner = nil
        stopOwner = nil
    }
}
