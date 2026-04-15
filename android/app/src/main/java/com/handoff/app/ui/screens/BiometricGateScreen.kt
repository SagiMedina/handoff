package com.handoff.app.ui.screens

import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import com.handoff.app.BuildConfig
import com.handoff.app.data.BiometricKeyStore

@Composable
fun BiometricGateScreen(
    biometricKeyStore: BiometricKeyStore,
    onAuthenticated: (String) -> Unit,
    onSkip: () -> Unit
) {
    val context = LocalContext.current
    var error by remember { mutableStateOf<String?>(null) }
    var showRetry by remember { mutableStateOf(false) }
    var retryKey by remember { mutableIntStateOf(0) }

    LaunchedEffect(retryKey) {
        val biometricManager = BiometricManager.from(context)
        val canAuth = biometricManager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
            BiometricManager.Authenticators.DEVICE_CREDENTIAL
        )

        if (canAuth != BiometricManager.BIOMETRIC_SUCCESS) {
            if (BuildConfig.DEBUG) Log.d("Handoff", "BiometricGate: not available, skipping")
            onSkip()
            return@LaunchedEffect
        }

        val activity = context as? FragmentActivity ?: run {
            if (BuildConfig.DEBUG) Log.d("Handoff", "BiometricGate: not a FragmentActivity, skipping")
            onSkip()
            return@LaunchedEffect
        }

        val executor = ContextCompat.getMainExecutor(context)
        val prompt = BiometricPrompt(activity, executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    if (BuildConfig.DEBUG) Log.d("Handoff", "BiometricGate: auth succeeded")
                    onAuthenticated("")
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    if (BuildConfig.DEBUG) Log.d("Handoff", "BiometricGate: auth error $errorCode: $errString")
                    error = errString.toString()
                    showRetry = true
                }

                override fun onAuthenticationFailed() {
                    // Not final — system prompt allows retries
                }
            }
        )

        // No CryptoObject — this is a pure UI gate (app lock)
        val promptInfo = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Handoff")
            .setSubtitle("Unlock to access your sessions")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                BiometricManager.Authenticators.DEVICE_CREDENTIAL
            )
            .build()

        if (BuildConfig.DEBUG) Log.d("Handoff", "BiometricGate: showing prompt")
        prompt.authenticate(promptInfo)
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "Handoff",
            style = MaterialTheme.typography.headlineMedium
        )

        Spacer(modifier = Modifier.height(16.dp))

        if (error != null) {
            Text(
                text = error!!,
                color = MaterialTheme.colorScheme.error,
                textAlign = TextAlign.Center,
                style = MaterialTheme.typography.bodyLarge
            )
            if (showRetry) {
                Spacer(modifier = Modifier.height(16.dp))
                Button(onClick = {
                    error = null
                    showRetry = false
                    retryKey++
                }) {
                    Text("Retry")
                }
            }
        } else {
            CircularProgressIndicator(
                color = MaterialTheme.colorScheme.primary
            )
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = "Authenticating...",
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
