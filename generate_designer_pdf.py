import os
from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Image, Table, TableStyle, PageBreak, KeepTogether, HRFlowable
)
from reportlab.pdfgen import canvas

pdf_filename = os.path.join(os.path.dirname(os.path.abspath(__file__)), "docs", "Ambient_Display_Product_Design_Specification.pdf")

# Numbered canvas for professional footer
class NumberedCanvas(canvas.Canvas):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._saved_page_states = []

    def showPage(self):
        self._saved_page_states.append(dict(self.__dict__))
        self._startPage()

    def save(self):
        num_pages = len(self._saved_page_states)
        for state in self._saved_page_states:
            self.__dict__.update(state)
            self.draw_page_number(num_pages)
            canvas.Canvas.showPage(self)
        canvas.Canvas.save(self)

    def draw_page_number(self, page_count):
        self.saveState()
        self.setFont("Helvetica", 8)
        self.setFillColor(colors.HexColor("#7A7A85"))
        page_text = f"Page {self._pageNumber} of {page_count}"
        self.drawRightString(612 - 40, 25, page_text)
        self.drawString(40, 25, "Ambient Display — Complete Product & UX Design Blueprint")
        self.setStrokeColor(colors.HexColor("#E5E5EA"))
        self.setLineWidth(0.5)
        self.line(40, 36, 612 - 40, 36)
        self.restoreState()

doc = SimpleDocTemplate(
    pdf_filename,
    pagesize=letter,
    leftMargin=40,
    rightMargin=40,
    topMargin=45,
    bottomMargin=45
)

styles = getSampleStyleSheet()

COLOR_PRIMARY = colors.HexColor("#FF9F0A")
COLOR_DARK = colors.HexColor("#121214")
COLOR_TEXT = colors.HexColor("#2C2C2E")
COLOR_MUTED = colors.HexColor("#6C6C70")

title_style = ParagraphStyle(
    'DocTitle',
    parent=styles['Normal'],
    fontName='Helvetica-Bold',
    fontSize=24,
    leading=28,
    textColor=COLOR_PRIMARY,
    spaceAfter=4
)

subtitle_style = ParagraphStyle(
    'DocSubTitle',
    parent=styles['Normal'],
    fontName='Helvetica',
    fontSize=11,
    leading=15,
    textColor=COLOR_MUTED,
    spaceAfter=12
)

h1_style = ParagraphStyle(
    'Heading1',
    parent=styles['Heading1'],
    fontName='Helvetica-Bold',
    fontSize=16,
    leading=20,
    textColor=COLOR_DARK,
    spaceBefore=14,
    spaceAfter=6,
    keepWithNext=True
)

h2_style = ParagraphStyle(
    'Heading2',
    parent=styles['Heading2'],
    fontName='Helvetica-Bold',
    fontSize=12,
    leading=16,
    textColor=COLOR_PRIMARY,
    spaceBefore=10,
    spaceAfter=4,
    keepWithNext=True
)

body_style = ParagraphStyle(
    'BodyText',
    parent=styles['Normal'],
    fontName='Helvetica',
    fontSize=9,
    leading=13,
    textColor=COLOR_TEXT,
    spaceAfter=5
)

callout_style = ParagraphStyle(
    'Callout',
    parent=styles['Normal'],
    fontName='Helvetica-Oblique',
    fontSize=8.5,
    leading=12,
    textColor=colors.HexColor("#1C1C1E")
)

card_title_style = ParagraphStyle(
    'CardTitle',
    parent=styles['Normal'],
    fontName='Helvetica-Bold',
    fontSize=11,
    leading=14,
    textColor=COLOR_DARK,
    spaceAfter=3
)

card_label_style = ParagraphStyle(
    'CardLabel',
    parent=styles['Normal'],
    fontName='Helvetica-Bold',
    fontSize=7.5,
    leading=9,
    textColor=COLOR_PRIMARY,
    spaceAfter=2
)

card_bullet_style = ParagraphStyle(
    'CardBullet',
    parent=styles['Normal'],
    fontName='Helvetica',
    fontSize=8,
    leading=11.5,
    textColor=COLOR_TEXT,
    spaceAfter=3
)

story = []

# Title Banner
story.append(Paragraph("AMBIENT DISPLAY", title_style))
story.append(Paragraph("Complete Product, Technical Architecture & Mobile Redesign Blueprint (Live Capture Edition)", subtitle_style))
story.append(HRFlowable(width="100%", thickness=1.5, color=COLOR_PRIMARY, spaceBefore=0, spaceAfter=12))

