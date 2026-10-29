package com.cellbridge.status

import org.junit.Assert.assertEquals
import org.junit.Test

class DialInputTest {
    @Test fun `spaces, dashes and brackets go`() {
        assertEquals("+905321112233", sanitizeDial("+90 (532) 111-22 33"))
        assertEquals("*#06#", sanitizeDial("*#06#"))
    }

    @Test fun `a plus only stays in front`() {
        assertEquals("+90532", sanitizeDial("+90+532"))
        assertEquals("90532", sanitizeDial("90+532"))
    }

    @Test fun `text without digits is empty`() {
        assertEquals("", sanitizeDial("call me"))
    }
}
