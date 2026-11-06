package com.cellbridge.spam

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SpamFilterTest {
    private val none = SpamRules()

    @Test fun `key is the last ten digits or the upper-cased sender name`() {
        assertEquals("5321234567", SpamFilter.key("+90 532 123 45 67"))
        assertEquals("5321234567", SpamFilter.key("0532-123-45-67"))
        assertEquals("GARANTI", SpamFilter.key("garanti"))
        assertNull(SpamFilter.key(" "))
        assertNull(SpamFilter.key(null))
    }

    @Test fun `unknown ordinary caller passes, contact and allowed always pass`() {
        assertFalse(SpamFilter.call("+905321234567", none).spam)
        assertFalse(SpamFilter.call("+905321234567", SpamRules(contacts = setOf("5321234567"), strict = true)).spam)
        assertFalse(SpamFilter.call("05321234567", SpamRules(allowed = setOf("5321234567"), strict = true)).spam)
    }

    @Test fun `reported number is blocked even when it is a contact`() {
        val rules = SpamRules(contacts = setOf("5321234567"), blocked = setOf("5321234567"))
        assertEquals("reported", SpamFilter.call("05321234567", rules).reason)
        assertEquals("reported", SpamFilter.sms("+905321234567", "selam", rules).reason)
    }

    @Test fun `call signals add up to the threshold`() {
        assertFalse(SpamFilter.call("08501234567", none).spam) // 40
        assertFalse(SpamFilter.call("+4915112345678", none).spam) // 30
        val range = SpamRules(blocked = setOf("5321234567"))
        assertFalse(SpamFilter.call("05321234999", range).spam) // 50
        val both = SpamRules(blocked = setOf("8501234567"))
        assertEquals("range", SpamFilter.call("08501234599", both).reason) // 50 + 40
    }

    @Test fun `short numbers are never filtered, strict or not`() {
        assertFalse(SpamFilter.call("4442", SpamRules(strict = true)).spam)
        assertFalse(SpamFilter.call("112", none).spam)
    }

    @Test fun `strict blocks unknown and withheld callers`() {
        val strict = SpamRules(strict = true)
        assertEquals("unknown", SpamFilter.call("05321234567", strict).reason)
        assertEquals("withheld", SpamFilter.call(null, strict).reason)
        assertFalse(SpamFilter.call(null, none).spam)
    }

    @Test fun `gambling text is spam`() {
        assertEquals("gambling", SpamFilter.sms("5551112233", "Hoşgeldin BONUSU 500 TL! Hemen kayıt ol", none).reason)
        assertEquals("gambling", SpamFilter.sms("BETX", "Canlı bahis fırsatı", none).reason)
    }

    @Test fun `scam text with a link is spam, a link alone or a lone phrase is not`() {
        assertTrue(SpamFilter.sms("5551112233", "Paketiniz teslim edilemedi, adresi doğrulayın http://x.co/a", none).spam)
        assertFalse(SpamFilter.sms("5551112233", "Toplantı notları: https://example.com/notlar", none).spam)
        assertFalse(SpamFilter.sms("5551112233", "Kazandınız sanırım, şaka yaptım", none).spam)
    }

    @Test fun `one-time code from a bank passes`() {
        assertFalse(SpamFilter.sms("GARANTI", "Doğrulama kodunuz: 482913. Kimseyle paylaşmayın.", none).spam)
    }

    @Test fun `reported text is recognised again from another number`() {
        val body = "Sevgili müşterimiz özel kampanyamızdan yararlanmak için hemen arayın"
        val rules = SpamRules(fingerprints = setOf(SpamFilter.fingerprint(body)!!))
        assertEquals("same_text", SpamFilter.sms("5559998877", body.uppercase(), rules).reason)
        assertNull(SpamFilter.fingerprint("kısa"))
    }

    @Test fun `strict blocks unknown numeric senders but not names`() {
        val strict = SpamRules(strict = true)
        assertEquals("unknown", SpamFilter.sms("05321234567", "selam", strict).reason)
        assertFalse(SpamFilter.sms("TURKCELL", "Faturanız hazır", strict).spam)
    }
}
