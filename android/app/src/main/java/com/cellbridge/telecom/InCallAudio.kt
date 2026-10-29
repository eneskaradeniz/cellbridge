package com.cellbridge.telecom

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/** What the phone's own call screen can do to the audio of the running call. Set by the InCallService while it is bound. */
interface InCallAudioControl {
    fun setMuted(muted: Boolean)
    fun setSpeaker(on: Boolean)
}

data class InCallAudioState(val muted: Boolean = false, val speaker: Boolean = false)

@Singleton
class InCallAudio @Inject constructor() {
    private val _state = MutableStateFlow(InCallAudioState())

    val state: StateFlow<InCallAudioState> = _state.asStateFlow()

    @Volatile var control: InCallAudioControl? = null

    fun update(muted: Boolean, speaker: Boolean) { _state.value = InCallAudioState(muted, speaker) }

    fun setMuted(muted: Boolean) { control?.setMuted(muted) }

    fun setSpeaker(on: Boolean) { control?.setSpeaker(on) }
}
