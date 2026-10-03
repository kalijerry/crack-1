package com.example.eslcollector

import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.ContentValues
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.provider.MediaStore
import org.json.JSONObject
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

data class TagStat(val id: String, val avgRssi: Double, val count: Int)

data class Snapshot(
    val blePerSec: Int,
    val uniquePerSec: Int,
    val top: List<TagStat>,
    val imuHz: Int,
    val magAccuracy: Int,
    val bleRows: Int,
    val imuRows: Int,
)

/** 采集核心：BLE 扫描 + IMU，输出格式见 docs/data-format.md。 */
class Recorder(private val ctx: Context) : SensorEventListener {
    private val sensorManager = ctx.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val btManager = ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private var scanner: BluetoothLeScanner? = null
    private var sensorThread: HandlerThread? = null
    private val mainHandler = Handler(ctx.mainLooper)

    var onlyEsl = true
    var isRecording = false
        private set
    var sessionDir: File? = null
        private set

    private var bleWriter: CsvWriter? = null
    private var imuWriter: CsvWriter? = null
    private var marksWriter: CsvWriter? = null
    private var startMs = 0L
    private var deviceLabel = ""

    // elapsedRealtime -> Unix 毫秒
    private var wallOffsetMs = 0L

    @Volatile var currentPoint = ""
        private set
    private var markStartMs = 0L
    private var markX = ""
    private var markY = ""

    // 传感器最新值（只在传感器线程访问）
    private val gyr = FloatArray(3)
    private val mag = FloatArray(3)
    private val quat = FloatArray(4).also { it[0] = 1f }
    private var heading = -1.0
    @Volatile private var magAccuracy = -1

    // 统计
    private val statLock = Any()
    private val recent = ArrayDeque<Triple<Long, String, Int>>()
    private var imuCount = 0
    private var lastSnapshotAt = SystemClock.elapsedRealtime()

