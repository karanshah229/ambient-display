import os
import docx
from docx.shared import Inches, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import nsdecls, qn

doc = docx.Document()

# Page Margins
sections = doc.sections
for section in sections:
    section.top_margin = Inches(0.8)
    section.bottom_margin = Inches(0.8)
    section.left_margin = Inches(0.8)
    section.right_margin = Inches(0.8)

# Color Palette Constants
COLOR_PRIMARY = RGBColor(255, 159, 10)     # Warm Ember #FF9F0A
COLOR_SUNRISE = RGBColor(255, 184, 0)     # Sunrise Gold #FFB800
COLOR_DARK = RGBColor(18, 18, 20)         # Obsidian #121214
COLOR_TEXT = RGBColor(40, 40, 45)         # Charcoal
COLOR_MUTED = RGBColor(120, 120, 130)     # Slate Gray
COLOR_GREEN = RGBColor(48, 209, 88)       # Fresh Green #30D158

def set_cell_background(cell, hex_color):
    shading_elm = parse_xml(f'<w:shd {nsdecls("w")} w:fill="{hex_color}"/>')
    cell._tc.get_or_add_tcPr().append(shading_elm)

def add_header(title, level=1):
    h = doc.add_heading(title, level=level)
    h.paragraph_format.space_before = Pt(14)
    h.paragraph_format.space_after = Pt(6)
    run = h.runs[0]
    if level == 1:
        run.font.size = Pt(20)
        run.font.bold = True
        run.font.color.rgb = COLOR_DARK
    elif level == 2:
        run.font.size = Pt(15)
        run.font.bold = True
        run.font.color.rgb = COLOR_PRIMARY
    elif level == 3:
        run.font.size = Pt(12)
        run.font.bold = True
        run.font.color.rgb = COLOR_DARK
    return h

def add_paragraph(text, bold_prefix=None, space_after=6):
    p = doc.add_paragraph()
    p.paragraph_format.space_after = Pt(space_after)
    p.paragraph_format.line_spacing = 1.15
    if bold_prefix:
        r_bold = p.add_run(bold_prefix)
        r_bold.font.bold = True
        r_bold.font.size = Pt(10.5)
        r_bold.font.color.rgb = COLOR_DARK
    r_text = p.add_run(text)
    r_text.font.size = Pt(10.5)
    r_text.font.color.rgb = COLOR_TEXT
    return p

def add_callout(text, title="NOTE FOR DESIGNER"):
    tbl = doc.add_table(rows=1, cols=1)
    tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    cell = tbl.cell(0, 0)
    set_cell_background(cell, "F8F9FA")
    p = cell.paragraphs[0]
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.space_after = Pt(4)
    r1 = p.add_run(f"✦ {title}: ")
    r1.font.bold = True
    r1.font.size = Pt(10)
    r1.font.color.rgb = COLOR_PRIMARY
    r2 = p.add_run(text)
    r2.font.size = Pt(10)
    r2.font.color.rgb = COLOR_TEXT
    doc.add_paragraph().paragraph_format.space_after = Pt(4)

