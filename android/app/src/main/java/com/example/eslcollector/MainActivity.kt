package com.example.eslcollector

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.View
import android.view.WindowManager
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import java.util.Locale
import kotlin.concurrent.thread

class MainActivity : Activity() {
    private lateinit var recorder: Recorder
    private val handler = Handler(Looper.getMainLooper())
    private val durations = listOf(15, 30, 60, 120, 300)

    private lateinit var status: TextView
    private lateinit var labelInput: EditText
    private lateinit var onlyEsl: CheckBox
    private lateinit var recordBtn: Button
    private lateinit var markPanel: LinearLayout
    private lateinit var pointInput: EditText
    private lateinit var xInput: EditText
    private lateinit var yInput: EditText
    private lateinit var durationSpinner: Spinner
    private lateinit var markBtn: Button
    private lateinit var topTags: TextView

    private var startRt = 0L
    private var markEndRt = 0L
    private var markCount = 0

    private val tick = object : Runnable {
        override fun run() {
            refresh()
            handler.postDelayed(this, 500)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        recorder = Recorder(this)
        buildUi()
        requestPerms()
    }

    override fun onDestroy() {
        if (recorder.isRecording) recorder.stop()
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    // ---- 交互 ----

    private fun toggleRecording() {
        if (recorder.isRecording) {
            val dir = recorder.stop()
            handler.removeCallbacks(tick)
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            updateControls()
            refresh()
            if (dir != null) {
                thread {
                    val msg = try {
                        "已导出到 " + recorder.exportToDownloads(dir)
                    } catch (e: Exception) {
                        "导出失败：${e.message}，原始数据在 ${dir.absolutePath}"
                    }
                    runOnUiThread { Toast.makeText(this, msg, Toast.LENGTH_LONG).show() }
                }
            }
            return
        }
        if (!hasPerms()) {
            requestPerms()
            Toast.makeText(this, "请先授予蓝牙和位置权限", Toast.LENGTH_SHORT).show()
            return
        }
        if (!recorder.bluetoothEnabled) {
            Toast.makeText(this, "请先打开蓝牙", Toast.LENGTH_SHORT).show()
            return
        }
        recorder.onlyEsl = onlyEsl.isChecked
        recorder.start(labelInput.text.toString().trim())
        startRt = SystemClock.elapsedRealtime()
        markCount = 0
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        updateControls()
        handler.post(tick)
    }

    private fun toggleMark() {
        if (recorder.currentPoint.isNotEmpty()) {
            finishMark("手动结束")
            return
        }
        val id = pointInput.text.toString().trim()
        if (id.isEmpty()) {
            Toast.makeText(this, "请先填写点位编号", Toast.LENGTH_SHORT).show()
            return
        }
        recorder.startMark(id, xInput.text.toString().trim(), yInput.text.toString().trim())
        markEndRt = SystemClock.elapsedRealtime() + durations[durationSpinner.selectedItemPosition] * 1000L
        markBtn.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
        updateControls()
    }

    private fun finishMark(note: String = "") {
        val id = recorder.currentPoint
        recorder.endMark(note)
        markEndRt = 0
        markCount++
        markBtn.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
        id.toIntOrNull()?.let { pointInput.setText((it + 1).toString()) }
        updateControls()
    }

    private fun refresh() {
        if (!recorder.isRecording) {
            status.text = "蓝牙：${if (recorder.bluetoothEnabled) "已开启" else "已关闭"}\n未录制"
            topTags.text = ""
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (markEndRt > 0) {
            val remain = ((markEndRt - now + 999) / 1000).coerceAtLeast(0)
            markBtn.text = "点位 ${recorder.currentPoint} 采集中… 剩余 $remain 秒（点击提前结束）"
            if (now >= markEndRt) finishMark()
        }
        val s = recorder.snapshot()
        recorder.flush()
        val secs = (now - startRt) / 1000
        status.text = buildString {
            append("蓝牙：${if (recorder.bluetoothEnabled) "已开启" else "已关闭"}\n")
            append(String.format(Locale.US, "录制时长：%02d:%02d:%02d\n", secs / 3600, (secs / 60) % 60, secs % 60))
            append("读数/秒：${s.blePerSec}    唯一价签/秒：${s.uniquePerSec}\n")
            append("IMU：${s.imuHz} Hz    磁场精度：${magText(s.magAccuracy)}\n")
            append("已写入：BLE ${s.bleRows} 行 · IMU ${s.imuRows} 行 · 打点 $markCount")
            recorder.lastError?.let { append("\n⚠ $it") }
        }
        topTags.text = if (s.top.isEmpty()) "暂无读数" else s.top.joinToString("\n") {
            String.format(Locale.US, "%-14s %7.1f dBm  ×%d", it.id, it.avgRssi, it.count)
        }
    }

    private fun updateControls() {
        val rec = recorder.isRecording
        recordBtn.text = if (rec) "停止录制" else "开始录制"
        labelInput.isEnabled = !rec
        onlyEsl.isEnabled = !rec
        markPanel.visibility = if (rec) View.VISIBLE else View.GONE
        val marking = recorder.currentPoint.isNotEmpty()
        durationSpinner.isEnabled = !marking
        if (!marking) markBtn.text = "开始打点"
    }

    private fun magText(a: Int) = when (a) {
        3 -> "高"
        2 -> "中"
        1 -> "低（请画 8 字校准）"
        else -> "未校准（请画 8 字校准）"
    }

    // ---- 权限 ----

    private fun neededPerms(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.ACCESS_FINE_LOCATION)
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun hasPerms() = neededPerms().all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    private fun requestPerms() {
        if (!hasPerms()) requestPermissions(neededPerms(), 1)
    }

    // ---- 界面（纯代码，不依赖 AndroidX） ----

    private fun buildUi() {
        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }
        fun header(t: String) = TextView(this).apply {
            text = t
            textSize = 13f
            setTypeface(typeface, Typeface.BOLD)
            setPadding(0, pad, 0, pad / 4)
        }

        status = TextView(this).apply { textSize = 15f }
        labelInput = EditText(this).apply {
            hint = "设备标签（如 s25plus）"
            setText("s25plus")
            inputType = InputType.TYPE_CLASS_TEXT
        }
        onlyEsl = CheckBox(this).apply {
            text = "仅记录价签广播（公司ID 13）"
            isChecked = true
        }
        recordBtn = Button(this).apply { setOnClickListener { toggleRecording() } }

        pointInput = EditText(this).apply {
            hint = "点位编号"
            setText("1")
            inputType = InputType.TYPE_CLASS_TEXT
        }
        xInput = EditText(this).apply {
            hint = "x (cm，可选)"
            inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or InputType.TYPE_NUMBER_FLAG_SIGNED
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        yInput = EditText(this).apply {
            hint = "y (cm，可选)"
            inputType = xInput.inputType
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        durationSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(this@MainActivity, android.R.layout.simple_spinner_dropdown_item,
                durations.map { "$it 秒" })
            setSelection(durations.indexOf(60))
        }
        markBtn = Button(this).apply { setOnClickListener { toggleMark() } }
        markPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(header("打点（两台手机并排、朝向一致，同时开始同一编号）"))
            addView(pointInput)
            addView(LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                addView(xInput)
                addView(yInput)
            })
            addView(durationSpinner)
            addView(markBtn)
        }
        topTags = TextView(this).apply {
            typeface = Typeface.MONOSPACE
            textSize = 13f
        }

        root.addView(header("状态"))
        root.addView(status)
        root.addView(header("录制（保持前台、亮屏）"))
        root.addView(labelInput)
        root.addView(onlyEsl)
        root.addView(recordBtn)
        root.addView(markPanel)
        root.addView(header("最强价签（近 2 秒）"))
        root.addView(topTags)
        root.addView(header("停止录制后自动打包到 下载/ESLCollector/"))

        setContentView(ScrollView(this).apply { addView(root) })
        updateControls()
        refresh()
    }
}
