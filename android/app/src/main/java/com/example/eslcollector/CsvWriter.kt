package com.example.eslcollector

import java.io.BufferedWriter
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/** 线程安全的追加写 CSV。 */
class CsvWriter(file: File, header: String) {
    private val out: BufferedWriter = file.bufferedWriter(Charsets.UTF_8, 64 * 1024)
    private val lock = Any()
    val rowCount = AtomicInteger(0)
    private var closed = false

    init {
        out.write(header)
        out.newLine()
    }

    fun append(line: String) {
        synchronized(lock) {
            // 停止录制后传感器/扫描线程可能还有残留回调，直接丢弃
            if (closed) return
            out.write(line)
            out.newLine()
        }
        rowCount.incrementAndGet()
    }

    fun flush() = synchronized(lock) { if (!closed) out.flush() }

    fun close() = synchronized(lock) {
        if (closed) return@synchronized
        closed = true
        out.flush()
        out.close()
    }

    companion object {
        fun esc(s: String): String =
            if (s.contains(',') || s.contains('"') || s.contains('\n')) "\"" + s.replace("\"", "\"\"") + "\"" else s

        fun f(v: Double, digits: Int = 4): String = String.format(java.util.Locale.US, "%.${digits}f", v)
        fun f(v: Float, digits: Int = 4): String = f(v.toDouble(), digits)
    }
}
