package com.cellbridge.push

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Base64

class PushCryptoTest {
    private val key = ByteArray(32) { it.toByte() }

    // Produced with Python's cryptography (AESGCM, key 0..31, nonce 100..111, context "cellbridge-push-v1"); the iOS test opens the same box.
    private val sealed = "ZGVmZ2hpamtsbW5vMzm9BxWFH/ocWH2L91FY327gaH/mDpYAheuOY8KTkH2h2HHxfiCoN9/fWlGcL6/tIXnZi0loPNFvnaLTME9cyiEDfKyeXRM="
    private val plain = """{"callId":"c-42","number":"+905551112233","name":"Ali"}"""

    @Test fun `opens a box sealed by another implementation`() {
        assertEquals(plain, PushCrypto.open(key, sealed)?.decodeToString())
    }

    @Test fun `seals the same bytes with the same nonce`() {
        assertEquals(sealed, PushCrypto.seal(key, plain.toByteArray(), ByteArray(12) { (100 + it).toByte() }))
    }

    @Test fun `round trips with a random nonce`() {
        val box = PushCrypto.seal(key, "hello".toByteArray())
        assertArrayEquals("hello".toByteArray(), PushCrypto.open(key, box))
        assertEquals(false, box == PushCrypto.seal(key, "hello".toByteArray())) // nonces differ
    }

    @Test fun `another key or a damaged box opens to nothing`() {
        assertNull(PushCrypto.open(ByteArray(32) { 9 }, sealed))
        val damaged = Base64.getDecoder().decode(sealed).also { it[20] = (it[20] + 1).toByte() }
        assertNull(PushCrypto.open(key, Base64.getEncoder().encodeToString(damaged)))
        assertNull(PushCrypto.open(key, "not base64 !!"))
    }
}
