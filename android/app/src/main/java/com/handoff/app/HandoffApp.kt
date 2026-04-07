package com.handoff.app

import android.app.Application
import org.apache.sshd.common.util.OsUtils

class HandoffApp : Application() {
    override fun onCreate() {
        super.onCreate()

        // Required for Apache MINA SSHD on Android
        OsUtils.setAndroid(java.lang.Boolean.TRUE)
        System.setProperty("user.name", "handoff")
        System.setProperty("user.dir", filesDir.absolutePath)
    }
}
