import os
from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Image, Table, TableStyle, PageBreak, KeepTogether, HRFlowable
)
from reportlab.pdfgen import canvas

pdf_filename = os.path.join(os.path.dirname(os.path.abspath(__file__)), "docs", "WakeMeUp_Product_Design_Specification.pdf")

# Numbered canvas for page numbers
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
        self.drawString(40, 25, "Wake Me Up — Complete Product & UX Design Blueprint")
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

# Custom Styles
COLOR_PRIMARY = colors.HexColor("#FF9F0A")
COLOR_DARK = colors.HexColor("#121214")
COLOR_TEXT = colors.HexColor("#2C2C2E")
COLOR_MUTED = colors.HexColor("#6C6C70")

title_style = ParagraphStyle(
    'DocTitle',
    parent=styles['Normal'],
    fontName='Helvetica-Bold',
    fontSize=26,
    leading=30,
    textColor=COLOR_PRIMARY,
    spaceAfter=4
)

subtitle_style = ParagraphStyle(
    'DocSubTitle',
    parent=styles['Normal'],
    fontName='Helvetica',
    fontSize=12,
    leading=16,
    textColor=COLOR_MUTED,
    spaceAfter=14
)

h1_style = ParagraphStyle(
    'Heading1',
    parent=styles['Heading1'],
    fontName='Helvetica-Bold',
    fontSize=18,
    leading=22,
    textColor=COLOR_DARK,
    spaceBefore=16,
    spaceAfter=8,
    keepWithNext=True
)

h2_style = ParagraphStyle(
    'Heading2',
    parent=styles['Heading2'],
    fontName='Helvetica-Bold',
    fontSize=13,
    leading=17,
    textColor=COLOR_PRIMARY,
    spaceBefore=12,
    spaceAfter=6,
    keepWithNext=True
)

body_style = ParagraphStyle(
    'BodyText',
    parent=styles['Normal'],
    fontName='Helvetica',
    fontSize=9.5,
    leading=13.5,
    textColor=COLOR_TEXT,
    spaceAfter=6
)

callout_style = ParagraphStyle(
    'Callout',
    parent=styles['Normal'],
    fontName='Helvetica-Oblique',
    fontSize=9,
    leading=13,
    textColor=colors.HexColor("#1C1C1E")
)

card_title_style = ParagraphStyle(
    'CardTitle',
    parent=styles['Normal'],
    fontName='Helvetica-Bold',
    fontSize=12,
    leading=15,
    textColor=COLOR_DARK,
    spaceAfter=4
)

card_label_style = ParagraphStyle(
    'CardLabel',
    parent=styles['Normal'],
    fontName='Helvetica-Bold',
    fontSize=8,
    leading=10,
    textColor=COLOR_PRIMARY,
    spaceAfter=2
)

card_bullet_style = ParagraphStyle(
    'CardBullet',
    parent=styles['Normal'],
    fontName='Helvetica',
    fontSize=8.5,
    leading=12,
    textColor=COLOR_TEXT,
    spaceAfter=4
)

story = []

# Title Banner
story.append(Paragraph("WAKE ME UP", title_style))
story.append(Paragraph("Complete Product, Architecture & UX Design Blueprint — 1-Stop Designer Guide", subtitle_style))
story.append(HRFlowable(width="100%", thickness=1.5, color=COLOR_PRIMARY, spaceBefore=0, spaceAfter=14))

# Executive Brief
story.append(Paragraph("1. Executive Product Brief", h1_style))
story.append(Paragraph(
    "<b>The Core Problem:</b> Conventional alarm clocks force an unnatural, rigid schedule. If you plan to sleep for 7.5 hours and set an alarm for 5:30 AM, but end up browsing on your phone in bed until 11:15 PM, the alarm still rings at 5:30 AM—leaving you sleep-deprived and groggy. Moreover, traditional alarms jar sleepers awake in pitch-black rooms with loud tones, spiking morning cortisol.",
    body_style
))
story.append(Paragraph(
    "<b>The Wake Me Up Paradigm:</b> Wake Me Up is a zero-friction, intelligent sleep detection and sunrise alarm ecosystem linking your Android bedside companion to your macOS workstation monitors. Instead of demanding manual setting:",
    body_style
))

