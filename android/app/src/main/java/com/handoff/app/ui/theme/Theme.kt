package com.handoff.app.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

private val Background = Color(0xFF0D1117)
private val Surface = Color(0xFF161B22)
private val SurfaceVariant = Color(0xFF21262D)
private val Primary = Color(0xFF58A6FF)
private val OnPrimary = Color(0xFFFFFFFF)
private val OnBackground = Color(0xFFC9D1D9)
private val OnSurface = Color(0xFFC9D1D9)
private val OnSurfaceVariant = Color(0xFF8B949E)
private val Green = Color(0xFF3FB950)
private val Error = Color(0xFFF85149)

val HandoffGreen = Green
val HandoffAmber = Color(0xFFD29922)
val HandoffAmberDim = Color(0xFF3D2E0A)

private val DarkColorScheme = darkColorScheme(
    primary = Primary,
    onPrimary = OnPrimary,
    background = Background,
    onBackground = OnBackground,
    surface = Surface,
    onSurface = OnSurface,
    surfaceVariant = SurfaceVariant,
    onSurfaceVariant = OnSurfaceVariant,
    error = Error,
)

// Handoff commits to a single terminal-style monospace type family across the whole UI.
// This isn't a design affectation: the app IS a terminal front-end, and the mono grid
// aligns directly with the content (tmux session/window names, cwd paths, SSH output).
// Sans-serif here would read as Material-default and make the app look like "just another"
// mobile app. Mono makes it look like a handcrafted dev tool — which is what it is.
private val HandoffTypography = Typography(
    bodyLarge = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Normal,
        fontSize = 15.sp,
        lineHeight = 22.sp,
        color = OnBackground
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Normal,
        fontSize = 13.sp,
        lineHeight = 18.sp,
        color = OnSurfaceVariant
    ),
    bodySmall = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Normal,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        color = OnSurfaceVariant
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Bold,
        fontSize = 20.sp,
        lineHeight = 26.sp,
        letterSpacing = (-0.5).sp,
        color = OnBackground
    ),
    titleMedium = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.SemiBold,
        fontSize = 15.sp,
        lineHeight = 20.sp,
        color = OnBackground
    ),
    labelMedium = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Normal,
        fontSize = 13.sp,
        color = OnSurfaceVariant
    ),
    labelSmall = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Normal,
        fontSize = 10.sp,
        letterSpacing = 1.sp,
        color = OnSurfaceVariant
    ),
)

@Composable
fun HandoffTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = DarkColorScheme,
        typography = HandoffTypography,
        content = content
    )
}
