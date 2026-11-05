package com.cellbridge.audio

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import javax.inject.Inject
import javax.inject.Singleton

/** A sound the phone itself plays during a call (it is not in the relayed audio): see docs/protocol.md `tone`. */
sealed interface ToneEvent {
    /** An Android `ToneGenerator` tone (23 = ringback, 17 = busy, ...). */
    data class Generator(val id: Int) : ToneEvent

    /** A sound file of Telecom (`endcall`, ...). */
    data class Media(val name: String) : ToneEvent

    /** The looping generator tone ended. */
    data object Stop : ToneEvent
}

/**
 * Reads the lines Telecom logs about the tones it plays (the daemon forwards them) and says what the iPhone should
 * sound like. Only what the log says is acted on: a tone that is not in the log is not played, as on the phone.
 * [mediaName] turns a Telecom resource id into the name of its file; [log] hears about lines it could not make sense of.
 */
class ToneParser(private val mediaName: (Int) -> String?, private val log: (String) -> Unit = {}) {
    fun parse(line: String): ToneEvent? {
        generatorStart.find(line)?.let { return ToneEvent.Generator(it.groupValues[1].toInt()) }
        if ("playToneGeneratorTone: tone playback stopped" in line || "RingbackPlayer: Stopping the ringback tone" in line) return ToneEvent.Stop
        mediaStart.find(line)?.let { match ->
            if ("completed" in line || "stopped" in line) return null // it ends on its own
            val id = match.groupValues[1].toLongOrNull()?.toInt() ?: return null
            val name = mediaName(id)
            if (name == null) log("tone: unknown media tone $id")
            return name?.let(ToneEvent::Media)
        }
        return null
    }

    private companion object {
        val generatorStart = Regex("""playToneGeneratorTone: toneType=(\d+)""")
        val mediaStart = Regex("""playMediaTone: toneResourceId=(\d+)""")
    }
}

/** Process-wide stream of tone events, from the daemon's connection to the control server. */
@Singleton
class ToneEvents @Inject constructor() {
    private val _events = MutableSharedFlow<ToneEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<ToneEvent> = _events.asSharedFlow()

    fun emit(event: ToneEvent) { _events.tryEmit(event) }
}
