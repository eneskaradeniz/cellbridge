#include "mic_state.h"

#include <stdio.h>
#include <string.h>
#include <unistd.h>

bool mic_state_write(const char *path, const struct mic_entry *entries, unsigned int count)
{
    FILE *f = fopen(path, "w");
    if (!f)
        return false;
    for (unsigned int i = 0; i < count; i++)
        fprintf(f, "%s=%s\n", entries[i].name, entries[i].value);
    bool ok = fflush(f) == 0 && fsync(fileno(f)) == 0;
    return fclose(f) == 0 && ok;
}

unsigned int mic_state_read(const char *path, struct mic_entry *entries, unsigned int max)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
    unsigned int n = 0;
    char line[2 * PROFILE_STR_MAX + 2];
    while (n < max && fgets(line, sizeof(line), f)) {
        line[strcspn(line, "\r\n")] = '\0';
        char *eq = strchr(line, '=');
        if (!eq || eq == line || strlen(eq + 1) >= PROFILE_STR_MAX || (size_t)(eq - line) >= PROFILE_STR_MAX)
            continue;
        *eq = '\0';
        strcpy(entries[n].name, line);
        strcpy(entries[n].value, eq + 1);
        n++;
    }
    fclose(f);
    return n;
}

void mic_state_clear(const char *path)
{
    unlink(path);
}
