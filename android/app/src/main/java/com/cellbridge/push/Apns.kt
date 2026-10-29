package com.cellbridge.push

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.security.PrivateKey
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

class ApnsCredentials(val keyId: String, val teamId: String, val key: PrivateKey)

/** The team's APNs key, if the owner put one on the phone (tools/install-apns-key.sh). Never part of the repository. */
fun interface ApnsCredentialSource {
    fun load(): ApnsCredentials?
}

@Serializable
private class ApnsConfig(val keyId: String, val teamId: String)

@Singleton
class FileApnsCredentials @Inject constructor(@ApplicationContext context: Context) : ApnsCredentialSource {
    private val dir = File(context.filesDir, "apns")

    override fun load(): ApnsCredentials? = runCatching {
        val config = Json { ignoreUnknownKeys = true }.decodeFromString<ApnsConfig>(File(dir, "config.json").readText())
        ApnsCredentials(config.keyId, config.teamId, ApnsJwt.parseP8(File(dir, "AuthKey.p8").readText()))
    }.getOrNull()
}

/** One HTTP/2 POST to APNs; returns the status code. */
interface ApnsTransport {
    suspend fun post(host: String, path: String, headers: Map<String, String>, body: ByteArray): Int
}

@Singleton
class OkHttpApnsTransport @Inject constructor() : ApnsTransport {
    private val client = OkHttpClient.Builder()
        .protocols(listOf(Protocol.HTTP_2, Protocol.HTTP_1_1))
        .callTimeout(10, TimeUnit.SECONDS)
        .build()

    override suspend fun post(host: String, path: String, headers: Map<String, String>, body: ByteArray): Int = withContext(Dispatchers.IO) {
        val request = Request.Builder().url("https://$host$path").post(body.toRequestBody("application/json".toMediaType()))
            .apply { headers.forEach { (name, value) -> header(name, value) } }.build()
        client.newCall(request).execute().use { it.code }
    }
}
