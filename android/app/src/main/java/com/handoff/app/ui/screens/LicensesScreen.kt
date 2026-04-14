package com.handoff.app.ui.screens

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

private data class LibraryInfo(
    val name: String,
    val license: String,
    val url: String
)

private val libraries = listOf(
    LibraryInfo(
        name = "Tailscale (tsnet)",
        license = "BSD-3-Clause",
        url = "https://github.com/tailscale/tailscale"
    ),
    LibraryInfo(
        name = "WireGuard-Go",
        license = "MIT",
        url = "https://www.wireguard.com/"
    ),
    LibraryInfo(
        name = "Termux Terminal Emulator",
        license = "GPLv3",
        url = "https://github.com/termux/termux-app"
    ),
    LibraryInfo(
        name = "JSch (SSH)",
        license = "BSD",
        url = "https://github.com/mwiede/jsch"
    ),
    LibraryInfo(
        name = "Bouncy Castle",
        license = "MIT",
        url = "https://www.bouncycastle.org/"
    ),
    LibraryInfo(
        name = "Jetpack Compose",
        license = "Apache 2.0",
        url = "https://developer.android.com/jetpack/compose"
    ),
    LibraryInfo(
        name = "AndroidX CameraX",
        license = "Apache 2.0",
        url = "https://developer.android.com/training/camerax"
    ),
    LibraryInfo(
        name = "Google ML Kit (Barcode)",
        license = "Google Terms of Service",
        url = "https://developers.google.com/ml-kit"
    ),
    LibraryInfo(
        name = "AndroidX Navigation",
        license = "Apache 2.0",
        url = "https://developer.android.com/guide/navigation"
    ),
    LibraryInfo(
        name = "AndroidX DataStore",
        license = "Apache 2.0",
        url = "https://developer.android.com/topic/libraries/architecture/datastore"
    ),
    LibraryInfo(
        name = "AndroidX Security Crypto",
        license = "Apache 2.0",
        url = "https://developer.android.com/training/articles/keystore"
    ),
    LibraryInfo(
        name = "Kotlin Coroutines",
        license = "Apache 2.0",
        url = "https://github.com/Kotlin/kotlinx.coroutines"
    ),
    LibraryInfo(
        name = "Go Mobile",
        license = "BSD-3-Clause",
        url = "https://pkg.go.dev/golang.org/x/mobile"
    ),
    LibraryInfo(
        name = "gVisor",
        license = "Apache 2.0",
        url = "https://github.com/google/gvisor"
    )
)

@Composable
fun LicensesScreen(
    onBack: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(horizontal = 20.dp)
            .padding(top = 16.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Text(
                text = "Open Source Licenses",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold
            )
            TextButton(onClick = onBack) {
                Text("Back")
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = "Handoff uses the following open source libraries:",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(16.dp))

        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            items(libraries) { lib ->
                ListItem(
                    headlineContent = {
                        Text(lib.name, style = MaterialTheme.typography.bodyLarge)
                    },
                    supportingContent = {
                        Text(lib.url, style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    },
                    trailingContent = {
                        Text(
                            lib.license,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                )
            }
        }
    }
}
