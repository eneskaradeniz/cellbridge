package com.cellbridge.spam

import android.app.role.RoleManager
import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import javax.inject.Inject
import javax.inject.Singleton

/** A call or text that was blocked. [id] is unique; [number] is as the sender showed it. */
@Serializable
data class SpamEntry(val id: String, val kind: String, val number: String, val body: String? = null, val ts: Long, val reason: String)

data class SpamSnapshot(val items: List<SpamEntry>, val strict: Boolean, val screening: Boolean)

/** The spam side of the host as the control server and the SMS watcher see it. */
interface SpamDesk {
    /** Blocked items as they happen. */
    val blocked: SharedFlow<SpamEntry>

    /** Judges a fresh text and, when it is spam, records it (and announces it on [blocked]). */
    fun screenSms(from: String, body: String, ts: Long): Boolean

    /** Judges without recording: for filtering what is replayed to a client. */
    fun isSpamSms(from: String, body: String): Boolean

    suspend fun syncContacts(keys: List<String>)
    suspend fun report(number: String, body: String?)
    suspend fun notSpam(number: String)
    suspend fun setStrict(strict: Boolean)
    suspend fun snapshot(): SpamSnapshot
}

object NoSpam : SpamDesk {
    override val blocked: SharedFlow<SpamEntry> = MutableSharedFlow()
    override fun screenSms(from: String, body: String, ts: Long) = false
    override fun isSpamSms(from: String, body: String) = false
    override suspend fun syncContacts(keys: List<String>) = Unit
    override suspend fun report(number: String, body: String?) = Unit
    override suspend fun notSpam(number: String) = Unit
    override suspend fun setStrict(strict: Boolean) = Unit
    override suspend fun snapshot() = SpamSnapshot(emptyList(), strict = false, screening = false)
}

/** Everything the filter learns, persisted by a [SpamStore]. */
@Serializable
data class SpamState(
    val contacts: Set<String> = emptySet(),
    val blocked: Set<String> = emptySet(),
    val allowed: Set<String> = emptySet(),
    val fingerprints: Set<String> = emptySet(),
    val strict: Boolean = false,
    val log: List<SpamEntry> = emptyList(),
) {
    val rules get() = SpamRules(contacts, blocked, allowed, fingerprints, strict)
}

fun interface ScreeningRole {
    fun held(): Boolean
}

@Singleton
class SpamGuard @Inject constructor(
    private val store: SpamStore,
    private val role: ScreeningRole,
) : SpamDesk {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val saving = Mutex()
    @Volatile private var state: SpamState = store.load()
    private val _blocked = MutableSharedFlow<SpamEntry>(extraBufferCapacity = 16)

    override val blocked: SharedFlow<SpamEntry> = _blocked.asSharedFlow()

    @Synchronized
    private fun update(change: (SpamState) -> SpamState) {
        state = change(state)
        scope.launch { saving.withLock { runCatching { store.save(state) }.onFailure { Log.w(TAG, "spam rules not saved", it) } } }
    }

    private fun record(kind: String, number: String, body: String?, ts: Long, reason: String, announce: Boolean = true): SpamEntry {
        val entry = SpamEntry("$kind$ts-${state.log.size}", kind, number, body, ts, reason)
        update { it.copy(log = (it.log + entry).takeLast(MAX_LOG)) }
        if (announce) _blocked.tryEmit(entry)
        return entry
    }

    /** Called by the call screening service; true = reject the call. Never logs the number. */
    fun screenCall(number: String?): Boolean {
        val verdict = SpamFilter.call(number, state.rules)
        if (verdict.spam) {
            record("call", number.orEmpty(), null, System.currentTimeMillis(), verdict.reason!!)
            Log.i(TAG, "Blocked call (${verdict.reason})")
        }
        return verdict.spam
    }

    override fun screenSms(from: String, body: String, ts: Long): Boolean {
        val verdict = SpamFilter.sms(from, body, state.rules)
        if (verdict.spam) {
            record("sms", from, body, ts, verdict.reason!!)
            Log.i(TAG, "Blocked text (${verdict.reason})")
        }
        return verdict.spam
    }

    override fun isSpamSms(from: String, body: String) = SpamFilter.sms(from, body, state.rules).spam

    override suspend fun syncContacts(keys: List<String>) =
        update { it.copy(contacts = keys.mapNotNull { k -> SpamFilter.key(k) }.toSet()) }

    override suspend fun report(number: String, body: String?) {
        val key = SpamFilter.key(number) ?: return
        update { it.copy(blocked = it.blocked + key, allowed = it.allowed - key, fingerprints = it.fingerprints + listOfNotNull(body?.let(SpamFilter::fingerprint))) }
        if (state.log.none { it.kind == "sms" && SpamFilter.key(it.number) == key && it.body == body }) {
            record(if (body != null) "sms" else "call", number, body, System.currentTimeMillis(), "reported", announce = false)
        }
    }

    override suspend fun notSpam(number: String) {
        val key = SpamFilter.key(number) ?: return
        update { s ->
            val fingerprints = s.log.filter { SpamFilter.key(it.number) == key }.mapNotNull { it.body?.let(SpamFilter::fingerprint) }.toSet()
            s.copy(
                blocked = s.blocked - key, allowed = s.allowed + key, fingerprints = s.fingerprints - fingerprints,
                log = s.log.filterNot { SpamFilter.key(it.number) == key },
            )
        }
    }

    override suspend fun setStrict(strict: Boolean) = update { it.copy(strict = strict) }

    override suspend fun snapshot() = SpamSnapshot(state.log.reversed(), state.strict, role.held())

    private companion object {
        const val TAG = "CellBridge"
        const val MAX_LOG = 200
    }
}

/** Whether Telecom hands incoming calls to the screening service. */
class PlatformScreeningRole @Inject constructor(@ApplicationContext private val context: Context) : ScreeningRole {
    override fun held() = runCatching {
        context.getSystemService(RoleManager::class.java).isRoleHeld(RoleManager.ROLE_CALL_SCREENING)
    }.getOrDefault(false)
}
