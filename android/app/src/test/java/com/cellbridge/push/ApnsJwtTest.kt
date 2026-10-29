package com.cellbridge.push

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.Base64

class ApnsJwtTest {
    private val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
    private val url = Base64.getUrlDecoder()

    /** Back to the DER the platform verifies with. */
    private fun rawToDer(raw: ByteArray): ByteArray {
        fun integer(bytes: ByteArray): ByteArray {
            val stripped = bytes.dropWhile { it == 0.toByte() }.toByteArray()
            val trimmed = if (stripped.isEmpty()) byteArrayOf(0) else stripped
            val padded = if (trimmed[0] < 0) byteArrayOf(0) + trimmed else trimmed
            return byteArrayOf(0x02, padded.size.toByte()) + padded
        }
        val body = integer(raw.copyOfRange(0, 32)) + integer(raw.copyOfRange(32, 64))
        return byteArrayOf(0x30, body.size.toByte()) + body
    }

    @Test fun `the token has the header and claims APNs expects`() {
        val jwt = ApnsJwt.create("KEY123", "TEAM456", pair.private, 1_700_000_000)
        val (header, claims, _) = jwt.split(".")
        assertEquals("""{"alg":"ES256","kid":"KEY123"}""", String(url.decode(header)))
        assertEquals("""{"iss":"TEAM456","iat":1700000000}""", String(url.decode(claims)))
    }

    @Test fun `the signature is 64 raw bytes and verifies`() {
        repeat(20) { // the DER length of r and s varies from signature to signature
            val jwt = ApnsJwt.create("K", "T", pair.private, 1)
            val parts = jwt.split(".")
            val raw = url.decode(parts[2])
            assertEquals(64, raw.size)
            val verifier = Signature.getInstance("SHA256withECDSA").apply { initVerify(pair.public); update("${parts[0]}.${parts[1]}".toByteArray()) }
            assertTrue(verifier.verify(rawToDer(raw)))
        }
    }

    @Test fun `a p8 file is read back into the same key`() {
        val pem = "-----BEGIN " + "PRIVATE KEY-----\n" + Base64.getMimeEncoder(64, "\n".toByteArray()).encodeToString(pair.private.encoded) + "\n-----END PRIVATE KEY-----\n"
        assertEquals(pair.private, ApnsJwt.parseP8(pem))
    }
}