def add_image_card(image_path, title, screen_label, callout_points, max_width=Inches(3.2)):
    if not os.path.exists(image_path):
        add_paragraph(f"[Image file not found: {image_path}]")
        return
    
    tbl = doc.add_table(rows=1, cols=2)
    tbl.alignment = WD_TABLE_ALIGNMENT.CENTER
    tbl.autofit = False
    
    cell_img = tbl.cell(0, 0)
    cell_img.width = Inches(3.3)
    p_img = cell_img.paragraphs[0]
    p_img.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p_img.paragraph_format.space_before = Pt(4)
    p_img.paragraph_format.space_after = Pt(4)
    run_img = p_img.add_run()
    run_img.add_picture(image_path, width=max_width)
    
    cell_desc = tbl.cell(0, 1)
    cell_desc.width = Inches(3.5)
    set_cell_background(cell_desc, "FAFAFC")
    
    p_title = cell_desc.paragraphs[0]
    p_title.paragraph_format.space_before = Pt(8)
    p_title.paragraph_format.space_after = Pt(2)
    r_lbl = p_title.add_run(f"{screen_label.upper()}\n")
    r_lbl.font.size = Pt(8.5)
    r_lbl.font.bold = True
    r_lbl.font.color.rgb = COLOR_PRIMARY
    
    r_t = p_title.add_run(title)
    r_t.font.size = Pt(13)
    r_t.font.bold = True
    r_t.font.color.rgb = COLOR_DARK
    
    for label, desc in callout_points:
        p_pt = cell_desc.add_paragraph()
        p_pt.paragraph_format.space_before = Pt(4)
        p_pt.paragraph_format.space_after = Pt(4)
        p_pt.paragraph_format.line_spacing = 1.15
        r_b = p_pt.add_run(f"• {label}: ")
        r_b.font.bold = True
        r_b.font.size = Pt(9.5)
        r_b.font.color.rgb = COLOR_DARK
        r_d = p_pt.add_run(desc)
        r_d.font.size = Pt(9.5)
        r_d.font.color.rgb = COLOR_TEXT
        
    doc.add_paragraph().paragraph_format.space_after = Pt(8)

# ----------------- DOCUMENT HEADER -----------------
title_p = doc.add_paragraph()
title_p.paragraph_format.space_before = Pt(10)
title_p.paragraph_format.space_after = Pt(2)
run_title = title_p.add_run("WAKE ME UP")
run_title.font.size = Pt(28)
run_title.font.bold = True
run_title.font.color.rgb = COLOR_PRIMARY

sub_p = doc.add_paragraph()
sub_p.paragraph_format.space_after = Pt(14)
run_sub = sub_p.add_run("Complete Product, Architecture & UX Design Blueprint (1-Stop Designer Guide)")
run_sub.font.size = Pt(14)
run_sub.font.color.rgb = COLOR_MUTED

add_paragraph(
    "This document is a comprehensive, standalone specification designed for UI/UX product designers. "
    "It explains the complete product philosophy, features, technical architecture, and user flows of Wake Me Up. "
    "Every existing screen from both the mobile Android app and macOS desktop companion is documented alongside "
    "explicit callouts detailing what the engineering implementation currently does and how the future UI should be elevated."
)

# ----------------- SECTION 1: PRODUCT BRIEF -----------------
add_header("1. Executive Product Brief", level=1)
add_paragraph(
    "Conventional alarm clocks operate on an archaic model: they require manual setting and assume a rigid bedtime. "
    "If a person wants 7.5 hours of sleep and plans to sleep at 10:00 PM, they set an alarm for 5:30 AM. "
    "However, real human habits are dynamic. If they stay awake watching videos, browsing social media, or reading in bed until 11:15 PM, "
    "the alarm doesn't adapt—it rings at 5:30 AM regardless, leaving the user sleep-deprived and groggy. "
    "Furthermore, traditional alarms shock the sleeper awake in a pitch-black room with shrill ringtones, spiking cortisol levels."
)
add_paragraph(
    "Wake Me Up introduces an intelligent, zero-friction sleep detection and sunrise alarm ecosystem spanning Android (bedside phone) "
    "and macOS (workstation displays and laptop). Instead of demanding manual alarms: ",
    bold_prefix="The Paradigm Shift: "
)
p_points = [
    ("Silent Sleep Detection", "The phone detects when you actually fall asleep based on screen locks and UsageStats inactivity compensation."),
    ("Dynamic Circadian Push", "If you stay awake in bed within your configurable bedtime window, your target wake-up time dynamically pushes forward to guarantee 7.5 hours of restorative sleep."),
    ("Ambient Room Beacon", "External workstation monitors turn into an ultra-dim bedroom countdown, smoothly illuminating into a warm sunrise glow 30 minutes before wake-up."),
    ("Intelligent Glance Filter", "Waking up at 3:00 AM for 20 seconds to check a quick message or drink water will never postpone or reset your alarm, while sustained nocturnal activity (>3 minutes) triggers a gentle, respectful prompt.")
]
for title, desc in p_points:
    add_paragraph(desc, bold_prefix=f"• {title}: ")