brief_bullets = [
    "<b>Silent Sleep Detection:</b> Automatically tracks when you fall asleep based on phone screen locks and UsageStats inactivity compensation.",
    "<b>Dynamic Sleep Target:</b> If you stay awake in bed within your configurable bedtime window, your wake target dynamically pushes forward to guarantee 7.5 hours of rest.",
    "<b>Workstation Ambient Beacon:</b> External workstation monitors turn into an ultra-dim bedroom countdown, smoothly fading into a warm sunrise glow 30 minutes before wake-up.",
    "<b>Intelligent Glance Filter:</b> Waking up at 3:00 AM for 20 seconds to check a message will never alter your alarm, while sustained nocturnal activity (>3 min) presents a gentle prompt."
]
for b in brief_bullets:
    story.append(Paragraph(f"• {b}", body_style))

callout_data = [[Paragraph("<b>✦ DESIGN VISION:</b> Wake Me Up must feel like premium, organic wellness hardware (inspired by Oura, Apple Health, or Loftie Clock). The visual interface must transform from an engineering test panel into a serene, typography-driven circadian experience.", callout_style)]]
t_callout = Table(callout_data, colWidths=[532])
t_callout.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,-1), colors.HexColor("#F8F9FA")),
    ('BOX', (0,0), (-1,-1), 1, colors.HexColor("#E5E5EA")),
    ('LEFTPADDING', (0,0), (-1,-1), 12),
    ('RIGHTPADDING', (0,0), (-1,-1), 12),
    ('TOPPADDING', (0,0), (-1,-1), 8),
    ('BOTTOMPADDING', (0,0), (-1,-1), 8),
]))
story.append(Spacer(1, 4))
story.append(t_callout)
story.append(Spacer(1, 14))

# Section 2: Features
story.append(Paragraph("2. Complete Feature Breakdown", h1_style))
story.append(Paragraph("<b>2.1 Pre-Lock Inactivity Compensator:</b> Uses Android's UsageStatsManager to detect when the phone was truly last touched. If left untouched on the mattress for 30 minutes before locking, bedtime is back-calculated accordingly so the user isn't over-slept.", body_style))
story.append(Paragraph("<b>2.2 Dual Configurable Windows:</b><br/>• <i>Eligible Sleep Window (Default: 9:00 PM – 6:00 AM):</i> Inactivity is strictly ignored during daytime hours (e.g. 2:00 PM on a workday).<br/>• <i>Auto-Push Window (Default: 9:00 PM – 11:00 PM):</i> Evening phone use automatically rolls the 7.5-hour wake target forward without prompting. Outside this window, the alarm locks in place.", body_style))
story.append(Paragraph("<b>2.3 Midnight Glance vs. Insomnia Filter:</b> Sub-60s unlocks leave the alarm untouched. Nocturnal activity past 3 minutes triggers an interactive prompt: 'Keep Original Alarm' or 'Reset Bedtime to Now (Push 7.5h)'.", body_style))
story.append(Paragraph("<b>2.4 Workstation Ambient Countdown:</b> External Dell monitors mirror a true-black (#000000) countdown display with zero backlight bleed. macOS power assertions keep monitors awake. ESC key immediately dismisses the display.", body_style))
story.append(Paragraph("<b>2.5 Circadian Dawn Simulation & Alarm:</b> Displays transition from deep ember (#D95926) to warm dawn glow (#FFBF66) at T-30 minutes, switching to golden amber (#FFB800) at T-0 minutes while the phone rings an exact hardware RTC alarm.", body_style))
story.append(Paragraph("<b>2.6 Zero-Cloud Wi-Fi Sync & Away Mode:</b> Communicates directly over local Wi-Fi via Bonjour and subnet scanning. Away Mode suppresses workstation monitors while keeping phone tracking active.", body_style))

story.append(PageBreak())

# Section 3: Visual Gallery
story.append(Paragraph("3. Visual Screen-by-Screen Gallery & Design Annotations", h1_style))
story.append(Paragraph("Every live screen from the OnePlus 12 mobile phone and MacBook Air desktop companion is documented below with specific callouts explaining the current functionality and the future design requirements.", body_style))
story.append(Spacer(1, 6))

