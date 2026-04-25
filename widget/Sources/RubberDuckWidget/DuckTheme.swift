// Centralized design tokens for the duck widget.

import SwiftUI

enum DuckTheme {
    // Layout
    static let widgetSize: CGFloat = 120
static let cornerRadius: CGFloat = 18
    static let eyeSize: CGFloat = 10
    static let eyeSpacing: CGFloat = 46

    // Duck palette — warm white body, golden-yellow accent (beak/feet)
    /// Accent color — warm golden yellow matching the beak.
    static let accent = Color(red: 0.95, green: 0.78, blue: 0.22)
    /// Widget background tint — slightly warm cream
    static let backgroundColor = Color(red: 0.95, green: 0.92, blue: 0.86)
    static let bodyColor = backgroundColor
    static let bodyColorDark = Color(red: 0.91, green: 0.88, blue: 0.82)
    static let bodyOpacity: Double = 0.75  // Yellow tint over glass — lets desktop bleed through
    static let eyeColor = Color.black
    static let cheekColor = Color(red: 1.0, green: 0.6, blue: 0.4).opacity(0.4)

    // Expression colors
    static let positiveGlow = Color(red: 1.0, green: 0.7, blue: 0.2).opacity(0.3)   // warm amber
    static let negativeGlow = Color(red: 0.3, green: 0.5, blue: 0.9).opacity(0.3)  // cool blue
    static let permissionGlow = Color(red: 1.0, green: 0.8, blue: 0.0).opacity(0.5)

    // Animation
    static let reactionDuration: Double = 0.6
    static let springResponse: Double = 0.5
    static let springDamping: Double = 0.6
}