add_callout(
    "Wake Me Up should feel like high-end wellness hardware (similar to Oura Ring, Apple Health, or Loftie Clock). "
    "The UI must replace technical developer clutter with calm, organic nighttime aesthetics.",
    title="CORE DESIGN PRINCIPLE"
)

# ----------------- SECTION 2: FEATURE SPECIFICATIONS -----------------
add_header("2. Detailed Feature Breakdown", level=1)

add_header("2.1 Smart Sleep Detection & Inactivity Compensator", level=2)
add_paragraph(
    "When the user locks their phone during their eligible nocturnal hours (default: 9:00 PM – 6:00 AM), the background service begins sleep tracking. "
    "However, if a user put their phone face down 35 minutes earlier while falling asleep, simply recording the lock timestamp would be inaccurate. "
    "The app queries Android's UsageStatsManager to determine the true last user interaction. If inactivity exceeds a threshold (default: 30 minutes), "
    "the bedtime is back-calculated to when the user actually drifted off."
)

add_header("2.2 Eligible Sleep Window vs. Auto-Push Window", level=2)
add_paragraph(
    "To avoid false triggers and unnecessary alarms, the system strictly defines two distinct time windows: ",
    bold_prefix="Dual Window Mechanics: "
)
add_paragraph(
    "Prevents false alarms during daytime productivity. Leaving your phone face down at 2:00 PM on a workday will completely ignore inactivity and never trigger sleep.",
    bold_prefix="1. Eligible Sleep Window (e.g. 9:00 PM – 6:00 AM): "
)
add_paragraph(
    "During this evening window, any phone interaction automatically and silently rolls your 7.5-hour wake target forward without interrupting you. Outside this window (e.g., past 11:00 PM), the alarm is locked and requires user consent to change.",
    bold_prefix="2. Auto-Push Window (e.g. 9:00 PM – 11:00 PM): "
)

add_header("2.3 Midnight Glance vs. Insomnia Filter", level=2)
add_paragraph(
    "Humans frequently wake up momentarily in the night to check the time or drink water. Wake Me Up categorizes midnight activity: "
)
add_paragraph(
    "Screen unlocked and locked within 60 seconds. The existing sleep session and morning alarm remain completely untouched.",
    bold_prefix="• Brief Glance (< 60s): "
)
add_paragraph(
    "Screen stays on past 3 minutes (e.g. scrolling social media). A high-priority heads-up prompt is presented with two explicit choices: 'Keep Original Alarm' or 'Reset Bedtime to Now (Push 7.5h)'.",
    bold_prefix="• Prolonged Activity (> 3 min): "
)

add_header("2.4 Multi-Monitor Workstation Ambient Display", level=2)
add_paragraph(
    "Over local Wi-Fi, the Mac receives the bedtime trigger and renders a borderless mirrored display across all connected monitors. "
    "The background is pitch black (#000000) with ultra-dim monochromatic countdown typography. Power assertions (IOPMAssertion) prevent "
    "the MacBook and external screens from going to sleep. Pressing the physical ESC key on the Mac instantly dismisses the display."
)

add_header("2.5 Circadian Dawn Simulation & Morning Alarm", level=2)
add_paragraph(
    "30 minutes prior to the wake target, the displays transition into a gentle dawn amber (#FFBF66) glow, gradually brightening to suppress melatonin. "
    "At T-0 minutes, screens switch to a warm sunrise yellow (#FFB800) with a 'Good Morning' greeting, while the phone fires an exact hardware RTC audio alarm."
)

add_header("2.6 Zero-Cloud Local Wi-Fi Sync & Away Mode", level=2)
add_paragraph(
    "No external servers, user accounts, or telemetry exist. The Mac advertises over Bonjour (_wakemeup._tcp) and the Android app auto-discovers it. "
    "All configuration changes sync bidirectionally. If Away Mode is enabled, external monitors stay off while the phone alarm continues to work normally."
)