def make_pdf_card(img_path, title, label, bullet_points, img_w=170, img_h=370):
    if not os.path.exists(img_path):
        return Paragraph(f"[Image missing: {img_path}]", body_style)
    
    img = Image(img_path, width=img_w, height=img_h)
    
    desc_flowables = [
        Paragraph(label.upper(), card_label_style),
        Paragraph(title, card_title_style),
        HRFlowable(width="100%", thickness=0.5, color=colors.HexColor("#E5E5EA"), spaceBefore=2, spaceAfter=6)
    ]
    for b_label, b_desc in bullet_points:
        desc_flowables.append(Paragraph(f"• <b>{b_label}:</b> {b_desc}", card_bullet_style))
        
    t = Table([[img, desc_flowables]], colWidths=[img_w + 10, 532 - (img_w + 10)])
    t.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), colors.HexColor("#FAFAFC")),
        ('BOX', (0,0), (-1,-1), 1, colors.HexColor("#E5E5EA")),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('LEFTPADDING', (0,0), (-1,-1), 8),
        ('RIGHTPADDING', (0,0), (-1,-1), 10),
        ('TOPPADDING', (0,0), (-1,-1), 8),
        ('BOTTOMPADDING', (0,0), (-1,-1), 8),
    ]))
    return t

# Mobile 1
story.append(make_pdf_card(
    "docs/screenshots/phone_01_top_live.png",
    "Mobile Home Dashboard & Status",
    "Screen 1: Mobile Companion Top",
    [
        ("Status Card", "Shows 'Standby (Outside Sleep Window)' in daytime; indicates sleep tracking is safely inactive."),
        ("Sleep Windows & Duration", "Displays target 7.5h duration, Eligible Window (9PM-6AM), and Auto-Push Window (9PM-11PM)."),
        ("Away Mode Toggle", "Suppresses monitor display activation when sleeping away from home."),
        ("Mac Connection Card", "Shows connected Mac IP (192.168.1.2) with Save, Ping, and Auto-Discover buttons."),
        ("Design Mandate", "Replace boxy cards with an organic circular circadian visualizer and an integrated connection status pill.")
    ]
))
story.append(Spacer(1, 14))

# Mobile 2
story.append(make_pdf_card(
    "docs/screenshots/phone_02_bottom_live.png",
    "Action Triggers & OxygenOS Checklist",
    "Screen 2: Mobile Companion Bottom",
    [
        ("Start Sleep Now Button", "Primary action button allowing immediate manual sleep initiation for 7.5 hours."),
        ("Preview Display (10s)", "Tests the external Mac monitor ambient screen directly from bed."),
        ("Test Phone Alarm", "Triggers immediate audio alarm verification to ensure volume and vibration work."),
        ("OxygenOS Checklist", "Battery optimization and accessibility watchdog links to prevent OS background kills."),
        ("Design Mandate", "Move the setup checklist into a dedicated secondary 'Device Health' sheet to keep home view calm.")
    ]
))

story.append(PageBreak())

# Mobile 3: Active Sleep
story.append(make_pdf_card(
    "docs/screenshots/phone_04_active_sleep_live.png",
    "Live Active Sleep Tracking State",
    "Screen 3: Live Active Sleep",
    [
        ("Status Transition", "Status card turns into 'Status: Sleeping' with dynamic target wake-up time calculated to exact minute."),
        ("Countdown Context", "Displays real-time countdown progress toward the 7.5-hour target."),
        ("Instant Control", "Primary action transforms into 'Stop Sleep / I'm Awake' to end tracking at any time."),
        ("Design Mandate", "Provide a breathing ambient pulse indicator with night-sky gradient visuals indicating restful tracking.")
    ]
))
story.append(Spacer(1, 14))

# Mobile 4: Notification Shade
story.append(make_pdf_card(
    "docs/screenshots/phone_05_sleeping_notification_live.png",
    "System Notifications & Quick Glance",
    "Screen 4: Android Notification Shade",
    [
        ("Persistent Notification", "High-priority foreground notification displaying real-time target wake-up time at a glance."),
        ("Lock Screen Visibility", "Visible on always-on display (AOD) or lock screen so users know their alarm is active without unlocking."),
        ("Doze Immunity", "Guarantees the background detection service stays alive through heavy Android battery saver modes.")
    ]
))

story.append(PageBreak())

# Mobile 5 & 6
story.append(make_pdf_card(
    "docs/screenshots/phone_alarm_ringing.png",
    "Morning Alarm Ringing Experience",
    "Screen 5: Wake-Up Alarm Ringing",
    [
        ("Full Screen Illumination", "Fires over lock screen when exact target minute is reached with audio and vibration."),
        ("Dismiss Action", "Provides an immediate 'Stop Alarm / I'm Awake' button to turn off sound and sync wake state to Mac."),
        ("Design Mandate", "Replace basic button with a soothing sunrise gradient and an affirmative 'Slide to Wake Up' gesture.")
    ]
))
story.append(Spacer(1, 14))

