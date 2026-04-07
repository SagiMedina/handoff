package com.handoff.app.shortcuts

import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import com.handoff.app.R

class HandoffShortcutManager(private val context: Context) {

    fun createHomeShortcut() {
        val shortcutManager = context.getSystemService(ShortcutManager::class.java) ?: return

        if (!shortcutManager.isRequestPinShortcutSupported) return

        val intent = Intent(Intent.ACTION_VIEW).apply {
            data = Uri.parse("handoff://connect")
            setPackage(context.packageName)
        }

        val shortcut = ShortcutInfo.Builder(context, "handoff_connect")
            .setShortLabel("Handoff")
            .setLongLabel("Connect to Mac")
            .setIcon(Icon.createWithResource(context, R.mipmap.ic_launcher))
            .setIntent(intent)
            .build()

        shortcutManager.requestPinShortcut(shortcut, null)
    }

    fun updateDynamicShortcuts(sessionNames: List<String>) {
        val shortcutManager = context.getSystemService(ShortcutManager::class.java) ?: return

        val shortcuts = sessionNames.take(4).map { name ->
            val intent = Intent(Intent.ACTION_VIEW).apply {
                data = Uri.parse("handoff://connect?session=$name")
                setPackage(context.packageName)
            }

            ShortcutInfo.Builder(context, "session_$name")
                .setShortLabel(name)
                .setLongLabel("Attach to $name")
                .setIcon(Icon.createWithResource(context, R.mipmap.ic_launcher))
                .setIntent(intent)
                .build()
        }

        shortcutManager.dynamicShortcuts = shortcuts
    }
}
