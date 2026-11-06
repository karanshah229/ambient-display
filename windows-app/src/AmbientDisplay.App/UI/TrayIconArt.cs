using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace AmbientDisplay.App.UI;

internal enum TrayState
{
    Idle,
    Sleeping,
    WakeUp,
    Away,
}

/// <summary>
/// Draws the notification-area icon from Segoe Fluent Icons glyphs (the SF Symbols the macOS menu bar uses:
/// display.2, moon.stars.fill, sun.max.fill). Monochrome to match the taskbar theme, gold when it is time to wake.
/// </summary>
internal static class TrayIconArt
{
    private const string GlyphMonitor = ""; // display
    private const string GlyphMoon = "";    // moon
    private const string GlyphSun = "";     // sun
    private const int Size = 32;

    private static readonly string FontName = PickFont();

    /// <summary>Creates an icon. The caller owns it and must dispose it (which also frees the HICON).</summary>
    public static Icon Create(TrayState state)
    {
        var lightTaskbar = IsLightTaskbar();
        var foreground = lightTaskbar ? Color.FromArgb(0x1F, 0x1F, 0x1F) : Color.White;
        var (glyph, color) = state switch
        {
            TrayState.Sleeping => (GlyphMoon, foreground),
            TrayState.WakeUp => (GlyphSun, Color.FromArgb(0xFF, 0xD0, 0x00)),
            TrayState.Away => (GlyphMonitor, Color.FromArgb(110, foreground)),
            _ => (GlyphMonitor, foreground),
        };

        using var bitmap = new Bitmap(Size, Size);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.Clear(Color.Transparent);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            using var font = new Font(FontName, 22f, FontStyle.Regular, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(color);
            using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            graphics.DrawString(glyph, font, brush, new RectangleF(0, 1, Size, Size), format);

            if (state == TrayState.Away)
            {
                // Small slash so "away" reads at 16 px too.
                using var pen = new Pen(color, 3f);
                graphics.DrawLine(pen, 6, 26, 26, 6);
            }
        }

        var handle = bitmap.GetHicon();
        try
        {
            return (Icon)Icon.FromHandle(handle).Clone(); // clone owns its own copy
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    private static bool IsLightTaskbar()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int value && value == 1;
    }

    private static string PickFont()
    {
        using var fonts = new InstalledFontCollection();
        return fonts.Families.Any(f => f.Name == "Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}
