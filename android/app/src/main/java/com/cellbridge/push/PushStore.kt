package com.cellbridge.push

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.util.Base64
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Where to send pushes: the iPhone's PushKit token (calls), its ordinary notification token and topic (texts, absent until the
 * client sends them) and the key only the two phones know.
 */
class PushTarget(
    val token: String, val sandbox: Boolean, val topic: String, val key: ByteArray,
    val alertToken: String? = null, val alertTopic: String? = null,
    /** What ActivityKit gave the client for starting a Live Activity by push. */
    val liveStartToken: String? = null,
) {
    /** The text token is gone (Apple said so); calls still work. */
    fun withoutAlert() = PushTarget(token, sandbox, topic, key, liveStartToken = liveStartToken)

    fun withLiveStart(token: String?) = PushTarget(this.token, sandbox, topic, key, alertToken, alertTopic, token)
}

interface PushStore {
    fun load(): PushTarget?
    fun save(target: PushTarget)
    fun clear()
}

@Serializable
private class Stored(
    val token: String, val sandbox: Boolean, val topic: String, val key: String,
    val alertToken: String? = null, val alertTopic: String? = null, val liveStartToken: String? = null,
)

/** One small file in the app's private storage, like the daemon token. */
@Singleton
class FilePushStore @Inject constructor(@ApplicationContext context: Context) : PushStore {
    private val file = File(context.filesDir, "push.json")

    @Synchronized
    override fun load(): PushTarget? = runCatching {
        val s = Json.decodeFromString<Stored>(file.readText())
        PushTarget(s.token, s.sandbox, s.topic, Base64.getDecoder().decode(s.key), s.alertToken, s.alertTopic, s.liveStartToken)
    }.getOrNull()

    @Synchronized
    override fun save(target: PushTarget) {
        file.writeText(Json.encodeToString(Stored.serializer(), Stored(target.token, target.sandbox, target.topic, Base64.getEncoder().encodeToString(target.key), target.alertToken, target.alertTopic, target.liveStartToken)))
        file.setReadable(false, false)
        file.setReadable(true, true)
        file.setWritable(false, false)
        file.setWritable(true, true)
    }

    @Synchronized
    override fun clear() { file.delete() }
}
