package com.handoff.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.handoff.app.data.ConfigStore
import com.handoff.app.data.ConnectionConfig
import com.handoff.app.data.SshManager
import com.handoff.app.data.TailscaleManager
import com.handoff.app.ui.screens.*
import com.handoff.app.ui.theme.HandoffTheme
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {

    private val sshManager = SshManager()
    private val tailscaleManager by lazy {
        TailscaleManager(HandoffApp.appFilesDir)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val configStore = ConfigStore(applicationContext)
        setContent {
            HandoffTheme {
                val navController = rememberNavController()
                var config by remember { mutableStateOf<ConnectionConfig?>(null) }
                val scope = rememberCoroutineScope()

                // Load saved config on startup
                LaunchedEffect(Unit) {
                    config = configStore.load()
                }

                Scaffold { innerPadding ->
                // innerPadding applied per-screen; terminal goes edge-to-edge
                val scaffoldPadding = innerPadding
                NavHost(
                    navController = navController,
                    startDestination = if (config != null) "tailscale_auth" else "welcome",
                ) {
                    composable("welcome") {
                        Box(Modifier.padding(scaffoldPadding)) {
                        WelcomeScreen(
                            onScanClick = {
                                navController.navigate("scan")
                            }
                        )
                        }
                    }

                    composable("scan") {
                        Box(Modifier.padding(scaffoldPadding)) {
                        ScanScreen(
                            onConfigScanned = { scannedConfig ->
                                scope.launch {
                                    configStore.save(scannedConfig)
                                    config = scannedConfig
                                    navController.navigate("tailscale_auth") {
                                        popUpTo("welcome") { inclusive = true }
                                    }
                                }
                            },
                            onError = { /* TODO: show snackbar */ }
                        )
                        }
                    }

                    composable("tailscale_auth") {
                        Box(Modifier.padding(scaffoldPadding)) {
                        TailscaleAuthScreen(
                            tailscaleManager = tailscaleManager,
                            onAuthenticated = {
                                navController.navigate("sessions") {
                                    popUpTo("tailscale_auth") { inclusive = true }
                                }
                            },
                            onError = { /* shown in auth screen UI */ }
                        )
                        }
                    }

                    composable("sessions") {
                        Box(Modifier.padding(scaffoldPadding)) {
                        val currentConfig = config
                        if (currentConfig != null) {
                            SessionsScreen(
                                config = currentConfig,
                                sshManager = sshManager,
                                tailscaleManager = tailscaleManager,
                                onWindowSelected = { sessionName, window ->
                                    navController.navigate(
                                        "terminal/$sessionName/${window.index}"
                                    )
                                },
                                onUnpair = {
                                    scope.launch {
                                        sshManager.disconnect()
                                        tailscaleManager.resetState()
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
                    }

                    composable("terminal/{session}/{window}") { backStackEntry ->
                        val currentConfig = config
                        val sessionName = backStackEntry.arguments?.getString("session") ?: ""
                        val windowIndex = backStackEntry.arguments?.getString("window")?.toIntOrNull() ?: 0

                        if (currentConfig != null) {
                            TerminalScreen(
                                config = currentConfig,
                                sshManager = sshManager,
                                tailscaleManager = tailscaleManager,
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
    }

    override fun onDestroy() {
        super.onDestroy()
        sshManager.disconnect()
        tailscaleManager.stopProxy()
        tailscaleManager.stop()
    }
}
