package com.cellbridge.spam

import java.text.Normalizer

/** What the filter knows. Numbers are [SpamFilter.key]s. */
data class SpamRules(
    val contacts: Set<String> = emptySet(),
    val blocked: Set<String> = emptySet(),
    val allowed: Set<String> = emptySet(),
    /** [SpamFilter.fingerprint]s of reported texts. */
    val fingerprints: Set<String> = emptySet(),
    val strict: Boolean = false,
)

/** [reason] is one of the protocol's spam reasons; null when [spam] is false. */
data class Verdict(val spam: Boolean, val reason: String? = null) {
    companion object {
        val PASS = Verdict(false)
        fun spam(reason: String) = Verdict(true, reason)
    }
}

/** Pure scoring of calls and texts; the rules are in docs/protocol.md ("Spam filter"). */
object SpamFilter {
    const val THRESHOLD = 60
    private const val MIN_KEY = 7 // shorter numbers are services (112, 444…) and never filtered unless reported

    /** The last 10 digits of a phone number, a sender name upper-cased, null for nothing usable. */
    fun key(number: String?): String? {
        val text = number?.trim().orEmpty()
        if (text.isEmpty()) return null
        if (text.any { it.isLetter() }) return text.uppercase()
        val digits = text.filter { it.isDigit() }
        return if (digits.isEmpty()) null else digits.takeLast(10)
    }

    private fun numeric(key: String) = key.all { it.isDigit() }

    private fun known(key: String?, rules: SpamRules) = key != null && (key in rules.allowed || key in rules.contacts)

    private fun reported(key: String?, rules: SpamRules): Verdict? =
        if (key != null && key in rules.blocked) Verdict.spam("reported") else null

    private fun inReportedRange(key: String, rules: SpamRules) =
        numeric(key) && key.length == 10 && rules.blocked.any { it.length == 10 && numeric(it) && it.take(8) == key.take(8) }

    private fun foreign(raw: String): Boolean {
        val t = raw.trim().filter { it.isDigit() || it == '+' }
        return (t.startsWith("+") && !t.startsWith("+90")) || (t.startsWith("00") && !t.startsWith("0090"))
    }

    fun call(number: String?, rules: SpamRules): Verdict {
        val key = key(number)
        reported(key, rules)?.let { return it }
        if (known(key, rules)) return Verdict.PASS
        if (key == null) return if (rules.strict) Verdict.spam("withheld") else Verdict.PASS // withheld alone is not enough
        if (numeric(key) && key.length < MIN_KEY) return Verdict.PASS
        if (rules.strict) return Verdict.spam("unknown")
        val signals = buildList {
            if (inReportedRange(key, rules)) add(50 to "range")
            if (key.startsWith("850")) add(40 to "marketing")
            if (number != null && foreign(number)) add(30 to "foreign")
        }
        return if (signals.sumOf { it.first } >= THRESHOLD) Verdict.spam(signals.maxBy { it.first }.second) else Verdict.PASS
    }

    fun sms(from: String, body: String, rules: SpamRules): Verdict {
        val key = key(from)
        reported(key, rules)?.let { return it }
        if (known(key, rules)) return Verdict.PASS
        val text = fold(body)
        fingerprint(body)?.let { if (it in rules.fingerprints) return Verdict.spam("same_text") }
        if (key != null && numeric(key) && key.length < MIN_KEY) return Verdict.PASS
        val link = LINK.containsMatchIn(text)
        val gambling = GAMBLING.containsMatchIn(text)
        val scam = SCAM.count { it in text }
        if (gambling) return Verdict.spam("gambling")
        if (scam * 30 + (if (link) 30 else 0) >= THRESHOLD) return Verdict.spam(if (scam > 0) "scam" else "link")
        val numericSender = key != null && numeric(key)
        if (rules.strict && numericSender) return Verdict.spam("unknown")
        return Verdict.PASS
    }

    /** Lower case without accents or Turkish dots, so "İndirim" and "indirim" match. */
    fun fold(text: String): String =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(Regex("\\p{Mn}+"), "").lowercase().replace('ı', 'i')

    /** The first 40 letters of a text, or null when it is too short to tell texts apart. */
    fun fingerprint(body: String): String? =
        fold(body).filter { it.isLetter() }.take(40).takeIf { it.length >= 25 }

    private val LINK = Regex("""https?://|www\.|\b[a-z0-9-]+\.(com|net|org|xyz|top|click|link|site|online|bet|cc|me)\b|bit\.ly|tinyurl|t\.co/""")
    private val GAMBLING = Regex(
        """bahis|casino|kumar|freespin|free spin|deneme bonusu|hosgeldin bonusu|\bbonus\b|\bslot\b|rulet|jackpot|\bbet\b|1xbet|betboo|betist|betmatik|bettilt|betturk|\.bet\b""",
    )
    private val SCAM = listOf(
        "kargonuz", "paketiniz", "teslim edilemedi", "odenmemis", "cezaniz", "askiya", "dogrulayin", "kazandiniz", "cekilis",
        "odul", "kredi limit", "e-devlet", "vergi borc", "tiklayin", "hesabiniz kapat",
    )
}
