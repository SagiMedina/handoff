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

private val HandoffTypography = Typography(
    bodyLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        color = OnBackground
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Bold,
        fontSize = 24.sp,
        lineHeight = 32.sp,
        color = OnBackground
    ),
    labelMedium = TextStyle(
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
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
