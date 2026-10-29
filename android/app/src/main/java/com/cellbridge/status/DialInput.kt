package com.cellbridge.status

/** What may be dialed: digits, `*`, `#`, and a `+` only in front (a number pasted or passed in with spaces, dashes and brackets). */
fun sanitizeDial(text: String): String {
    val kept = text.filter { it in '0'..'9' || it == '*' || it == '#' || it == '+' }
    if (kept.isEmpty()) return ""
    return kept.first().toString() + kept.drop(1).filter { it != '+' }
}
