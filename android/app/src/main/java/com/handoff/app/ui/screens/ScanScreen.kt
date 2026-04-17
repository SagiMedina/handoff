package com.handoff.app.ui.screens

import com.handoff.app.BuildConfig

import android.Manifest
import android.content.pm.PackageManager
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import com.handoff.app.data.ConnectionConfig
import org.json.JSONObject
import java.util.concurrent.Executors

@Composable
fun ScanScreen(
    onConfigScanned: (ConnectionConfig) -> Unit,
    onError: (String) -> Unit
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hasCameraPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED
        )
    }
    var scanned by remember { mutableStateOf(false) }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasCameraPermission = granted
    }

    LaunchedEffect(Unit) {
        if (!hasCameraPermission) {
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        if (hasCameraPermission) {
            AndroidView(
                factory = { ctx ->
                    val previewView = PreviewView(ctx)
                    val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)

                    cameraProviderFuture.addListener({
                        val cameraProvider = cameraProviderFuture.get()

                        val preview = Preview.Builder().build().also {
                            it.surfaceProvider = previewView.surfaceProvider
                        }

                        val analyzer = ImageAnalysis.Builder()
                            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                            .build()
                            .also { analysis ->
                                analysis.setAnalyzer(Executors.newSingleThreadExecutor()) { imageProxy ->
                                    if (scanned) {
                                        imageProxy.close()
                                        return@setAnalyzer
                                    }

                                    val mediaImage = imageProxy.image
                                    if (mediaImage != null) {
                                        val image = InputImage.fromMediaImage(
                                            mediaImage,
                                            imageProxy.imageInfo.rotationDegrees
                                        )
                                        val scanner = BarcodeScanning.getClient()
                                        scanner.process(image)
                                            .addOnSuccessListener { barcodes ->
                                                for (barcode in barcodes) {
                                                    if (BuildConfig.DEBUG) Log.d("Handoff", "Barcode detected: type=${barcode.valueType}, length=${barcode.rawValue?.length ?: 0}")
                                                    if (barcode.valueType == Barcode.TYPE_TEXT) {
                                                        val raw = barcode.rawValue ?: continue
                                                        if (BuildConfig.DEBUG) Log.d("Handoff", "QR raw (first 80): ${raw.take(80)}")
                                                        val config = parseQrPayload(raw)
                                                        if (BuildConfig.DEBUG) Log.d("Handoff", "QR parse result: ${if (config != null) "v${config.protocolVersion}" else "null"}")
                                                        if (config != null && !scanned) {
                                                            scanned = true
                                                            onConfigScanned(config)
                                                            return@addOnSuccessListener
                                                        }
                                                    }
                                                }
                                            }
                                            .addOnCompleteListener {
                                                imageProxy.close()
                                            }
                                    } else {
                                        imageProxy.close()
                                    }
                                }
                            }

                        cameraProvider.unbindAll()
                        cameraProvider.bindToLifecycle(
                            lifecycleOwner,
                            CameraSelector.DEFAULT_BACK_CAMERA,
                            preview,
                            analyzer
                        )
                    }, ContextCompat.getMainExecutor(ctx))

                    previewView
                },
                modifier = Modifier.fillMaxSize()
            )

            // Overlay with viewfinder
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // Viewfinder frame
                Box(
                    modifier = Modifier
                        .size(250.dp)
                        .clip(RoundedCornerShape(16.dp))
                        .background(Color.White.copy(alpha = 0.1f))
                )

                Spacer(modifier = Modifier.height(24.dp))

                Text(
                    text = "Point at the QR code\non your Mac",
                    color = Color.White,
                    fontSize = 16.sp,
                    textAlign = TextAlign.Center
                )
            }
        } else {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(32.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    text = "Camera permission required to scan QR codes",
                    color = MaterialTheme.colorScheme.onBackground,
                    textAlign = TextAlign.Center
                )
                Spacer(modifier = Modifier.height(16.dp))
                Button(onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) }) {
                    Text("Grant Permission")
                }
            }
        }
    }
}

private fun parseQrPayload(raw: String): ConnectionConfig? {
    return try {
        val json = JSONObject(raw)
        val version = json.optInt("v", 0)
        when (version) {
            1 -> ConnectionConfig(
                ip = json.getString("ip"),
                user = json.getString("user"),
                privateKey = json.getString("key"),
                tmuxPath = json.getString("tmux"),
                protocolVersion = 1
            )
            2 -> {
                // v2 uses compact keys: i, u, k, t, n
                val innerKey = json.getString("k")
                // Reconstruct PEM and base64-encode it for JSch compatibility
                val pem = "-----BEGIN OPENSSH PRIVATE KEY-----\n" +
                    innerKey.chunked(70).joinToString("\n") +
                    "\n-----END OPENSSH PRIVATE KEY-----\n"
                val pemBase64 = android.util.Base64.encodeToString(
                    pem.toByteArray(Charsets.UTF_8),
                    android.util.Base64.NO_WRAP
                )
                ConnectionConfig(
                    ip = json.getString("i"),
                    user = json.getString("u"),
                    privateKey = pemBase64,
                    tmuxPath = json.getString("t"),
                    protocolVersion = 2,
                    nonce = json.optString("n", "")
                )
            }
            else -> null
        }
    } catch (e: Exception) {
        if (BuildConfig.DEBUG) Log.w("Handoff", "QR parse failed: ${e.message}", e)
        null
    }
}