    private val restartScan = object : Runnable {
        override fun run() {
            // 与 Handy+ 一致：每 20 分钟重启扫描，避免系统把长时间无过滤扫描降级
            stopScan()
            startScan()
            mainHandler.postDelayed(this, 20 * 60 * 1000L)
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = handle(result)
        override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach(::handle)
        override fun onScanFailed(errorCode: Int) {
            lastError = "BLE 扫描失败，错误码 $errorCode"
        }
    }

    @Volatile var lastError: String? = null

    val bluetoothEnabled: Boolean get() = btManager.adapter?.isEnabled == true

    fun start(label: String) {
        if (isRecording) return
        lastError = null
        deviceLabel = label.ifBlank { "android" }
        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val safe = deviceLabel.replace(Regex("[^A-Za-z0-9-]"), "-")
        val dir = File(ctx.getExternalFilesDir(null), "sessions/android_${safe}_$stamp").apply { mkdirs() }
        sessionDir = dir
        bleWriter = CsvWriter(File(dir, "ble.csv"), "t_ms,point_id,esl_id,rssi,src,mfg_hex")
        imuWriter = CsvWriter(File(dir, "imu.csv"), "t_ms,ax,ay,az,gx,gy,gz,mx,my,mz,mag_acc,qw,qx,qy,qz,heading_deg")
        marksWriter = CsvWriter(File(dir, "marks.csv"), "point_id,x_cm,y_cm,t_start_ms,t_end_ms,note")
        wallOffsetMs = System.currentTimeMillis() - SystemClock.elapsedRealtime()
        startMs = System.currentTimeMillis()
        synchronized(statLock) {
            recent.clear()
            imuCount = 0
        }
        writeMeta(null)

        val thread = HandlerThread("sensors").apply { start() }
        sensorThread = thread
        val h = Handler(thread.looper)
        val delay = SensorManager.SENSOR_DELAY_GAME
        for (type in listOf(Sensor.TYPE_GYROSCOPE, Sensor.TYPE_MAGNETIC_FIELD, Sensor.TYPE_ROTATION_VECTOR, Sensor.TYPE_ACCELEROMETER)) {
            val s = sensorManager.getDefaultSensor(type)
            if (s != null) {
                sensorManager.registerListener(this, s, delay, h)
            } else if (type == Sensor.TYPE_ACCELEROMETER) {
                lastError = "没有加速度计"
            }
        }

        isRecording = true
        startScan()
        mainHandler.postDelayed(restartScan, 20 * 60 * 1000L)
    }

    fun stop(): File? {
        if (!isRecording) return null
        if (currentPoint.isNotEmpty()) endMark("录制停止时结束")
        mainHandler.removeCallbacks(restartScan)
        stopScan()
        sensorManager.unregisterListener(this)
        sensorThread?.quitSafely()
        sensorThread = null
        bleWriter?.close()
        imuWriter?.close()
        marksWriter?.close()
        writeMeta(System.currentTimeMillis())
        isRecording = false
        return sessionDir
    }

    fun startMark(pointId: String, x: String, y: String) {
        markStartMs = System.currentTimeMillis()
        markX = x
        markY = y
        currentPoint = pointId
    }

    fun endMark(note: String = "") {
        val id = currentPoint
        if (id.isEmpty()) return
        currentPoint = ""
        marksWriter?.apply {
            append(listOf(CsvWriter.esc(id), CsvWriter.esc(markX), CsvWriter.esc(markY),
                markStartMs.toString(), System.currentTimeMillis().toString(), CsvWriter.esc(note)).joinToString(","))
            flush()
        }
    }

    fun flush() {
        bleWriter?.flush()
        imuWriter?.flush()
    }

    fun snapshot(): Snapshot {
        val now = System.currentTimeMillis()
        val nowRt = SystemClock.elapsedRealtime()
        synchronized(statLock) {
            while (recent.isNotEmpty() && now - recent.first().first > 2000) recent.removeFirst()
            val lastSec = recent.filter { now - it.first <= 1000 }
            val top = recent.groupBy { it.second }
                .map { (id, rs) -> TagStat(id, rs.map { it.third }.average(), rs.size) }
                .sortedByDescending { it.avgRssi }
                .take(10)
            val dt = (nowRt - lastSnapshotAt).coerceAtLeast(1)
            val hz = (imuCount * 1000.0 / dt).toInt()
            imuCount = 0
            lastSnapshotAt = nowRt
            return Snapshot(lastSec.size, lastSec.map { it.second }.toSet().size, top, hz, magAccuracy,
                bleWriter?.rowCount?.get() ?: 0, imuWriter?.rowCount?.get() ?: 0)
        }
    }

    // ---- BLE ----

    @SuppressLint("MissingPermission")
    private fun startScan() {
        val s = btManager.adapter?.bluetoothLeScanner
        if (s == null) {
            lastError = "蓝牙未开启"
            return
        }
        scanner = s
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setReportDelay(0)
            .build()
        s.startScan(null, settings, scanCallback)
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        try {
            scanner?.stopScan(scanCallback)
        } catch (_: Exception) {
        }
        scanner = null
    }

    @SuppressLint("MissingPermission")
    private fun handle(r: ScanResult) {
        val w = bleWriter ?: return
        val id = EslParser.eslId(r.scanRecord)
        if (onlyEsl && id == null) return
        val mfg = EslParser.manufacturerHex(r.scanRecord)
        if (id == null && mfg.isEmpty()) return
        val t = wallOffsetMs + r.timestampNanos / 1_000_000
        val src = r.device?.address ?: ""
        w.append("$t,${CsvWriter.esc(currentPoint)},${id ?: ""},${r.rssi},$src,$mfg")
        synchronized(statLock) { recent.addLast(Triple(System.currentTimeMillis(), id ?: src, r.rssi)) }
    }

    // ---- 传感器 ----

    override fun onSensorChanged(e: SensorEvent) {
        when (e.sensor.type) {
            Sensor.TYPE_GYROSCOPE -> System.arraycopy(e.values, 0, gyr, 0, 3)
            Sensor.TYPE_MAGNETIC_FIELD -> System.arraycopy(e.values, 0, mag, 0, 3)
            Sensor.TYPE_ROTATION_VECTOR -> {
                SensorManager.getQuaternionFromVector(quat, e.values)
                val rm = FloatArray(9)
                val ori = FloatArray(3)
                SensorManager.getRotationMatrixFromVector(rm, e.values)
                SensorManager.getOrientation(rm, ori)
                heading = (Math.toDegrees(ori[0].toDouble()) + 360.0) % 360.0
            }
            Sensor.TYPE_ACCELEROMETER -> {
                // 以加速度计事件为节拍输出一行（与 HPASS core/E 的打包方式一致）
                val t = wallOffsetMs + e.timestamp / 1_000_000
                val v = e.values
                imuWriter?.append(
                    listOf(
                        t.toString(),
                        CsvWriter.f(v[0]), CsvWriter.f(v[1]), CsvWriter.f(v[2]),
                        CsvWriter.f(gyr[0], 5), CsvWriter.f(gyr[1], 5), CsvWriter.f(gyr[2], 5),
                        CsvWriter.f(mag[0], 3), CsvWriter.f(mag[1], 3), CsvWriter.f(mag[2], 3),
                        magAccuracy.toString(),
                        CsvWriter.f(quat[0], 6), CsvWriter.f(quat[1], 6), CsvWriter.f(quat[2], 6), CsvWriter.f(quat[3], 6),
                        CsvWriter.f(heading, 2),
                    ).joinToString(",")
                )
                synchronized(statLock) { imuCount++ }
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {
        if (sensor.type == Sensor.TYPE_MAGNETIC_FIELD) magAccuracy = accuracy
    }

    // ---- 元数据与导出 ----

    private fun writeMeta(endMs: Long?) {
        val dir = sessionDir ?: return
        val meta = JSONObject().apply {
            put("platform", "android")
            put("device_label", deviceLabel)
            put("model", "${Build.MANUFACTURER} ${Build.MODEL}")
            put("os_version", "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
            put("app_version", "0.1.0")
            put("start_ms", startMs)
            put("only_esl", onlyEsl)
            put("imu_target_hz", 50)
            put("imu_convention", "android: acc m/s^2 incl. gravity (+z up when flat), gyro rad/s, mag uT calibrated")
            endMs?.let { put("end_ms", it) }
        }
        File(dir, "meta.json").writeText(meta.toString(2))
    }

    /** 打包会话目录为 zip，保存到 下载/ESLCollector/。返回可读的保存位置描述。 */
    fun exportToDownloads(dir: File): String {
        val name = dir.name + ".zip"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, "application/zip")
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/ESLCollector")
            }
            val uri = ctx.contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("无法创建下载文件")
            ctx.contentResolver.openOutputStream(uri)!!.use { zipDir(dir, it) }
            return "下载/ESLCollector/$name"
        } else {
            val out = File(ctx.getExternalFilesDir(null), "exports/$name").apply { parentFile?.mkdirs() }
            out.outputStream().use { zipDir(dir, it) }
            return out.absolutePath
        }
    }

    private fun zipDir(dir: File, os: java.io.OutputStream) {
        ZipOutputStream(os).use { zip ->
            dir.listFiles()?.sortedBy { it.name }?.forEach { f ->
                zip.putNextEntry(ZipEntry("${dir.name}/${f.name}"))
                f.inputStream().use { it.copyTo(zip) }
                zip.closeEntry()
            }
        }
    }
}
