package com.cellbridge.status

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HostStatusTest {
    @Test fun `only local network addresses are worth typing on the iPhone`() {
        assertTrue(isLocalNetwork("192.168.43.1"))
        assertTrue(isLocalNetwork("10.0.0.7"))
        assertTrue(isLocalNetwork("172.20.10.1"))
        assertFalse(isLocalNetwork("172.32.0.1"))
        assertFalse(isLocalNetwork("100.64.1.2")) // carrier-grade NAT, the mobile data address
        assertFalse(isLocalNetwork("8.8.8.8"))
        assertFalse(isLocalNetwork("not an address"))
    }

    @Test fun `interfaces are named for people and mobile data is left out`() {
        assertEquals("Wi-Fi", interfaceLabel("wlan0"))
        assertEquals("Hotspot", interfaceLabel("ap0"))
        assertEquals("Hotspot", interfaceLabel("swlan0"))
        assertNull(interfaceLabel("rmnet_data1"))
        assertNull(interfaceLabel("lo"))
    }

    @Test fun `the picked addresses are the ones the iPhone can use`() {
        val picked = pickAddresses(listOf("rmnet_data0" to "10.1.2.3", "wlan0" to "192.168.1.155", "ap0" to "192.168.43.1", "wlan0" to "192.168.1.155"))
        assertEquals(listOf(AddressInfo("Wi-Fi", "192.168.1.155"), AddressInfo("Hotspot", "192.168.43.1")), picked)
    }
}
