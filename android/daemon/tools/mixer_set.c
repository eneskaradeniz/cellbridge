/* Test helper: writes an INT mixer control array without tinymix's range check (it rejects 0..-1 ranges).
 * usage: mixer_set <control name> [v0 v1 ...]   (no values = just print the current ones) */
#include <stdio.h>
#include <stdlib.h>
#include <tinyalsa/mixer.h>

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <control> [values...]\n", argv[0]); return 2; }
    struct mixer *m = mixer_open(0);
    if (!m) { fprintf(stderr, "no mixer\n"); return 1; }
    struct mixer_ctl *c = mixer_get_ctl_by_name(m, argv[1]);
    if (!c) { fprintf(stderr, "no control '%s'\n", argv[1]); mixer_close(m); return 1; }
    unsigned n = mixer_ctl_get_num_values(c);
    if (argc > 2) {
        int v[8] = {0};
        for (unsigned i = 0; i < n && i < 8 && (int)i + 2 < argc; i++) v[i] = (int)strtol(argv[i + 2], NULL, 0);
        int rc = mixer_ctl_set_array(c, v, n);
        printf("set rc=%d\n", rc);
    }
    for (unsigned i = 0; i < n; i++) printf("%d ", mixer_ctl_get_value(c, i));
    printf("\n");
    mixer_close(m);
    return 0;
}