# Executive Brief
story.append(Paragraph("1. Executive Product Brief", h1_style))
story.append(Paragraph(
    "<b>The Core Problem:</b> Conventional alarm clocks force an unnatural, rigid schedule. If you plan to sleep for 7.5 hours and set an alarm for 5:30 AM, but end up browsing on your phone in bed until 11:15 PM, the alarm still rings at 5:30 AM—leaving you sleep-deprived and groggy. Moreover, traditional alarms jar sleepers awake in pitch-black rooms with loud tones, spiking morning cortisol. Meanwhile, large external monitors in modern home offices sit idle all night.",
    body_style
))
story.append(Paragraph(
    "<b>The Solution:</b> Ambient Display is a zero-friction, intelligent sleep detection and ambient workstation canvas ecosystem linking your Android companion to your macOS workstation monitors. Instead of demanding manual setting:",
    body_style
))

brief_bullets = [
    "<b>Silent Sleep Detection:</b> Automatically tracks when you fall asleep based on phone screen locks and UsageStats inactivity compensation.",
    "<b>Dynamic Sleep Target:</b> If you stay awake in bed within your configurable bedtime window, your wake target dynamically pushes forward to guarantee 7.5 hours of rest.",
    "<b>Workstation Ambient Beacon:</b> External workstation monitors turn into an ultra-dim bedroom countdown, smoothly fading into a warm sunrise glow (amber to soft coral) 30 minutes before wake-up.",
    "<b>Intelligent Glance Filter:</b> Waking up at 3:00 AM for 20 seconds to check a message will never alter your alarm, while sustained nocturnal activity (>3 min) presents a gentle prompt.",
    "<b>Remote Multi-Type Ambient Canvas:</b> Acts as a remote control for your desk displays to broadcast typography billboards, looping video streams, image posters, or live web dashboards.",
    "<b>Multi-Machine Fleet Targeting:</b> Authenticate via Google Sign-In and target individual machines (e.g. MacBook Air, Studio Display) or broadcast fleet-wide with live presence pills."
]
for b in brief_bullets:
    story.append(Paragraph(f"• {b}", body_style))

callout_data = [[Paragraph("<b>✦ DESIGN VISION:</b> Ambient Display must feel like a tranquil, high-end wellness product (inspired by Oura, Apple Health, Rise Science, or Loftie Clock). The visual interface must transform from an engineering test panel into a serene, typography-driven circadian experience.", callout_style)]]
t_callout = Table(callout_data, colWidths=[532])
t_callout.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,-1), colors.HexColor("#F8F9FA")),
    ('BOX', (0,0), (-1,-1), 1, colors.HexColor("#E5E5EA")),
    ('LEFTPADDING', (0,0), (-1,-1), 10),
    ('RIGHTPADDING', (0,0), (-1,-1), 10),
    ('TOPPADDING', (0,0), (-1,-1), 6),
    ('BOTTOMPADDING', (0,0), (-1,-1), 6),
]))
story.append(Spacer(1, 4))
story.append(t_callout)
story.append(Spacer(1, 10))

# Section 2: Features
story.append(Paragraph("2. Exhaustive Feature Matrix across 4 Pillars", h1_style))
story.append(Paragraph("<b>2.1 Pillar 1: Circadian Sleep & Alarm Engine:</b><br/>• <i>Inactivity Compensator:</i> Queries UsageStatsManager to detect true touch events, back-dating bedtime when users fall asleep watching videos.<br/>• <i>Dual Windows:</i> Eligible Sleep Window (9PM–6AM) ignores daytime locks; Auto-Push Window (9PM–11PM) automatically postpones bedtime targets.<br/>• <i>Midnight Glance Filter:</i> Sub-60s unlocks keep alarms intact. Prolonged wakefulness (>3m) triggers an interactive 'Keep Alarm' vs 'Reset Bedtime' prompt.<br/>• <i>Hardware RTC Alarm:</i> Bypasses Doze mode and silencers via AlarmManager.RTC_WAKEUP with USAGE_ALARM stream attributes.", body_style))

story.append(Paragraph("<b>2.2 Pillar 2: Remote Multi-Type Ambient Canvas:</b><br/>• <i>Typography Billboard:</i> Large across-the-room messaging (80pt dynamic font scaling) with optional subtitle.<br/>• <i>Looping Video Surface:</i> Hardware-accelerated video loops streamed via native AVPlayerLooper.<br/>• <i>Image Posters & Web Dashboards:</i> Full-screen imagery with vignette text overlays and live embedded WKWebView dashboards.<br/>• <i>Policies & Duration:</i> Timed toasts (15s/30s) or persistent displays; dismissible via physical ESC (esc_any) or locked to phone (phone_only).", body_style))

