package com.cellbridge.spam

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

interface SpamStore {
    fun load(): SpamState
    fun save(state: SpamState)
}

/** One small file in the app's private storage, like the push target. */
@Singleton
class FileSpamStore @Inject constructor(@ApplicationContext context: Context) : SpamStore {
    private val file = File(context.filesDir, "spam.json")
    private val json = Json { ignoreUnknownKeys = true }

    @Synchronized
    override fun load(): SpamState = runCatching { json.decodeFromString(SpamState.serializer(), file.readText()) }.getOrDefault(SpamState())

    @Synchronized
    override fun save(state: SpamState) {
        file.writeText(json.encodeToString(SpamState.serializer(), state))
        file.setReadable(false, false)
        file.setReadable(true, true)
        file.setWritable(false, false)
        file.setWritable(true, true)
    }
}
