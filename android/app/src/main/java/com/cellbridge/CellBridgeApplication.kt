package com.cellbridge

import android.app.Application
import com.cellbridge.server.ControlServer
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

@HiltAndroidApp
class CellBridgeApplication : Application() {
    @Inject lateinit var controlServer: ControlServer

    override fun onCreate() {
        super.onCreate()
        controlServer.start() // TODO(step 3b): move into a foreground service so it outlives the UI process state
    }
}