story.append(Paragraph("<b>2.3 Pillar 3: Workstation Fleet Targeting & Cloud Sync:</b><br/>• <i>Dual-Tier Connectivity:</i> Operates 100% locally out-of-the-box over Wi-Fi (HTTP :8321 + Bonjour) and globally via Google-authenticated Firebase Cloud Firestore.<br/>• <i>Live Presence Pills:</i> Automatic 90-second heartbeats power ONLINE (green) and OFFLINE (gray) status badges.<br/>• <i>Selective & Broadcast Dispatch:</i> Target a specific machine or broadcast across the entire fleet with per-machine Quick Clear.", body_style))

story.append(Paragraph("<b>2.4 Pillar 4: Circadian Settings & System Health:</b><br/>• Configurable sleep duration (1h–16h), customizable RGB hex colors for Night (#D95926), Dawn (#FA7268), and Wake (#FFD000).<br/>• OEM background immunity checklist for OnePlus/Oppo/Xiaomi (Battery Unrestricted, Usage Stats, Accessibility Watchdog, Auto-Launch).", body_style))

story.append(PageBreak())

# Section 3: Visual Gallery
story.append(Paragraph("3. Fresh Device Screen-by-Screen Gallery & Design Annotations", h1_style))
story.append(Paragraph("The screenshots below were captured live from the OnePlus physical phone (CPH2717) and macOS Sequoia workstation setup.", body_style))
story.append(Spacer(1, 4))

def make_phone_card(img_path, title, label, bullet_points, img_w=150, img_h=325):
    if not os.path.exists(img_path):
        return Paragraph(f"[Image missing: {img_path}]", body_style)
    img = Image(img_path, width=img_w, height=img_h)
    desc_flowables = [
        Paragraph(label.upper(), card_label_style),
        Paragraph(title, card_title_style),
        HRFlowable(width="100%", thickness=0.5, color=colors.HexColor("#E5E5EA"), spaceBefore=2, spaceAfter=5)
    ]
    for b_label, b_desc in bullet_points:
        desc_flowables.append(Paragraph(f"• <b>{b_label}:</b> {b_desc}", card_bullet_style))
    t = Table([[img, desc_flowables]], colWidths=[img_w + 10, 532 - (img_w + 10)])
    t.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), colors.HexColor("#FAFAFC")),
        ('BOX', (0,0), (-1,-1), 1, colors.HexColor("#E5E5EA")),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('LEFTPADDING', (0,0), (-1,-1), 8),
        ('RIGHTPADDING', (0,0), (-1,-1), 8),
        ('TOPPADDING', (0,0), (-1,-1), 6),
        ('BOTTOMPADDING', (0,0), (-1,-1), 6),
    ]))
    return t

def make_mac_card(img_path, title, label, bullet_points, img_w=220, img_h=220):
    if not os.path.exists(img_path):
        return Paragraph(f"[Image missing: {img_path}]", body_style)
    img = Image(img_path, width=img_w, height=img_h)
    desc_flowables = [
        Paragraph(label.upper(), card_label_style),
        Paragraph(title, card_title_style),
        HRFlowable(width="100%", thickness=0.5, color=colors.HexColor("#E5E5EA"), spaceBefore=2, spaceAfter=5)
    ]
    for b_label, b_desc in bullet_points:
        desc_flowables.append(Paragraph(f"• <b>{b_label}:</b> {b_desc}", card_bullet_style))
    t = Table([[img, desc_flowables]], colWidths=[img_w + 10, 532 - (img_w + 10)])
    t.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), colors.HexColor("#FAFAFC")),
        ('BOX', (0,0), (-1,-1), 1, colors.HexColor("#E5E5EA")),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('LEFTPADDING', (0,0), (-1,-1), 8),
        ('RIGHTPADDING', (0,0), (-1,-1), 8),
        ('TOPPADDING', (0,0), (-1,-1), 6),
        ('BOTTOMPADDING', (0,0), (-1,-1), 6),
    ]))
    return t

