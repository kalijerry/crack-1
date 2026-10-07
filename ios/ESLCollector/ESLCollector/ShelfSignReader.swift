import ARKit
import Foundation
import HPASSKit
import Vision

/// 采集时用摄像头读货架立柱上的黄色位置标签（「082-20」）。
///
/// - 用 ARKit 已经在跑的相机画面（不另开相机），每秒约 2 帧送给系统自带的文字识别（Vision，全部在手机上做）；
/// - 只留下符合「三位-两位」格式的文字，不存图片、不上传图片；
/// - 上一帧还没识别完就跳过这一帧（ARKit 的画面不能久占）。
final class ShelfSignReader: @unchecked Sendable {
    /// 读到标签：时间（ms，和传感器同一时钟）、规范化的文字（如 082-20）、置信度
    var onRead: (@Sendable (Int64, String, Float) -> Void)?

    private let queue = DispatchQueue(label: "shelf-sign-reader", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    func process(_ frame: ARFrame, tMs: Int64) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()
        let buffer = frame.capturedImage
        queue.async { [weak self] in
            defer { self?.lock.lock(); self?.busy = false; self?.lock.unlock() }
            self?.recognize(buffer, tMs: tMs)
        }
    }

    private func recognize(_ buffer: CVPixelBuffer, tMs: Int64) {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["en-US"]
        req.minimumTextHeight = 0.015
        // 竖着拿手机：画面要转到「上」朝上
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right, options: [:])
        do { try handler.perform([req]) } catch { return }
        var seen = Set<String>()
        for obs in req.results ?? [] {
            for cand in obs.topCandidates(2) where cand.confidence >= 0.4 {
                guard let (a, b) = ShelfSigns.parse(cand.string) else { continue }
                let text = String(format: "%03d-%02d", a, b)
                if seen.insert(text).inserted { onRead?(tMs, text, cand.confidence) }
                break
            }
        }
    }
}