add_header("2.7 Remote Screen Message Billboard (Manual Display Broadcast)", level=2)
add_paragraph(
    "Allows the user to manually type a custom message on their phone and broadcast it to connected Mac workstation displays (e.g. 'Taking a quick walk. Back in 15m!'). "
    "Features dynamic monitor targeting (all displays mirrored or specific monitor), duration control (persistent billboard or 15s/30s timed toast), "
    "and seamless mutual-exclusion state reversion (if a message is dismissed on a screen during an active sleep session, that screen immediately reverts back to its sleep countdown)."
)

# ----------------- SECTION 3: VISUAL SCREEN-BY-SCREEN GALLERY -----------------
add_header("3. Complete Visual Screen-by-Screen Gallery", level=1)
add_paragraph(
    "Below are the actual screenshots captured directly from the OnePlus 12 mobile device and MacBook Air workstation. "
    "Each image includes detailed annotations describing what the user is experiencing and what needs design refinement."
)

add_header("3.1 Mobile App: Dashboard, Settings & Active Sleep", level=2)

add_image_card(
    "docs/screenshots/phone_01_top_live.png",
    "Mobile Home Dashboard & Settings",
    "Screen 1: Mobile Companion Top",
    [
        ("Status Card", "Shows 'Standby (Outside Sleep Window)' in fresh green. In daytime, it indicates sleep tracking is inactive."),
        ("Sleep Windows & Duration", "Displays target 7.5h duration, Eligible Window (9PM-6AM), and Auto-Push Window (9PM-11PM)."),
        ("Away Mode Toggle", "Allows user to suppress monitor activation when sleeping away from home."),
        ("Mac Connection Card", "Shows the connected Mac IP (192.168.1.2) with Save, Ping, and Auto-Discover buttons."),
        ("Design Goal", "Transform this engineering card view into an organic circular circadian visualizer with integrated pairing status.")
    ]
)

add_image_card(
    "docs/screenshots/phone_02_bottom_live.png",
    "Action Triggers & Device Health Checklist",
    "Screen 2: Mobile Companion Bottom",
    [
        ("Start Sleep Now Button", "Primary action button allowing immediate manual sleep initiation for 7.5 hours."),
        ("Preview Display (10s)", "Tests the external Mac monitor ambient screen directly from bed."),
        ("Test Phone Alarm", "Triggers immediate audio alarm verification to ensure volume and vibration work."),
        ("OxygenOS Setup Checklist", "Critical battery optimization and accessibility watchdog links to prevent background OS kills."),
        ("Design Goal", "Move the OxygenOS setup checklist into a dedicated secondary 'Device Health' sheet to keep the primary screen calm.")
    ]
)

add_image_card(
    "docs/screenshots/phone_04_active_sleep_live.png",
    "Active Sleep Tracking State",
    "Screen 3: Live Active Sleep",
    [
        ("Status Transition", "Status card turns into 'Status: Sleeping' with dynamic target wake-up time calculated to the exact minute."),
        ("Countdown Context", "Displays real-time countdown progress toward the 7.5-hour target."),
        ("Instant Control", "The primary action transforms into 'Stop Sleep / I'm Awake' to end tracking at any time."),
        ("Design Goal", "Provide a breathing ambient pulse indicator with night-sky gradient visuals indicating restful tracking.")
    ]
)

add_image_card(
    "docs/screenshots/phone_05_sleeping_notification_live.png",
    "System Notifications & Quick Glance",
    "Screen 4: Android Notification Shade",
    [
        ("Persistent Notification", "High-priority foreground notification displaying real-time target wake-up time at a glance."),
        ("Lock Screen Visibility", "Visible on always-on display (AOD) or lock screen so users know their alarm is active without unlocking."),
        ("Doze Immunity", "Guarantees the background detection service stays alive through heavy Android battery saver modes.")
    ]
)

