package com.cellbridge.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ToneParserTest {
    private val unknown = mutableListOf<String>()
    private val parser = ToneParser(mediaName = { if (it == 0x7f0c0001) "endcall" else null }, log = { unknown += it })

    // Lines as Telecom wrote them on the phone (call to a busy number).
    private val ringbackStart = "11-05 20:28:26.228  1997 31088 I Telecom : InCallTonePlayer: playToneGeneratorTone: toneType=23: CSW.SRR->ICTP.r(cap)@M5o"
    private val ringbackStop = "11-05 20:28:43.267  1997  2259 I Telecom : RingbackPlayer: Stopping the ringback tone for [Call id=TC@29, state=DISCONNECTED]"
    private val generatorStopped = "11-05 20:28:43.267  1997 31088 I Telecom : InCallTonePlayer: playToneGeneratorTone: tone playback stopped.: CSW.SRR->ICTP.r(cap)@M5o"
    private val mediaStart = "11-05 20:28:43.267  1997 31217 I Telecom : InCallTonePlayer: playMediaTone: toneResourceId=2131492865: CSW.sDc->ICTP.r(cap)@M+Y"
    private val mediaDone = "11-05 20:28:44.230  1997  1997 I Telecom : InCallTonePlayer: playMediaTone: toneResourceId=2131492865 completed."

    @Test fun `a generator tone starts with its constant`() = assertEquals(ToneEvent.Generator(23), parser.parse(ringbackStart))

    @Test fun `the ringback and the generator both stop the loop`() {
        assertEquals(ToneEvent.Stop, parser.parse(ringbackStop))
        assertEquals(ToneEvent.Stop, parser.parse(generatorStopped))
    }

    @Test fun `a media tone starts under the name of its file and its end is left to the sound itself`() {
        assertEquals(ToneEvent.Media("endcall"), parser.parse(mediaStart))
        assertNull(parser.parse(mediaDone))
    }

    @Test fun `a media tone of an unknown resource is reported and ignored`() {
        assertNull(parser.parse(mediaStart.replace("2131492865", "99")))
        assertEquals(listOf("tone: unknown media tone 99"), unknown)
    }

    @Test fun `other lines mean nothing`() {
        assertNull(parser.parse("11-05 20:28:43.267  1997  2721 I Telecom : CallAudioModeStateMachine: Message received: TONE_STOPPED_PLAYING."))
        assertNull(parser.parse(""))
    }
}
