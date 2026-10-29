package com.cellbridge.push

import java.security.KeyFactory
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64

/** The provider token APNs wants with every request: a JWT signed ES256 with the team's `.p8` key. */
object ApnsJwt {
    private val url = Base64.getUrlEncoder().withoutPadding()

    fun parseP8(pem: String): PrivateKey {
        val body = pem.lineSequence().filterNot { it.startsWith("-----") }.joinToString("").trim()
        return KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(Base64.getDecoder().decode(body)))
    }

    fun create(keyId: String, teamId: String, key: PrivateKey, issuedAtSeconds: Long): String {
        val header = url.encodeToString("""{"alg":"ES256","kid":"$keyId"}""".toByteArray())
        val claims = url.encodeToString("""{"iss":"$teamId","iat":$issuedAtSeconds}""".toByteArray())
        val signer = Signature.getInstance("SHA256withECDSA")
        signer.initSign(key)
        signer.update("$header.$claims".toByteArray())
        return "$header.$claims.${url.encodeToString(derToRaw(signer.sign()))}"
    }

    /** JOSE wants the two 32-byte integers back to back; the platform signs as a DER sequence. */
    fun derToRaw(der: ByteArray): ByteArray {
        var offset = 3 // 0x30, total length (< 128 for P-256), 0x02
        if (der[1].toInt() and 0x80 != 0) offset++ // long-form length
        val rLength = der[offset].toInt()
        val r = der.copyOfRange(offset + 1, offset + 1 + rLength)
        val sOffset = offset + 1 + rLength + 1 // skip 0x02
        val s = der.copyOfRange(sOffset + 1, sOffset + 1 + der[sOffset].toInt())
        return fixed(r) + fixed(s)
    }

    private fun fixed(integer: ByteArray): ByteArray {
        val trimmed = integer.dropWhile { it == 0.toByte() }.toByteArray()
        return ByteArray(32 - trimmed.size) + trimmed
    }
}
