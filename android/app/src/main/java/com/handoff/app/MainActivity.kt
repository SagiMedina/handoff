package com.handoff.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.handoff.app.data.TmuxSession
import com.handoff.app.data.BiometricKeyStore
import com.handoff.app.data.ConfigStore
import com.handoff.app.data.ConnectionConfig
import com.handoff.app.service.HandoffConnectionService
import com.handoff.app.ui.screens.*
import com.handoff.app.ui.theme.HandoffTheme
import kotlinx.coroutines.launch

class MainActivity : FragmentActivity() {

    // Holders live in HandoffApp so their state — SSH channel, tmux scrollback, tsnet
    // tunnel — survives the Activity. HandoffConnectionService keeps the process alive
    // so they're not just leaked: killed when the user explicitly disconnects.
    private val sshManager get() = HandoffApp.instance.sshManager
    private val tailscaleManager get() = HandoffApp.instance.tailscaleManager
    private val terminalHolder get() = HandoffApp.instance.terminalHolder
    // Sessions list cache that survives navigating in/out of the terminal screen —
    // avoids flashing a loading spinner on every return to the sessions list.
    private val sessionsCache = mutableStateOf<List<TmuxSession>>(emptyList())

    private val requestNotificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { /* best-effort: if denied, service still runs but notification won't be visible */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        // Android 13+ requires an explicit runtime grant for the foreground-service notification.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) requestNotificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }

        val configStore = ConfigStore(applicationContext)
        val biometricKeyStore = BiometricKeyStore(applicationContext)
        setContent {
            HandoffTheme {
                val navController = rememberNavController()
                var config by remember { mutableStateOf<ConnectionConfig?>(null) }
                var configLoaded by remember { mutableStateOf(false) }
                val scope = rememberCoroutineScope()

                // Load saved config on startup
                LaunchedEffect(Unit) {
                    config = configStore.load()
                    configLoaded = true
                }

                Scaffold { innerPadding ->
                // innerPadding applied per-screen; terminal goes edge-to-edge
                val scaffoldPadding = innerPadding

                // Don't render until config is loaded — otherwise startDestination is wrong
                if (!configLoaded) {
                    // Show nothing while loading (< 100ms)
                    return@Scaffold
                }

                val startDest = when {
                    config == null -> "welcome"
                    biometricKeyStore.isBiometricEnabled && biometricKeyStore.hasStoredKey -> "biometric_gate"
                    else -> "tailscale_auth"
                }
                NavHost(
                    navController = navController,
                    startDestination = startDest,
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
                                    Log.d("Handoff", "Nav: scan complete, config v${scannedConfig.protocolVersion}, saving and navigating to tailscale_auth")
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

                    composable("verify") {
                        Box(Modifier.padding(scaffoldPadding)) {
                            val currentConfig = config
                            if (currentConfig != null) {
                                VerificationScreen(
                                    config = currentConfig,
                                    sshManager = sshManager,
                                    tailscaleManager = tailscaleManager,
                                    onVerified = {
                                        navController.navigate("sessions") {
                                            popUpTo("verify") { inclusive = true }
                                        }
                                    },
                                    onError = { errorMsg ->
                                        // Pairing failed — go back to welcome
                                        scope.launch {
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

                    composable("tailscale_auth") {
                        Box(Modifier.padding(scaffoldPadding)) {
                        TailscaleAuthScreen(
                            tailscaleManager = tailscaleManager,
                            onAuthenticated = {
                                scope.launch {
                                    val savedConfig = config ?: configStore.load()
                                    if (savedConfig != null) config = savedConfig
                                    // Claim foreground priority the moment we have a live
                                    // Tailscale tunnel — from here on, the process needs
                                    // to survive backgrounding or every SSH channel dies
                                    // when the user switches apps.
                                    HandoffConnectionService.start(applicationContext)
                                    val pv = savedConfig?.protocolVersion ?: 1
                                    // v1: go straight to sessions. v2: go through verify,
                                    // which internally checks if device is already active
                                    // (list-first) and skips the pair code if so.
                                    val dest = if (pv >= 2) "verify" else "sessions"
                                    Log.d("Handoff", "Nav: tailscale authenticated, config=${if (savedConfig != null) "v$pv" else "null"}, navigating to $dest")
                                    navController.navigate(dest) {
                                        popUpTo("tailscale_auth") { inclusive = true }
                                    }
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
                                cachedSessions = sessionsCache,
                                onWindowSelected = { sessionName, window ->
                                    navController.navigate(
                                        "terminal/$sessionName/${window.index}"
                                    )
                                },
                                onLicenses = {
                                    navController.navigate("licenses")
                                },
                                onSettings = {
                                    navController.navigate("settings")
                                },
                                onUnpair = {
                                    scope.launch {
                                        HandoffConnectionService.disconnect(applicationContext)
                                        sshManager.disconnect()
                                        terminalHolder.disconnect()
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

                    composable("licenses") {
                        Box(Modifier.padding(scaffoldPadding)) {
                            LicensesScreen(
                                onBack = { navController.popBackStack() }
                            )
                        }
                    }

                    composable("settings") {
                        Box(Modifier.padding(scaffoldPadding)) {
                            val currentConfig = config
                            if (currentConfig != null) {
                                SettingsScreen(
                                    config = currentConfig,
                                    biometricKeyStore = biometricKeyStore,
                                    onBack = { navController.popBackStack() },
                                    onLicenses = { navController.navigate("licenses") }
                                )
                            }
                        }
                    }

                    composable("biometric_gate") {
                        Box(Modifier.padding(scaffoldPadding)) {
                            BiometricGateScreen(
                                biometricKeyStore = biometricKeyStore,
                                onAuthenticated = { _ ->
                                    navController.navigate("tailscale_auth") {
                                        popUpTo("biometric_gate") { inclusive = true }
                                    }
                                },
                                onSkip = {
                                    navController.navigate("tailscale_auth") {
                                        popUpTo("biometric_gate") { inclusive = true }
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
                                tailscaleManager = tailscaleManager,
                                terminalHolder = terminalHolder,
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

    // No teardown in onDestroy: the Activity may be recreated while the user still
    // wants the connection up. Disconnect happens via HandoffConnectionService — either
    // the notification's Disconnect action, a swipe dismissal, or Unpair.
}
