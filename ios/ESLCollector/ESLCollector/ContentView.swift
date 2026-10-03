import SwiftUI

struct ContentView: View {
    @StateObject private var rec = Recorder()
    private let durations = [15, 30, 60, 120, 300]

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                recordSection
                if rec.isRecording { markSection }
                topTagsSection
                Section {
                    NavigationLink("历史会话 / 导出") { SessionsView() }
                        .disabled(rec.isRecording)
                }
            }
            .navigationTitle("ESL 采集")
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private var statusSection: some View {
        Section("状态") {
            row("蓝牙", rec.bleState)
            if rec.isRecording {
                row("录制时长", Self.duration(rec.elapsed))
                row("读数 / 秒", "\(rec.blePerSec)")
                row("唯一价签 / 秒", "\(rec.uniqueTagsPerSec)")
                row("IMU 频率", "\(rec.imuHz) Hz")
                row("磁场精度", Self.magText(rec.magAccuracy))
                row("已写入", "BLE \(rec.bleRows) 行 · IMU \(rec.imuRows) 行 · 打点 \(rec.markCount)")
            }
            if let err = rec.lastError {
                Text(err).foregroundStyle(.red)
            }
        }
    }

    private var recordSection: some View {
        Section {
            TextField("设备标签（如 16pro）", text: $rec.deviceLabel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(rec.isRecording)
            Toggle("仅记录价签广播（公司ID 13）", isOn: $rec.onlyESL)
                .disabled(rec.isRecording)
            Button {
                rec.isRecording ? rec.stopRecording() : rec.startRecording()
            } label: {
                Text(rec.isRecording ? "停止录制" : "开始录制")
                    .frame(maxWidth: .infinity)
                    .fontWeight(.semibold)
            }
            .tint(rec.isRecording ? .red : .accentColor)
        } header: {
            Text("录制")
        } footer: {
            Text("录制期间请保持 App 在前台、屏幕常亮（已自动禁用锁屏）。")
        }
    }

    private var markSection: some View {
        Section {
            HStack {
                Text("点位编号")
                TextField("如 12", text: $rec.pointId)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            HStack {
                Text("坐标 cm（可选）")
                TextField("x", text: $rec.xText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                TextField("y", text: $rec.yText)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
            }
            Picker("时长", selection: $rec.markDuration) {
                ForEach(durations, id: \.self) { Text("\($0) 秒").tag($0) }
            }
            .disabled(rec.markingPoint != nil)
            if let p = rec.markingPoint {
                Button {
                    rec.endMark(note: "手动结束")
                } label: {
                    Text("点位 \(p) 采集中… 剩余 \(rec.markRemaining) 秒（点击提前结束）")
                        .frame(maxWidth: .infinity)
                }
                .tint(.orange)
            } else {
                Button {
                    rec.startMark()
                } label: {
                    Text("开始打点").frame(maxWidth: .infinity).fontWeight(.semibold)
                }
            }
        } header: {
            Text("打点")
        } footer: {
            Text("标定时两台手机并排、朝向一致，同时开始同一编号的打点。结束时会震动提示，纯数字编号自动 +1。")
        }
    }

    private var topTagsSection: some View {
        Section("最强价签（近 2 秒）") {
            if rec.topTags.isEmpty {
                Text(rec.isRecording ? "暂无读数" : "未录制").foregroundStyle(.secondary)
            }
            ForEach(rec.topTags) { t in
                HStack {
                    Text(t.id).font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(String(format: "%.1f dBm", t.avgRssi)).monospacedDigit()
                    Text("×\(t.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    static func magText(_ a: Int) -> String {
        switch a {
        case 2: return "高"
        case 1: return "中"
        case 0: return "低（请画 8 字校准）"
        default: return "未校准（请画 8 字校准）"
        }
    }
}
