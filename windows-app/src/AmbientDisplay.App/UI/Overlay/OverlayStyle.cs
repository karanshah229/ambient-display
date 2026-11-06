using System.Globalization;
using System.Windows.Media;

namespace AmbientDisplay.App.UI.Overlay;

/// <summary>Colour helpers and icon glyphs shared by the overlay views.</summary>
internal static class OverlayStyle
{
    // Segoe Fluent Icons / MDL2 code points standing in for the SF Symbols used on macOS.
    public const string GlyphSun = "";        // sun.max.fill
    public const string GlyphMoon = "";       // bed.double.fill / moon
    public const string GlyphTimer = "";      // timer
    public const string GlyphLock = "";       // lock.fill
    public const string GlyphShield = "";     // lock.shield.fill
    public const string GlyphMessage = "";    // message.fill
    public const string GlyphPhoto = "";      // photo.fill
    public const string GlyphVideo = "";      // play.rectangle.fill
    public const string GlyphGlobe = "";      // globe
    public const string GlyphPhone = "";      // iphone.radiowaves
    public const string GlyphWarning = "";    // photo.badge.exclamationmark

    public static Color FromHex(string hex, Color fallback)
    {
        var clean = (hex ?? string.Empty).Trim().TrimStart('#');
        if (clean.Length == 6 && uint.TryParse(clean, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgb))
        {
            return Color.FromRgb((byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
        }

        return fallback;
    }

    public static SolidColorBrush Brush(Color color, double opacity = 1.0)
    {
        var brush = new SolidColorBrush(Color.FromArgb((byte)Math.Round(Math.Clamp(opacity, 0, 1) * color.A), color.R, color.G, color.B));
        brush.Freeze();
        return brush;
    }

    /// <summary>SwiftUI <c>Color(red:green:blue:)</c> with 0..1 components.</summary>
    public static Color Rgb(double r, double g, double b) =>
        Color.FromRgb((byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));

    public static SolidColorBrush Gray(double white, double opacity = 1.0) => Brush(Rgb(white, white, white), opacity);

    public static string FormatHours(double hours) =>
        hours % 1 == 0 ? hours.ToString("0", CultureInfo.CurrentCulture) : hours.ToString("0.0", CultureInfo.CurrentCulture);
}
