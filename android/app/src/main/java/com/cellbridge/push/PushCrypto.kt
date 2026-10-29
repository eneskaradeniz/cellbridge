package com.cellbridge.push

import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** The push body's sealed box (docs/protocol.md): base64(nonce + AES-256-GCM ciphertext + tag), bound to a fixed context string. */
object PushCrypto {
    private const val NONCE_BYTES = 12
    private const val TAG_BITS = 128
    private val CONTEXT = "cellbridge-push-v1".toByteArray()
    private val random = SecureRandom()

    fun seal(key: ByteArray, plaintext: ByteArray, nonce: ByteArray = ByteArray(NONCE_BYTES).also(random::nextBytes)): String {
        require(key.size == 32 && nonce.size == NONCE_BYTES)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, nonce))
        cipher.updateAAD(CONTEXT)
        return Base64.getEncoder().encodeToString(nonce + cipher.doFinal(plaintext))
    }

    /** Null when the box is damaged or was sealed under another key. */
    fun open(key: ByteArray, sealed: String): ByteArray? = runCatching {
        val bytes = Base64.getDecoder().decode(sealed)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(TAG_BITS, bytes.copyOfRange(0, NONCE_BYTES)))
        cipher.updateAAD(CONTEXT)
        cipher.doFinal(bytes, NONCE_BYTES, bytes.size - NONCE_BYTES)
    }.getOrNull()
}
