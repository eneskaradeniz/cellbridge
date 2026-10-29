package com.cellbridge.status

import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import java.net.URLEncoder

/** What the QR code on the phone's screen holds; the iPhone's camera reads it once to pair (docs/protocol.md). */
fun pairingLink(code: String, deviceId: String, host: String?, port: Int): String = buildString {
    append("cellbridge://pair?code=").append(URLEncoder.encode(code, "UTF-8"))
    append("&id=").append(URLEncoder.encode(deviceId, "UTF-8"))
    append("&port=").append(port)
    if (host != null) append("&host=").append(URLEncoder.encode(host, "UTF-8"))
}

/** The QR code as rows of dark/light modules, quiet zone not included. */
fun qrModules(text: String): List<List<Boolean>> {
    val matrix = QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0, mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 0))
    return List(matrix.height) { y -> List(matrix.width) { x -> matrix[x, y] } }
}