story.append(make_pdf_card(
    "docs/screenshots/phone_flow_06_midnight_prompt_live.png",
    "Midnight Prolonged Activity Prompt (Live Notification)",
    "Screen 6: Midnight Activity Filter",
    [
        ("Interactive Choice", "Appears if phone remains active past 5 minutes at night ('Still sleeping? You've been active for 5+ minutes')."),
        ("Action 1: Keep Alarm", "Dismisses prompt and preserves the existing morning wake-up schedule."),
        ("Action 2: Reset Bedtime", "Recalculates a fresh 7.5-hour schedule starting from current moment."),
        ("Design Mandate", "A sleek, non-intrusive bottom sheet or banner that doesn't blind the user in dark environments.")
    ]
))

story.append(PageBreak())

# Mac Screenshots Header
story.append(Paragraph("3.2 macOS Preferences & Monitor Displays", h1_style))
story.append(Paragraph("Captured live from macOS Sequoia on the MacBook Air and connected workstation monitors.", body_style))
story.append(Spacer(1, 6))

def make_mac_pdf_card(img_path, title, label, bullet_points, img_w=230, img_h=230):
    if not os.path.exists(img_path):
        return Paragraph(f"[Image missing: {img_path}]", body_style)
    img = Image(img_path, width=img_w, height=img_h)
    desc_flowables = [
        Paragraph(label.upper(), card_label_style),
        Paragraph(title, card_title_style),
        HRFlowable(width="100%", thickness=0.5, color=colors.HexColor("#E5E5EA"), spaceBefore=2, spaceAfter=6)
    ]
    for b_label, b_desc in bullet_points:
        desc_flowables.append(Paragraph(f"• <b>{b_label}:</b> {b_desc}", card_bullet_style))
    t = Table([[img, desc_flowables]], colWidths=[img_w + 10, 532 - (img_w + 10)])
    t.setStyle(TableStyle([
        ('BACKGROUND', (0,0), (-1,-1), colors.HexColor("#FAFAFC")),
        ('BOX', (0,0), (-1,-1), 1, colors.HexColor("#E5E5EA")),
        ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
        ('LEFTPADDING', (0,0), (-1,-1), 8),
        ('RIGHTPADDING', (0,0), (-1,-1), 10),
        ('TOPPADDING', (0,0), (-1,-1), 8),
        ('BOTTOMPADDING', (0,0), (-1,-1), 8),
    ]))
    return t

story.append(make_mac_pdf_card(
    "docs/screenshots/mac_pref_sleep_live.png",
    "Sleep Schedule & Dynamic Window Settings",
    "Screen 7: Mac Preferences - Sleep Schedule",
    [
        ("Target Sleep Duration", "Numeric stepper allowing custom durations between 1.0 and 16.0 hours (default 7.5h)."),
        ("Eligible Sleep Window", "Configurable start and end dropdowns (9:00 PM to 6:00 AM) that sync with mobile app."),
        ("Auto-Push Window", "Configurable early-evening window (9:00 PM to 11:00 PM) for automatic sleep target postponement."),
        ("Inactivity Offset", "Configurable minutes subtracted from bedtime when phone was untouched before lock.")
    ]
))
story.append(Spacer(1, 14))

story.append(make_mac_pdf_card(
    "docs/screenshots/mac_pref_displays_live.png",
    "Multi-Monitor Selection Manager",
    "Screen 8: Mac Preferences - Displays Tab",
    [
        ("Detected Hardware", "Lists all connected screens (Dell P2722HE, Built-in Retina, Dell S2740L, Sidecar)."),
        ("Ignore Display Toggles", "Allows users to selectively exclude screens (e.g. exclude iPad Sidecar)."),
        ("Native Dimensions", "Displays point resolutions and native frame parameters for pixel-perfect overlays.")
    ]
))

story.append(PageBreak())

