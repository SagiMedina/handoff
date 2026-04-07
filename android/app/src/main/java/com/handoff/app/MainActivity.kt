package com.handoff.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.handoff.app.data.ConfigStore
import com.handoff.app.data.ConnectionConfig
import com.handoff.app.data.SshManager
import com.handoff.app.shortcuts.HandoffShortcutManager
import com.handoff.app.ui.screens.*
import com.handoff.app.ui.theme.HandoffTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private val sshManager = SshManager()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val configStore = ConfigStore(applicationContext)
        val shortcutManager = HandoffShortcutManager(applicationContext)

        setContent {
            HandoffTheme {
                val navController = rememberNavController()
                var config by remember { mutableStateOf<ConnectionConfig?>(null) }
                val scope = rememberCoroutineScope()

                // Load saved config on startup
                LaunchedEffect(Unit) {
                    config = configStore.load()
                }

                // Handle deep links
                val deepLink = intent?.data
                val autoConnect = deepLink?.scheme == "handoff" && deepLink.host == "connect"

                NavHost(
                    navController = navController,
                    startDestination = if (config != null) "sessions" else "welcome"
                ) {
                    composable("welcome") {
                        WelcomeScreen(
                            onScanClick = {
                                navController.navigate("scan")
                            }
                        )
                    }

                    composable("scan") {
                        ScanScreen(
                            onConfigScanned = { scannedConfig ->
                                scope.launch {
                                    configStore.save(scannedConfig)
                                    config = scannedConfig
                                    shortcutManager.createHomeShortcut()
                                    navController.navigate("sessions") {
                                        popUpTo("welcome") { inclusive = true }
                                    }
                                }
                            },
                            onError = { /* TODO: show snackbar */ }
                        )
                    }

                    composable("sessions") {
                        val currentConfig = config
                        if (currentConfig != null) {
                            SessionsScreen(
                                config = currentConfig,
                                sshManager = sshManager,
                                onWindowSelected = { sessionName, window ->
                                    navController.navigate(
                                        "terminal/$sessionName/${window.index}"
                                    )
                                },
                                onUnpair = {
                                    scope.launch {
                                        sshManager.disconnect()
                                        configStore.clear()
                                        config = null
                                        navController.navigate("welcome") {
                                            popUpTo(0) { inclusive = true }
                                        }
                                    }
                                }
                            )
                        }
                    }

                    composable("terminal/{session}/{window}") { backStackEntry ->
                        val currentConfig = config
                        val sessionName = backStackEntry.arguments?.getString("session") ?: ""
                        val windowIndex = backStackEntry.arguments?.getString("window")?.toIntOrNull() ?: 0

                        if (currentConfig != null) {
                            TerminalScreen(
                                config = currentConfig,
                                sshManager = sshManager,
                                sessionName = sessionName,
                                windowIndex = windowIndex,
                                onDisconnect = {
                                    navController.popBackStack()
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        sshManager.disconnect()
    }
}
