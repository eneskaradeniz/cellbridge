package com.cellbridge.status

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PairingLinkTest {
    @Test fun `the link carries the code, the installation id, the port and the address`() {
        assertEquals(
            "cellbridge://pair?code=AB12CD34&id=1234-abcd&port=8765&host=192.168.1.155",
            pairingLink("AB12CD34", "1234-abcd", "192.168.1.155", 8765),
        )
    }

    @Test fun `the address is optional`() {
        assertEquals("cellbridge://pair?code=AB12CD34&id=x&port=8765", pairingLink("AB12CD34", "x", null, 8765))
    }

    @Test fun `a link becomes a square QR code with the finder pattern in the corner`() {
        val modules = qrModules(pairingLink("AB12CD34", "1234-abcd", "192.168.1.155", 8765))
        assertTrue(modules.size >= 21)
        assertTrue(modules.all { it.size == modules.size })
        // The top-left finder pattern: a dark 7x7 ring with a dark 3x3 centre.
        for (i in 0..6) {
            assertTrue(modules[0][i] && modules[6][i] && modules[i][0] && modules[i][6])
        }
        assertTrue(modules[3][3] && modules[2][2] && modules[4][4])
    }
}
