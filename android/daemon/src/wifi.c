#include "wifi.h"
#include "run.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>


#define SOFTAP_FILE "/data/misc/apexdata/com.android.wifi/WifiConfigStoreSoftAp.xml"
#define STORE_FILE "/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml"

/* Copies the XML text up to the next '<' with the five predefined entities resolved. Returns false if it does not fit. */
static bool xml_text(const char *p, char *out, size_t cap)
{
    static const struct { const char *ent; char ch; } ents[] = {
        { "&quot;", '"' }, { "&amp;", '&' }, { "&lt;", '<' }, { "&gt;", '>' }, { "&apos;", '\'' },
    };
    size_t n = 0;
    while (*p && *p != '<') {
        char c = *p;
        size_t used = 1;
        if (c == '&') {
            bool known = false;
            for (size_t i = 0; i < sizeof(ents) / sizeof(ents[0]); i++) {
                size_t len = strlen(ents[i].ent);
                if (!strncmp(p, ents[i].ent, len)) {
                    c = ents[i].ch;
                    used = len;
                    known = true;
                    break;
                }
            }
            if (!known)
                return false;
        }
        if (n + 1 >= cap)
            return false;
        out[n++] = c;
        p += used;
    }
    out[n] = '\0';
    return true;
}

/* The text of the element `<… name="NAME">text<`, searching from `from`; NULL if there is none. */
static const char *xml_find(const char *from, const char *name)
{
    char key[48];
    snprintf(key, sizeof(key), "name=\"%s\">", name);
    const char *at = strstr(from, key);
    return at ? at + strlen(key) : NULL;
}

/* A quoted SSID ("name" in the store) without its quotes; hex SSIDs (no quotes) are not handled. */
static bool unquote_ssid(char *s)
{
    size_t n = strlen(s);
    if (n < 3 || s[0] != '"' || s[n - 1] != '"' || n - 2 >= WIFI_SSID_MAX || strchr(s, '\n'))
        return false;
    memmove(s, s + 1, n - 2);
    s[n - 2] = '\0';
    return true;
}

bool wifi_parse_softap(const char *xml, struct softap_config *out)
{
    const char *at;
    char ssid[WIFI_SSID_MAX + 2];
    memset(out, 0, sizeof(*out));
    if (!(at = xml_find(xml, "WifiSsid")) || !xml_text(at, ssid, sizeof(ssid)) || !unquote_ssid(ssid))
        return false;
    strcpy(out->ssid, ssid);
    if (!strstr(xml, "name=\"SecurityType\" value=\"2\"")) /* 2 = WPA2-PSK */
        return false;
    if (!(at = xml_find(xml, "Passphrase")) || !xml_text(at, out->pass, sizeof(out->pass)) || strlen(out->pass) < 8)
        return false;
    const char *band = strstr(xml, "name=\"Band\" value=\"");
    out->band = band ? atoi(band + strlen("name=\"Band\" value=\"")) : 0;
    return true;
}

size_t wifi_parse_saved(const char *xml, char *out, size_t cap)
{
    size_t n = 0;
    const char *at = xml;
    char ssid[WIFI_SSID_MAX + 2];
    while ((at = xml_find(at, "SSID"))) {
        if (!xml_text(at, ssid, sizeof(ssid)) || !unquote_ssid(ssid))
            continue;
        size_t len = strlen(ssid);
        if (n + len + 1 >= cap)
            break;
        memcpy(out + n, ssid, len);
        out[n + len] = '\n';
        n += len + 1;
    }
    if (cap)
        out[n] = '\0';
    return n;
}

bool wifi_parse_connected(const char *text, char *out, size_t cap)
{
    static const char key[] = "Wifi is connected to \"";
    const char *at = strstr(text, key);
    if (!at)
        return false;
    at += sizeof(key) - 1;
    const char *end = strchr(at, '"');
    if (!end || (size_t)(end - at) >= WIFI_SSID_MAX || (size_t)(end - at) >= cap || memchr(at, '\n', (size_t)(end - at)))
        return false;
    memcpy(out, at, (size_t)(end - at));
    out[end - at] = '\0';
    return true;
}

static bool read_file(const char *path, char *buf, size_t cap)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return false;
    size_t n = fread(buf, 1, cap - 1, f);
    fclose(f);
    buf[n] = '\0';
    return true;
}

bool wifi_hotspot(bool on, char *reason, size_t reason_cap)
{
    char out[4096];
    if (!on) {
        char *argv[] = { "cmd", "wifi", "stop-softap", NULL };
        bool ok = run_command(argv, out, sizeof(out), 10000);
        if (!ok)
            snprintf(reason, reason_cap, "stop timed out");
        return ok;
    }
    static char xml[16384];
    struct softap_config cfg;
    if (!read_file(SOFTAP_FILE, xml, sizeof(xml)) || !wifi_parse_softap(xml, &cfg)) {
        snprintf(reason, reason_cap, "hotspot settings unreadable (WPA2 and a named network are required)");
        return false;
    }
    char *band = cfg.band == 1 ? "2" : cfg.band == 2 ? "5" : "any";
    char *argv[] = { "cmd", "wifi", "start-softap", cfg.ssid, "wpa2", cfg.pass, "-b", band, NULL };
    bool ran = run_command(argv, out, sizeof(out), 20000);
    memset(cfg.pass, 0, sizeof(cfg.pass));
    if (!ran || !strstr(out, "enabled successfully")) {
        snprintf(reason, reason_cap, "hotspot did not start");
        return false;
    }
    return true;
}

size_t wifi_info(char *out, size_t cap)
{
    char status[8192];
    char ssid[WIFI_SSID_MAX] = "";
    char *argv[] = { "cmd", "wifi", "status", NULL };
    if (run_command(argv, status, sizeof(status), 5000))
        wifi_parse_connected(status, ssid, sizeof(ssid));
    size_t n = (size_t)snprintf(out, cap, "%s\n", ssid);
    static char xml[65536];
    if (n < cap && read_file(STORE_FILE, xml, sizeof(xml)))
        n += wifi_parse_saved(xml, out + n, cap - n);
    return n;
}
