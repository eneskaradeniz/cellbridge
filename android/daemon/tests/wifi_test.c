/* Host-side unit tests for the Wi-Fi config parsers: tests/run.sh */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "wifi.h"

int main(void)
{
    const char *softap =
        "<string name=\"WifiSsid\">&quot;MI 8 &amp; Lite&quot;</string>\n<boolean name=\"HiddenSSID\" value=\"false\" />\n"
        "<int name=\"SecurityType\" value=\"2\" />\n<string name=\"Passphrase\">pa&lt;ss&gt;word1</string>\n"
        "<BandChannelMap><BandChannel><int name=\"Band\" value=\"1\" /></BandChannel></BandChannelMap>";
    struct softap_config cfg;
    assert(wifi_parse_softap(softap, &cfg));
    assert(!strcmp(cfg.ssid, "MI 8 & Lite") && !strcmp(cfg.pass, "pa<ss>word1") && cfg.band == 1);

    assert(!wifi_parse_softap("", &cfg));
    assert(!wifi_parse_softap("<string name=\"WifiSsid\">4d49</string><int name=\"SecurityType\" value=\"2\" />", &cfg)); /* hex ssid */
    char open[512];
    snprintf(open, sizeof(open), "%s", softap);
    memcpy(strstr(open, "value=\"2\""), "value=\"0\"", 9); /* open network: never started from here */
    assert(!wifi_parse_softap(open, &cfg));
    assert(!wifi_parse_softap(
        "<string name=\"WifiSsid\">&quot;A&quot;</string><int name=\"SecurityType\" value=\"2\" /><string name=\"Passphrase\">short</string>", &cfg));

    const char *store =
        "<Network><string name=\"SSID\">&quot;HomeNet_2.4GHz&quot;</string></Network>"
        "<Network><string name=\"SSID\">&quot;HomeNet_5GHz&quot;</string></Network>"
        "<Network><string name=\"SSID\">0a1b</string></Network>"; /* hex: skipped */
    char saved[256];
    size_t n = wifi_parse_saved(store, saved, sizeof(saved));
    assert(n == strlen("HomeNet_2.4GHz\nHomeNet_5GHz\n") && !strcmp(saved, "HomeNet_2.4GHz\nHomeNet_5GHz\n"));
    char tiny[20];
    n = wifi_parse_saved(store, tiny, sizeof(tiny)); /* never past the caller's buffer */
    assert(n < sizeof(tiny) && !strcmp(tiny, "HomeNet_2.4GHz\n"));

    char ssid[WIFI_SSID_MAX];
    assert(wifi_parse_connected("Wifi is enabled\nWifi is connected to \"HomeNet_5GHz\"\nWifiInfo: x", ssid, sizeof(ssid)));
    assert(!strcmp(ssid, "HomeNet_5GHz"));
    assert(!wifi_parse_connected("Wifi is enabled\nWifi is not connected", ssid, sizeof(ssid)));
    assert(!wifi_parse_connected("Wifi is connected to \"unterminated", ssid, sizeof(ssid)));
    printf("wifi_test: ok\n");
    return 0;
}