story.append(make_mac_pdf_card(
    "docs/screenshots/mac_pref_ambient_live.png",
    "Circadian Ambient Color Customizer",
    "Screen 9: Mac Preferences - Ambient Tab",
    [
        ("Deep Night Glow", "Color picker for nocturnal ultra-dim countdown (default ember #D95926)."),
        ("Dawn Warm Glow", "Color picker for T-30 min melatonin suppression glow (default Sunrise Coral #FA7268)."),
        ("Morning Wake Glow", "Color picker for sunrise wake greeting (default Radiant Solar Gold #FFD000)."),
        ("Test Ambient Display", "Fires an immediate 10-second mirrored preview across all monitors.")
    ]
))
story.append(Spacer(1, 14))

story.append(make_mac_pdf_card(
    "docs/screenshots/mac_flow_05_wakeup_banner.png",
    "Workstation Sunrise Simulation (Radiant Solar Gold)",
    "Screen 10: Workstation Morning Sunrise",
    [
        ("Authentic 3-Stage Progression", "Transitions from Midnight Ember (#D95926) -> Dawn Coral (#FA7268) -> Radiant Solar Gold (#FFD000)."),
        ("Wake-Up Greeting", "Displays warm 'WAKE ME UP' banner with radiant sun icon, current time, and elapsed hours."),
        ("Audio Harmonization", "Coordinates with phone's acoustic alarm for synchronized multi-device awakening.")
    ],
    img_w=230,
    img_h=130
))

story.append(PageBreak())

story.append(make_pdf_card(
    "docs/screenshots/phone_screen_message_card.png",
    "Remote Screen Message Composer (Mobile)",
    "Screen 11: Mobile Screen Message Remote",
    [
        ("Custom Broadcast Input", "Allows user to type ad-hoc text (e.g. 'Taking a quick walk. Back in 15m!')."),
        ("Monitor Targeting", "Dropdown dynamically populated from Mac hardware to target all screens or a single display."),
        ("Duration Selector", "Persistent mode (stays until ESC) or timed toasts (15s / 30s auto-dismiss)."),
        ("Remote Dismiss", "'Clear Screen' button immediately dismisses overlay remotely.")
    ]
))
story.append(Spacer(1, 14))

story.append(make_mac_pdf_card(
    "docs/screenshots/mac_screen_message_billboard.png",
    "Workstation Billboard Overlay (DELL Monitor)",
    "Screen 12: Mac Workstation Billboard Display",
    [
        ("Pitch Black Canvas", "#000000 background prevents OLED/IPS backlight glow in dark environment."),
        ("Dynamic Auto-Scaling", "Font size automatically scales based on character count for maximum readability from distance."),
        ("Origin & Timestamp Header", "Displays subtle origin badge ('MESSAGE FROM PHONE') and current clock time."),
        ("State Reversion", "Dismissing the message cleanly restores active sleep countdown or idle desktop.")
    ],
    img_w=230,
    img_h=130
))

story.append(Spacer(1, 14))

# Section 4: Architecture & Design Recommendations
story.append(Paragraph("4. UX & UI Design Mandates for Mobile Redesign", h1_style))
story.append(Paragraph("The current mobile companion works with 100% technical reliability but presents as an internal engineering console. The designer must elevate this into an intuitive, calm circadian product:", body_style))

ux_mandates = [
    "<b>Hero Circadian Ring:</b> Focal circular dial displaying bedtime, target wake time, and visual gradient arcs representing Sleep, Dawn (T-30m), and Wake phases.",
    "<b>Hardware Connection Pill:</b> Condense the 5-button Mac connection card into a single elegant header pill: '🟢 Connected to MacBook Air' (tapping opens details sheet).",
    "<b>Screen Message Billboard:</b> Clean quick-broadcast widget to display ad-hoc messages on Mac workstation displays with one tap, including display picker and duration pills.",
    "<b>Integrated Windows Timeline Dial:</b> Replace numeric dropdowns with an intuitive 24-hour circular slider allowing users to sculpt their Eligible Sleep and Auto-Push windows.",
    "<b>Secondary Settings Sheet:</b> Relocate technical checklists (OnePlus battery optimizations, ADB developer controls, raw IP fields) into a secondary 'Device Health' sheet.",
    "<b>Sunrise Alarm Experience:</b> Design a full-screen morning gradient canvas with rhythmic pulsing typography and an affirmative 'Slide to Wake Up' thumb slider."
]
for m in ux_mandates:
    story.append(Paragraph(f"• {m}", body_style))

doc.build(story, canvasmaker=NumberedCanvas)
print(f"Successfully generated PDF at: {pdf_filename}")
