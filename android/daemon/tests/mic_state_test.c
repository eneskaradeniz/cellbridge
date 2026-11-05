/* Host-side unit tests for the mic state file: tests/run.sh */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

#include "mic_state.h"

int main(void)
{
    char path[] = "/tmp/mic_state_test_XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    close(fd);

    struct mic_entry in[2] = { { "DEC1 MUX", "ADC1" }, { "DEC2 MUX", "ADC2" } };
    assert(mic_state_write(path, in, 2));
    struct mic_entry out[MIC_MAX];
    assert(mic_state_read(path, out, MIC_MAX) == 2);
    assert(!strcmp(out[0].name, "DEC1 MUX") && !strcmp(out[0].value, "ADC1"));
    assert(!strcmp(out[1].name, "DEC2 MUX") && !strcmp(out[1].value, "ADC2"));

    FILE *f = fopen(path, "w"); /* garbage lines are skipped, a half-written file does not crash the reader */
    fputs("no equals sign\n=novalue\nDEC3 MUX=ZERO\nDEC4 MUX=ADC", f);
    fclose(f);
    assert(mic_state_read(path, out, MIC_MAX) == 2);
    assert(!strcmp(out[0].name, "DEC3 MUX"));
    assert(mic_state_read(path, out, 1) == 1); /* never past the caller's buffer */

    mic_state_clear(path);
    assert(mic_state_read(path, out, MIC_MAX) == 0); /* no file: nothing to undo */
    printf("mic_state_test: ok\n");
    return 0;
}
