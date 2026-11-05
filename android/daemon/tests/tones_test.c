/* Host-side unit tests for the tone line filter: tests/run.sh */
#include <assert.h>
#include <stdio.h>

#include "log.h"
#include "tones.h"

/* The real daemon_log writes to the Android log, which does not exist on the host. */
void daemon_log(const char *fmt, ...) { (void)fmt; }

int main(void)
{
    assert(tones_is_relevant("11-05 20:28:26.228  1997 31088 I Telecom : InCallTonePlayer: playToneGeneratorTone: toneType=23: CSW.SRR"));
    assert(tones_is_relevant("11-05 20:28:43.267  1997  2259 I Telecom : RingbackPlayer: Stopping the ringback tone for [Call id=TC@29]"));
    assert(tones_is_relevant("11-05 20:28:43.267  1997 31217 I Telecom : InCallTonePlayer: playMediaTone: toneResourceId=2131492865"));
    assert(!tones_is_relevant("11-05 20:28:43.267  1997  1997 I Telecom : CallAudioModeStateMachine: Message received: TONE_STOPPED_PLAYING."));
    assert(!tones_is_relevant(""));
    printf("tones_test: ok\n");
    return 0;
}
