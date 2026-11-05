/* Host-side unit tests for the SAVE_SENT payload: tests/run.sh */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "sms.h"

static size_t build(unsigned char *buf, long long date, const char *text)
{
    for (int i = 0; i < 8; i++)
        buf[i] = (unsigned char)((unsigned long long)date >> (8 * i));
    memcpy(buf + 8, text, strlen(text));
    return 8 + strlen(text);
}

int main(void)
{
    unsigned char buf[256];
    struct sent_sms s;
    size_t n = build(buf, 1793887644809LL, "+905551234567\nmerhaba: \"dünya\"\nikinci satır");
    assert(sms_parse_sent(buf, n, &s));
    assert(s.date_ms == 1793887644809LL && !strcmp(s.address, "+905551234567") && !strcmp(s.body, "merhaba: \"dünya\"\nikinci satır"));

    n = build(buf, 5, "0555 123-45 (67)\nx");
    assert(sms_parse_sent(buf, n, &s));
    n = build(buf, 5, "evil;rm\nx"); /* not a phone number */
    assert(!sms_parse_sent(buf, n, &s));
    n = build(buf, 5, "+90555\n"); /* empty body */
    assert(!sms_parse_sent(buf, n, &s));
    n = build(buf, 5, "+90555 no newline");
    assert(!sms_parse_sent(buf, n, &s));
    n = build(buf, 0, "+90555\nx"); /* no date */
    assert(!sms_parse_sent(buf, n, &s));
    n = build(buf, 5, "12\nx"); /* too short */
    assert(!sms_parse_sent(buf, n, &s));
    assert(!sms_parse_sent(buf, 5, &s));
    printf("sms_test: ok\n");
    return 0;
}
