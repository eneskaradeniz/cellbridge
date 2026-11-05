#include "sms.h"

#include <stdio.h>
#include <string.h>

#include "run.h"

static bool plain_number(const char *a)
{
    size_t n = strlen(a);
    if (n < 3 || n >= SMS_ADDRESS_MAX)
        return false;
    for (size_t i = 0; i < n; i++) {
        char c = a[i];
        bool ok = (c >= '0' && c <= '9') || c == ' ' || c == '(' || c == ')' || c == '-' || (c == '+' && i == 0);
        if (!ok)
            return false;
    }
    return true;
}

bool sms_parse_sent(const unsigned char *payload, size_t len, struct sent_sms *out)
{
    if (len < 8 + 3 + 1 + 1)
        return false;
    uint64_t date = 0;
    for (int i = 7; i >= 0; i--)
        date = (date << 8) | payload[i];
    if (date == 0 || date > (uint64_t)INT64_MAX)
        return false;
    const unsigned char *text = payload + 8;
    size_t text_len = len - 8;
    const unsigned char *nl = memchr(text, '\n', text_len);
    if (!nl || (size_t)(nl - text) >= SMS_ADDRESS_MAX)
        return false;
    size_t body_len = text_len - (size_t)(nl - text) - 1;
    if (body_len == 0 || body_len >= SMS_BODY_MAX || memchr(nl + 1, '\0', body_len) || memchr(text, '\0', (size_t)(nl - text)))
        return false;
    memcpy(out->address, text, (size_t)(nl - text));
    out->address[nl - text] = '\0';
    memcpy(out->body, nl + 1, body_len);
    out->body[body_len] = '\0';
    out->date_ms = (int64_t)date;
    return plain_number(out->address);
}

bool sms_save_sent(const struct sent_sms *sms, char *reason, size_t reason_cap)
{
    char address[SMS_ADDRESS_MAX + 16], body[SMS_BODY_MAX + 16], date[40];
    snprintf(address, sizeof(address), "address:s:%s", sms->address);
    snprintf(body, sizeof(body), "body:s:%s", sms->body);
    snprintf(date, sizeof(date), "date:l:%lld", (long long)sms->date_ms);
    char *argv[] = { "content", "insert", "--uri", "content://sms/sent", "--bind", address, "--bind", body, "--bind", date,
                     "--bind", "read:i:1", "--bind", "type:i:2", NULL };
    char out[512];
    bool ran = run_command(argv, out, sizeof(out), 10000);
    if (!ran || strstr(out, "Exception") || strstr(out, "Error")) {
        snprintf(reason, reason_cap, "could not file the text");
        return false;
    }
    return true;
}