# Phone Screen 1: Tab 1 Sleep Top
story.append(make_phone_card(
    "docs/screenshots/live_fresh/phone_tab1_sleep_top.png",
    "Rest & Sleep Dashboard (Fresh Live Capture)",
    "Tab 1: Rest Dashboard (Top)",
    [
        ("Status Card", "Shows real-time status: 'Away Mode (Paused)' or 'Standby' with live screen timeout (30m)."),
        ("Duration Presets", "Segmented chips: 6.0h, 7.0h, 7.5h (5 cycles), 8.0h, 9.0h."),
        ("Primary Action", "'Start Sleep Session (7.5h)' button and secondary 'Stop Sleep / I'm Awake' control."),
        ("Away Mode Switch", "Suppresses workstation monitor illumination when sleeping away from home."),
        ("Design Mandate", "Replace blocky cards with a circular 24-hour circadian arc dial with subtle breathing glow.")
    ]
))
story.append(Spacer(1, 10))

# Phone Screen 2: Tab 2 Canvas
story.append(make_phone_card(
    "docs/screenshots/live_fresh/phone_tab2_canvas_top.png",
    "Remote Canvas Billboard Studio (Live Capture)",
    "Tab 2: Canvas Studio",
    [
        ("Mode Selector", "Supports Billboard (Typography), Ambient Video, Image Poster, and Web Dashboard."),
        ("Text & Media Inputs", "Headline, optional subtitle, and media URL inputs with live typing history."),
        ("Quick Presets", "Instant chips for away states ('Gone down to meet Tarun', 'DND', 'BRB in 10m')."),
        ("Lock Policy & Duration", "Toggle 'ESC (Any)' vs '🔒 Locked (Phone Only)'; Duration: Infinite, 15s, or 30s."),
        ("Design Mandate", "Transform inputs into a visual card carousel with thumbnail previews and live character counts.")
    ]
))

story.append(PageBreak())

# Phone Screen 3: Tab 3 Devices Fleet
story.append(make_phone_card(
    "docs/screenshots/live_fresh/phone_tab3_devices_top.png",
    "Workstation Fleet Manager (Live Capture)",
    "Tab 3: Devices & Fleet",
    [
        ("Google Cloud Sign-In", "Displays signed-in account (karanshah229@gmail.com) with active Firebase sync status."),
        ("Fleet Target List", "Shows registered machines (MacBook Air) with live ONLINE / OFFLINE heartbeat pill."),
        ("Per-Machine Clear", "Dedicated 'Clear' button to dismiss canvas on an individual machine immediately."),
        ("Local IP Fallback", "Displays local subnet IP (192.168.1.2) with ping test and mDNS auto-discovery."),
        ("Design Mandate", "Replace raw IP inputs with a clean connection island card; highlight online machines.")
    ]
))
story.append(Spacer(1, 10))

# Phone Screen 4: Tab 4 Settings & Checklist
story.append(make_phone_card(
    "docs/screenshots/live_fresh/phone_tab4_settings_bottom.png",
    "OEM Protection Checklist & Colors (Live Capture)",
    "Tab 4: Settings & Health",
    [
        ("Ambient Color Shaders", "Visual RGB swatches for Deep Night (#D95926), Dawn (#FA7268), and Wake (#FFD000)."),
        ("OnePlus Immunity Checklist", "Direct intent shortcuts for Battery Unrestricted, Usage Access, Watchdog, and Auto-Launch."),
        ("Timers & Windows", "Configurable 9PM–6AM sleep window, 9PM–11PM auto-push window, and inactivity offsets."),
        ("Design Mandate", "Relocate setup checklists and developer tools into a collapsible 'Device Health' drawer.")
    ]
))

story.append(PageBreak())

# Mac Screen 1: Menu Bar Dropdown
story.append(make_mac_card(
    "docs/screenshots/live_fresh/mac_menubar_dropdown_live.png",
    "macOS Status Bar Dropdown Menu (Live Capture)",
    "macOS Menu Bar Utility",
    [
        ("Native StatusItem", "Live menu bar icon reflects state: Idle, Sleeping (with countdown time), or Away."),
        ("Quick Actions", "Instant 1-click 'Start Sleep (7.5h Target)' and 'Test Ambient (10s)' triggers."),
        ("Cloud Machine Identity", "Displays signed-in Google account (karanshah229@gmail.com) and machine_macbook_air."),
        ("Preferences Access", "Opens multi-tab Preferences window for display management and schedule configuration.")
    ],
    img_w=200,
    img_h=200
))
story.append(Spacer(1, 10))

