#ifndef CELLBRIDGE_SMS_H
#define CELLBRIDGE_SMS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { SMS_ADDRESS_MAX = 21, SMS_BODY_MAX = 4096 };

struct sent_sms {
    int64_t date_ms;
    char address[SMS_ADDRESS_MAX];
    char body[SMS_BODY_MAX];
};

/* SAVE_SENT payload: i64 date (LE), address, '\n', body. False if it is malformed or the address is not a plain phone number. */
bool sms_parse_sent(const unsigned char *payload, size_t len, struct sent_sms *out);

/* Files the text in the system SMS database's sent box (`content insert`, so root is needed). */
bool sms_save_sent(const struct sent_sms *sms, char *reason, size_t reason_cap);

#endif