add_image_card(
    "docs/screenshots/phone_alarm_ringing.png",
    "Morning Alarm Ringing Experience",
    "Screen 5: Wake-Up Alarm Ringing",
    [
        ("Full Screen Illumination", "Fires over lock screen when exact target minute is reached with audio and vibration."),
        ("Dismiss Action", "Provides an immediate 'Stop Alarm / I'm Awake' button to turn off sound and sync wake state to Mac."),
        ("Design Goal", "Replace basic button with a soothing full-screen sunrise gradient and an affirmative 'Slide to Wake Up' gesture.")
    ]
)

add_image_card(
    "docs/screenshots/phone_flow_06_midnight_prompt_live.png",
    "Midnight Prolonged Activity Prompt (Live Notification)",
    "Screen 6: Midnight Activity Filter",
    [
        ("Interactive Choice", "Appears if phone remains active past threshold during nocturnal hours ('Still sleeping? You've been active for 5+ minutes')."),
        ("Action 1: Keep Alarm", "Dismisses prompt and preserves the existing morning wake-up schedule."),
        ("Action 2: Reset Bedtime to Now", "Recalculates a fresh 7.5-hour schedule starting from the current moment."),
        ("Design Goal", "Elevate into a calm, non-intrusive bottom sheet or banner with high contrast and smooth dark mode styling.")
    ]
)

add_header("3.2 macOS Desktop Utility: Menu Bar & Preferences", level=2)

add_image_card(
    "docs/screenshots/mac_pref_sleep_live.png",
    "Sleep Schedule & Dynamic Window Settings",
    "Screen 7: Mac Preferences - Sleep Schedule",
    [
        ("Target Sleep Duration", "Numeric stepper allowing custom durations between 1.0 and 16.0 hours (default 7.5h)."),
        ("Eligible Sleep Window", "Configurable start and end dropdowns (e.g. 9:00 PM to 6:00 AM) that sync with the mobile app."),
        ("Auto-Push Window", "Configurable early-evening window (e.g. 9:00 PM to 11:00 PM) for automatic sleep target postponement."),
        ("Inactivity Offset", "Configurable minutes subtracted from bedtime when phone was left untouched before lock.")
    ]
)

add_image_card(
    "docs/screenshots/mac_pref_displays_live.png",
    "Multi-Monitor Selection Manager",
    "Screen 8: Mac Preferences - Displays Tab",
    [
        ("Detected Hardware", "Lists all connected physical and virtual screens (Dell P2722HE, Built-in Retina, Dell S2740L, Sidecar)."),
        ("Ignore Display Toggles", "Allows users to selectively exclude screens (e.g., exclude iPad Sidecar or secondary monitor)."),
        ("Resolution & Aspect Ratio", "Displays point dimensions and native frame parameters for pixel-perfect overlays.")
    ]
)

add_image_card(
    "docs/screenshots/mac_pref_ambient_live.png",
    "Circadian Ambient Color & Palette Customizer",
    "Screen 9: Mac Preferences - Ambient Tab",
    [
        ("Deep Night Glow", "Color picker for nocturnal ultra-dim countdown (default ember #D95926)."),
        ("Dawn Warm Glow", "Color picker for T-30 minute melatonin suppression glow (default Sunrise Coral #FA7268)."),
        ("Morning Wake-Up Glow", "Color picker for sunrise wake greeting (default Radiant Solar Gold #FFD000)."),
        ("Test Ambient Display Button", "Fires an immediate 10-second mirrored preview across all monitors.")
    ]
)

add_image_card(
    "docs/screenshots/mac_pref_network_live.png",
    "Local Network Hub & Auto-Discovery Info",
    "Screen 10: Mac Preferences - Network Tab",
    [
        ("Local Wi-Fi IP", "Displays the current DHCP Wi-Fi address (192.168.1.2) allocated to the MacBook."),
        ("HTTP Port", "Lightweight HTTP server running on dedicated port 8321."),
        ("Bonjour mDNS", "Broadcasts _wakemeup._tcp service so phone discovers the Mac without manual IP entry.")
    ]
)

