#ifndef CELLBRIDGE_WIFI_H
#define CELLBRIDGE_WIFI_H

#include <stdbool.h>
#include <stddef.h>

enum { WIFI_SSID_MAX = 33, WIFI_PASS_MAX = 64 };

struct softap_config {
    char ssid[WIFI_SSID_MAX];
    char pass[WIFI_PASS_MAX + 1];
    int band; /* 1 = 2.4 GHz, 2 = 5 GHz, anything else: any */
};

/* Pure parsers (tests/wifi_test.c). `xml` is a Wi-Fi config store file, `text` the output of `cmd wifi status`. */
bool wifi_parse_softap(const char *xml, struct softap_config *out); /* false: missing, hex ssid or not WPA2 */
size_t wifi_parse_saved(const char *xml, char *out, size_t cap);    /* saved SSIDs, one per line; returns bytes */
bool wifi_parse_connected(const char *text, char *out, size_t cap); /* false: not connected */

/* Actions (run `cmd wifi …`, so they need the Wi-Fi service and root). */
bool wifi_hotspot(bool on, char *reason, size_t reason_cap);
size_t wifi_info(char *out, size_t cap); /* connected SSID line, then every saved SSID line */

#endif
