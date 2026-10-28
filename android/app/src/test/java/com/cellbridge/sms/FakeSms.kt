package com.cellbridge.sms

import com.cellbridge.domain.model.IncomingSms
import com.cellbridge.domain.model.SendResult
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow

class FakeSmsGateway : SmsGateway {
    val flow = MutableSharedFlow<IncomingSms>(extraBufferCapacity = 8)
    var available = true
    var pending: List<IncomingSms> = emptyList()
    val acknowledged = mutableListOf<Long>()
    val sent = mutableListOf<Pair<String, String>>()
    var sendResult: SendResult = SendResult.Sent

    override val incoming: SharedFlow<IncomingSms> = flow
    override fun isAvailable() = available
    override suspend fun unacknowledged() = pending
    override suspend fun acknowledge(id: Long) { acknowledged += id }
    override suspend fun send(to: String, body: String): SendResult = sendResult.also { sent += to to body }
}