add_header("3.3 Workstation Ambient Display Modes (Physical Monitors)", level=2)

add_image_card(
    "docs/screenshots/test_02_dell_monitor_night.png",
    "Night Countdown Ambient Mode (Ultra Dim)",
    "Screen 11: Workstation Night Countdown",
    [
        ("Pure True-Black Canvas", "#000000 background ensures zero backlight bleed on IPS/OLED displays in a dark bedroom."),
        ("Minimal Typography", "Monochromatic, subdued countdown displays remaining sleep hours and minutes."),
        ("Power Assertions", "Keeps screens powered without letting macOS trigger DPMS standby."),
        ("Dismissal", "Pressing the ESC key on the Mac keyboard immediately closes the overlay.")
    ]
)

add_image_card(
    "docs/screenshots/mac_flow_05_wakeup_banner.png",
    "Sunrise Wake-Up Simulation (Radiant Solar Gold #FFD000)",
    "Screen 12: Morning Sunrise Illumination",
    [
        ("Authentic 3-Stage Progression", "Evolves naturally from Midnight Ember (#D95926) -> Dawn Coral (#FA7268) -> Radiant Solar Gold (#FFD000)."),
        ("Wake-Up Greeting", "Displays warm 'WAKE ME UP' banner with current time, sun iconography, and 7.5 hours completed message."),
        ("Audio Harmonization", "Coordinates with the phone's acoustic alarm for a synchronized multi-device awakening.")
    ]
)

add_header("3.4 Remote Screen Message Billboard (Live Mobile & Monitor Pairing)", level=2)

add_image_card(
    "docs/screenshots/phone_screen_message_card.png",
    "Mobile Message Composer & Remote Controller",
    "Screen 13: Mobile Screen Message Card",
    [
        ("Custom Message Field", "Multi-line input allowing arbitrary custom text (e.g. 'Taking a quick walk. Back in 15m!')."),
        ("Dynamic Display Targeting", "Spinner dynamically queried from Mac to target 'All Displays (Mirrored)' or a single monitor."),
        ("Duration Selector", "Radio options for Persistent (manual ESC dismiss), 15s Toast, or 30s Toast."),
        ("Action Controls", "Instant 'Send to Screen' broadcast and remote 'Clear Screen' button.")
    ]
)

add_image_card(
    "docs/screenshots/mac_screen_message_billboard.png",
    "Workstation Billboard Display (DELL Monitor)",
    "Screen 14: Mac Monitor Billboard Overlay",
    [
        ("Pure True-Black Canvas", "#000000 background prevents OLED/IPS backlight glow in dark environment."),
        ("Dynamic Auto-Scaling Typography", "Soft off-white (#E0E0E6) font automatically scales based on length (massive for short notes, proportional for sentences)."),
        ("Source & Timestamp Header", "Subtle header indicating origin ('MESSAGE FROM PHONE') and current time."),
        ("Universal Dismissal", "Dismissable via ESC key on Mac keyboard, clicking anywhere on screen, or 'Clear Screen' on mobile.")
    ]
)

# ----------------- SECTION 4: TECHNICAL ARCHITECTURE -----------------
add_header("4. Technical Architecture & Communication Protocols", level=1)
add_paragraph(
    "Wake Me Up operates as a distributed local-first ecosystem. No external cloud infrastructure or user databases are utilized. "
    "All telemetry and synchronization take place over local Wi-Fi between the Android mobile device and macOS workstation."
)