# Mac Screen 2: Preferences Cloud Tab
story.append(make_mac_card(
    "docs/screenshots/live_fresh/mac_pref_cloud_live.png",
    "macOS Preferences: Cloud & Paired Devices (Live Capture)",
    "Mac Preferences - Cloud Tab",
    [
        ("Firebase Cloud Identity", "Shows active connection to Firebase project 'ambient-screen' with Google OAuth."),
        ("Device Identity", "Hardware ID 'machine_macbook_air' with 'Online & Synchronizing' status badge."),
        ("Paired Fleet Devices", "Real-time list of all paired machines: MacBook Air (ONLINE) and OnePlus CPH2717 (ONLINE)."),
        ("Two-Way Sync", "Synchronizes preferences between phone and Mac instantaneously over Cloud Firestore.")
    ],
    img_w=200,
    img_h=200
))

story.append(PageBreak())

# Mac Screen 3: Displays Manager
story.append(make_mac_card(
    "docs/screenshots/live_fresh/mac_pref_displays_live.png",
    "Multi-Monitor Selection Manager (Live Capture)",
    "Mac Preferences - Displays Tab",
    [
        ("Detected Hardware (4)", "Lists all 4 active displays: DELL P2722HE (Main), Retina, DELL S2740L, Sidecar."),
        ("Selective Monitor Exclusion", "'Ignore Display' button allows excluding specific screens from ambient glow."),
        ("Native Resolution", "Reports native frame dimensions (1920x1080, 1470x956) for pixel-perfect canvas rendering.")
    ],
    img_w=200,
    img_h=200
))
story.append(Spacer(1, 10))

# Mac Screen 4: Live Timed Billboard Canvas
story.append(make_mac_card(
    "docs/screenshots/live_fresh/mac_live_canvas_billboard.png",
    "Live Workstation Canvas Billboard (DELL Monitor)",
    "Workstation Monitor Display",
    [
        ("Pitch-Black Zero-Bleed Canvas", "#000000 pure background prevents backlight bleeding in dark environments."),
        ("Timed Toast Badge", "Top-right pill shows real-time countdown ('Closes in 9s') with current time."),
        ("Billboard Headline & Subtitle", "Large-scale typography 'Design Review in Progress' with subtitle and origin badge."),
        ("Dismissal Options", "Dismiss button at bottom-left; physical ESC key or phone clear immediately dismisses.")
    ],
    img_w=220,
    img_h=125
))

story.append(Spacer(1, 10))

# Mac Screen 5: Live Privacy-Locked Canvas
story.append(make_mac_card(
    "docs/screenshots/live_fresh/mac_live_canvas_focus.png",
    "Live Privacy-Locked Billboard ('phone_only' Policy)",
    "Workstation Monitor Display (Locked)",
    [
        ("Privacy Lock Badge", "Top badge indicates '🔒 LOCKED' with red accent color."),
        ("Headline & Subtitle", "'Focus Time • Deep Work in Progress' centered with high-contrast typography."),
        ("Remote Dismiss Policy", "Disables physical ESC key on Mac; bottom prompt displays '📱 Dismiss from phone'.")
    ],
    img_w=220,
    img_h=125
))

story.append(PageBreak())

# Section 4: UX & UI Design Mandates
story.append(Paragraph("4. UX & UI Design Mandates for Mobile Redesign", h1_style))
story.append(Paragraph("The designer must transform the functional engineering console into an elegant, tranquil circadian companion:", body_style))

ux_mandates = [
    "<b>Hero Circadian Ring (Tab 1):</b> Focal 24-hour circular dial displaying bedtime anchor and target wake time with 3-phase color gradient (Deep Night #FF8C38, Dawn #FA7268, Wake #FFD000).",
    "<b>Hardware Connection Pill:</b> Replace raw IP text fields with an elegant connection status badge: '🟢 Karan's MacBook Air (Dell 27\") • Local Wi-Fi' (tapping opens details).",
    "<b>Visual Canvas Studio (Tab 2):</b> A modern card carousel for Billboard, Video Loop, Image Poster, and Webview with real-time character count and preset chips.",
    "<b>Workstation Fleet Matrix (Tab 3):</b> Card grid for registered machines with pulsing online status pills, select-all broadcast switch, and per-machine quick clear.",
    "<b>Secondary Device Health Drawer (Tab 4):</b> Relocate technical checklists (OnePlus battery optimization, ADB developer tools) into a secondary sheet to keep the daily UI clean.",
    "<b>Sunrise Alarm Ringing Experience:</b> Full-screen sunrise gradient with large typography and an affirmative 'Slide to Wake Up' gesture."
]
for m in ux_mandates:
    story.append(Paragraph(f"• {m}", body_style))

doc.build(story, canvasmaker=NumberedCanvas)
print(f"Successfully generated PDF at: {pdf_filename}")
