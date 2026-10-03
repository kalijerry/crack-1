package com.example.eslcollector

import android.bluetooth.le.ScanRecord

object EslParser {
    /** 价签广播使用的公司 ID，与 Handy+ NativeBluetoothManager 一致。 */
    const val COMPANY_ID = 13

    /**
     * 与 Handy+ shortPackageParse 相同：getManufacturerSpecificData(13) 长度 4..7，
     * 取前 4 字节转大写十六进制，用 "-" 连接。
     */
    fun eslId(record: ScanRecord?): String? {
        val data = record?.getManufacturerSpecificData(COMPANY_ID) ?: return null
        return eslIdFromPayload(data)
    }

    fun eslIdFromPayload(payload: ByteArray): String? {
        if (payload.size < 4 || payload.size >= 8) return null
        return payload.take(4).joinToString("-") { "%02X".format(it.toInt() and 0xFF) }
    }

    /** 完整厂商数据（含 2 字节小端公司 ID），与 iOS kCBAdvDataManufacturerData 格式一致。 */
    fun manufacturerHex(record: ScanRecord?): String {
        val arr = record?.manufacturerSpecificData ?: return ""
        if (arr.size() == 0) return ""
        val idx = arr.indexOfKey(COMPANY_ID).takeIf { it >= 0 } ?: 0
        val cid = arr.keyAt(idx)
        val payload = arr.valueAt(idx) ?: return ""
        val sb = StringBuilder()
        sb.append("%02X%02X".format(cid and 0xFF, (cid shr 8) and 0xFF))
        for (b in payload) sb.append("%02X".format(b.toInt() and 0xFF))
        return sb.toString()
    }
}