add_header("4.1 Local REST API Endpoints (Mac Server :8321)", level=2)
api_rows = [
    ("GET /api/status", "Returns current session state (idle, sleeping, wakeUpReady), active monitors count, and away mode."),
    ("POST /api/sleep", "Payload: { bedtime_epoch_ms, duration_minutes, reason }. Activates sleep session and mirrored display overlays."),
    ("POST /api/wake", "Payload: {}. Dismisses ambient overlays, releases power assertions, returns app to idle."),
    ("POST /api/test", "Payload: { duration_seconds }. Runs 10s preview across all displays."),
    ("POST /api/away", "Payload: { is_away_mode }. Toggles or sets Away Mode status."),
    ("GET & POST /api/config", "Bidirectional synchronization of sleep duration, window start/end hours, and inactivity offsets."),
    ("GET /api/displays", "Returns real-time list of connected Mac displays with ID, localized name, dimensions, and active mode (idle, sleeping, message)."),
    ("POST /api/message", "Payload: { text, target_display_id, duration_seconds }. Renders fullscreen message overlay on targeted monitor(s)."),
    ("POST /api/message/dismiss", "Payload: { target_display_id }. Clears message and seamlessly reverts screen(s) to sleep countdown or desktop."),
    ("GET /api/message/status", "Returns all active messages and remaining countdown timers.")
]
for ep, desc in api_rows:
    add_paragraph(desc, bold_prefix=f"• {ep}: ")

add_header("4.2 Resilient Network Auto-Discovery", level=2)
add_paragraph(
    "To handle dynamic home routers where DHCP addresses change (e.g. from 192.168.1.3 to 192.168.1.2), Wake Me Up implements a multi-tier discovery pipeline: "
)
add_paragraph(
    "1. Cached IP Quick-Probe (< 400ms): Attempts instant connection to the last verified IP.\n"
    "2. Bonjour / mDNS Service Discovery: Resolves '_wakemeup._tcp' published by macOS NWListener.\n"
    "3. High-Speed Subnet Scan (< 200ms): Concurrently probes all 254 subnet socket endpoints on port 8321 to locate the Mac even if router mDNS multicast is filtered."
)

# ----------------- SECTION 5: UX SPECIFICATION FOR MOBILE REDESIGN -----------------
add_header("5. UX & UI Design Recommendations for Mobile Redesign", level=1)
add_paragraph(
    "The current mobile application functions with complete engineering reliability, but its visual presentation is that of an internal engineering test tool. "
    "A senior UI/UX designer should transform the app based on the following structural pillars:"
)

pillars = [
    ("Hero Circadian Ring", "Replace flat card boxes with a focal circular circadian ring. The ring shows bedtime, target wake time, and visual gradient arcs representing the Sleep Phase (deep ember), Dawn Phase (amber), and Wake Time (sunrise gold)."),
    ("Seamless Hardware Connection Pill", "Condense the current 5-button Mac connection card into a single elegant hardware pill at the top: '🟢 Connected to MacBook Air'. Tapping the pill opens a connection bottom sheet with advanced network controls."),
    ("Integrated Windows Timeline Dial", "Replace numeric dropdowns with an intuitive 24-hour circular slider allowing users to visually sculpt their Eligible Sleep Window and Auto-Push Window with smooth haptic feedback."),
    ("Secondary Settings Sheet", "Relocate technical checklists (OnePlus battery optimizations, ADB developer controls, raw IP fields) into a secondary 'Device Health & Settings' sheet, preserving the serenity of the main resting view."),
    ("Soothing Sunrise Alarm Screen", "Design a full-screen morning gradient canvas with gentle rhythmic pulsing typography and an affirmative 'Slide to Wake Up' thumb slider to prevent accidental dismissal.")
]
for title, desc in pillars:
    add_paragraph(desc, bold_prefix=f"{title}: ")

add_callout(
    "Deliverables expected from designer: Figma design system with Night/Dark mode palette, Component specifications, "
    "Hero Home Dashboard screen, Active Sleep mode screen, Sunrise Alarm Ringing screen, and Settings / Hardware sheet.",
    title="DESIGNER ACTION ITEM"
)

output_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "docs", "WakeMeUp_Product_Design_Specification.docx")
doc.save(output_path)
print(f"Successfully generated designer guide at: {output_path}")
