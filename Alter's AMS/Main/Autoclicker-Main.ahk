#Requires AutoHotkey v2.0
#Include Gdip_All.ahk
#SingleInstance Force
#MaxThreadsPerHotkey 100
Persistent

; ============================================================
; LIVE MONITOR WINDOW (Recorder loop)
; A small always-on-top window that appears while a recording is playing on
; "Loop Until Stopped" and shows what it is doing. It never takes focus, so
; whatever you are controlling keeps keyboard input.
; ============================================================
class RunMonitor {
    __New(title, rowNames, updater) {
        global bg, fg, sub, accent, MyGui
        this.updater := updater
        this.startTick := A_TickCount
        this.rows := Map()
        this.alive := true
        this.actKey := ""
        this.actTick := A_TickCount
        g := Gui("+AlwaysOnTop +ToolWindow", title " - Live Monitor")
        g.BackColor := bg
        g.SetFont("s12 bold c" accent, "Bahnschrift")
        g.AddText("x12 y8 w276", title)
        g.SetFont("s9 c" sub, "Bahnschrift")
        y := 34
        for name in rowNames {
            h := (name = "Current action") ? 36 : 18
            g.SetFont("s9 c" sub, "Bahnschrift")
            g.AddText("x12 y" y " w96 h" h, name)
            g.SetFont("s9 bold c" fg, "Bahnschrift")
            this.rows[name] := g.AddText("x112 y" y " w176 h" h, "-")
            y += h + 4
        }
        this.gui := g
        g.OnEvent("Close", (*) => this.Close())

        px := 20, py := 20
        try {
            WinGetPos(&mx, &my, &mw, &mh, "ahk_id " MyGui.Hwnd)
            px := mx + mw + 8
            py := my
            if px + 300 > A_ScreenWidth
                px := Max(0, A_ScreenWidth - 300)
        }
        g.Show("NoActivate x" px " y" py " w300 h" (y + 4))
        this.timer := ObjBindMethod(this, "Tick")
        SetTimer(this.timer, 500)
        this.Tick()
    }

    Set(name, text) {
        if this.alive && this.rows.Has(name) && this.rows[name].Text != text
            this.rows[name].Text := text
    }

    ; Shows the current action plus how long it has been running. Digits are
    ; ignored when deciding whether it is still the same action, so text that
    ; already counts (e.g. "playing... 3m 12s") keeps one continuous timer.
    SetAction(text) {
        if !this.alive
            return
        key := RegExReplace(text, "\d+", "#")
        if key != this.actKey {
            this.actKey := key
            this.actTick := A_TickCount
        }
        secs := (A_TickCount - this.actTick) // 1000
        this.Set("Current action", text "  (" (secs // 60) ":" SubStr("0" Mod(secs, 60), -2) ")")
    }

    Tick() {
        if !this.alive
            return
        try this.updater.Call(this)
    }

    Close() {
        if !this.alive
            return
        this.alive := false
        SetTimer(this.timer, 0)
        try this.gui.Destroy()
    }
}

; AHK's default is to pop up a warning dialog once 70 hotkey activations land
; inside a 2000ms window (A_MaxHotkeysPerInterval=70, A_HotkeyInterval=2000).
; A fast clicker/recorder can trip that, so turn the dialog off entirely.
A_HotkeyInterval := 0
A_MaxHotkeysPerInterval := 99000000
CoordMode("Mouse", "Screen")

TraySetIcon(A_ScriptDir "\AutoClicker_icon.png")
; Tray icon: click it (or use the menu) to bring the macro window back if it was minimized away.
A_TrayMenu.Insert("1&", "Show Macro AIO", TrayShowMain)
A_TrayMenu.Default := "Show Macro AIO"
A_TrayMenu.ClickCount := 1
TrayShowMain(*) {
    global MyGui
    try {
        MyGui.Show()
        if WinGetMinMax("ahk_id " MyGui.Hwnd) = -1
            WinRestore("ahk_id " MyGui.Hwnd)
        WinActivate("ahk_id " MyGui.Hwnd)
    }
}

; =====================================================
;   AUTOCLICKER — compact wide UI, three modes, stats
; =====================================================
; Modes (selected via the MODE dropdown on the Clicker tab):
;   - Normal      : fires a real mouse click at the cursor.
;   - Window Focus: posts clicks to the exact child control
;                   under a chosen point without activating
;                   that window/tab.
;   - Key Press   : "presses" a chosen letter/number key
;                   instead of clicking. Goes to whichever
;                   window currently has keyboard focus.
; Reality check: background-tab clicking inside one browser
; window is not possible (tabs share one HWND and get
; throttled when inactive) — pop the target into its own
; window first. Some anti-cheat systems (e.g. Roblox/Hyperion)
; also detect and block synthetic input by design.
; =====================================================

dataFile := A_ScriptDir "\AutoClicker_data.ini"

; ---------- State ----------
clicking       := false
sessionClicks  := 0
toggleKey      := "F6"
targetHwnd     := 0
targetTopHwnd  := 0
targetTitle    := ""
clickX         := 0
clickY         := 0
pickMode       := false
winList        := Map()

cpsWindowStart := 0
cpsWindowCount := 0
sessionPeakCps := 0.0
appStartTick   := A_TickCount

; ---------- High Speed Mode state ----------
hsFreq        := 0      ; high-res counter ticks per second
hsLast        := 0      ; counter reading at the previous High Speed tick
hsCarry       := 0.0    ; fractional clicks still owed from earlier ticks
hsRunClicks   := 0      ; clicks fired since this run started (for Fixed Count)

; ---------- Recorder state ----------
recording            := false
playing              := false
recordedEvents       := []
recordStartTick      := 0
lastMoveX            := 0
lastMoveY            := 0
playbackIndex        := 1
playbackStartTick    := 0
playbackRepeatsTotal := 1
playbackRepeatsDone  := 0
playbackPaused       := false
playbackPauseStartTick := 0
recordingFilePath    := ""
recKeyList           := BuildRecordableKeyList()


lifetimeClicks   := Integer(IniRead(dataFile, "Stats", "LifetimeClicks", 0))
totalSessions    := Integer(IniRead(dataFile, "Stats", "TotalSessions", 0)) + 1
lifetimeRuntime  := Integer(IniRead(dataFile, "Stats", "LifetimeRuntimeSec", 0))
longestSession   := Integer(IniRead(dataFile, "Stats", "LongestSessionSec", 0))
peakCpsEver      := Float(IniRead(dataFile, "Stats", "PeakCpsEver", 0))
IniWrite(totalSessions, dataFile, "Stats", "TotalSessions")

cpsTestRunning     := false
cpsTestClicks      := 0
cpsTestEndTick     := 0
cpsCooldownEndTick := 0

; ---------- Dashboard state ----------
dashboardImagePath := IniRead(dataFile, "Dashboard", "ImagePath", "")
currentPage := ""

; ---------- Version / updates ----------
APP_VERSION := "1.0"
updSource := IniRead(dataFile, "Updates", "Source", "https://raw.githubusercontent.com/AlterUnknown/Autoclicker-AMS/main/")
updCheckOnLaunch := (IniRead(dataFile, "Updates", "CheckOnLaunch", "1") = "1")
updLatest := ""
updFilePath := ""      ; optional file path given on line 2 (ahk) / 3 (exe) of version.txt

; ---------- Background image state ----------
bgImagePath := IniRead(dataFile, "Background", "ImagePath", "")
bgDim := Integer(IniRead(dataFile, "Background", "Dim", "35"))
bgHbm := 0
bgBmpW := 0
bgBmpH := 0
bgRoundOk := 0
bgRoundFail := 0
bgRoundErr := ""
bgTransCtrls := []
bgPlain := []
bgGroups := []
bgGroupBrush := 0
bgLastText := Map()
bgTransOn := false

; ---------- Macro playback keybind (persisted so it survives a restart) ----------
playbackToggleKey := IniRead(dataFile, "Hotkeys", "PlaybackKey", "F4")

; ---------- Theme ----------
; Diavolo-inspired pink-only palette: neutral charcoal base, ivory text,
; and multiple shades of pink for accents, buttons, and states.
bg      := "101010"   ; neutral near-black (no purple tint)
fg      := "F7EAF0"   ; soft ivory-pink text
sub     := "B995A8"   ; muted pink-gray secondary text
accent  := "E0568C"   ; core Diavolo pink
green   := "D66A9C"   ; running/positive state, still pink
red     := "FF4F7B"   ; stop/danger state, pink-red

; ---------- Window size ----------
; 1.0 = the original size. Lower = smaller / more compact window.
; UI_FONT_SCALE shrinks the text on its own (raise it if text looks cramped).
UI_SCALE      := 0.80
UI_FONT_SCALE := 0.88

; ================= GUI =================
MyGui := Gui("+Resize", "Macro AIO")
gdipToken := Gdip_Startup()
gdipButtons := []
MyGui.BackColor := bg
MyGui.SetFont("s9 c" fg, "Bahnschrift")

; ---- Header ----
MyGui.SetFont("s13 bold c" fg, "Bahnschrift")
hdrTitle := MyGui.AddText("x16 y12 w300 h24", "")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
chkTop := MyGui.AddCheckbox("x621 y16 w130 c" sub, "Always on top")
chkTop.OnEvent("Click", (*) => WinSetAlwaysOnTop(chkTop.Value, MyGui))

; ============================================================
; LEFT SIDEBAR NAVIGATION
; ============================================================
; Flat list of native buttons, indented per nesting level. Clicking
; one calls ShowPage(key), which shows only that page's controls
; (collected into the `pages` map below as each page is built) and
; re-labels the active button with a leading marker.
navLabels := Map()
navButtons := Map()

MakeNavButton(key, x, y, w, label) {
    global navLabels, navButtons, MyGui, bg, fg
    navLabels[key] := label
    btn := MyGui.AddText("x" x " y" y " w" w " h26 Background" bg " c" fg " 0x200", label)
    btn.SetFont("s9")
    btn.OnEvent("Click", (*) => ShowPage(key))
    navButtons[key] := btn
    return btn
}

MakeNavButton("dashboard", 8, 44, 128, "Dashboard")

MyGui.SetFont("s8 bold c" accent, "Bahnschrift")
MyGui.AddText("x12 y78 w128", "CLICKER")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
MakeNavButton("autoclicker", 8, 96, 128, "Auto Clicker")
MakeNavButton("cpstest", 20, 124, 116, "CPS Test")
MakeNavButton("sessionstats", 20, 152, 116, "Session Stats")

MyGui.SetFont("s8 bold c" accent, "Bahnschrift")
MyGui.AddText("x12 y186 w128", "MACRO")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
MakeNavButton("macro", 8, 204, 128, "Recorder")
MakeNavButton("macroprofiles", 20, 232, 116, "Macro Profiles")
MakeNavButton("actions", 8, 260, 128, "Actions")

MyGui.SetFont("s8 bold c" accent, "Bahnschrift")
MyGui.AddText("x12 y292 w128", "MISC")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
MakeNavButton("settings", 8, 312, 128, "Settings")

; ============================================================
; PAGE — DASHBOARD
; ============================================================
MyGui.SetFont("s20 bold c" accent, "Bahnschrift")
dashTitle := MyGui.AddText("x145 y70 w600 h34 Center", "MACRO AIO")
MyGui.SetFont("s10 c" sub, "Bahnschrift")
dashCredit := MyGui.AddText("x145 y108 w600 h20 Center", "Created by AlterUnknown")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

dashPicFrame := MyGui.AddGroupBox("x145 y140 w600 h250 c" fg, "")
dashDefaultPic := A_ScriptDir "\AutoClicker_icon.png"
dashInitialPic := (dashboardImagePath != "" && FileExist(dashboardImagePath)) ? dashboardImagePath : dashDefaultPic
dashPic := MyGui.AddPicture("x155 y150 w580 h200 Border", dashInitialPic)
MyGui.SetFont("s9 c" fg, "Bahnschrift")

pageDashboard := [dashTitle, dashCredit, dashPicFrame, dashPic]


; -- Left column: mode + swappable mode panel --
anon_pageautoclickertxt_1 := MyGui.AddText("x145 y70 w280 c" accent, "MODE")
anon_pageautoclickertxt_1.SetFont("s9 bold")
ddMode := MyGui.AddDropDownList("x145 y88 w280 c000000", ["Normal (click at cursor)", "Window Focus (background click)", "Key Press (auto-press key)"])
ddMode.Choose(1)

; -- Mode panel: exactly one of these three is visible at a time --
grpNormal := MyGui.AddGroupBox("x145 y120 w280 h190 c" sub, "Normal Click")
txtNormalHint1 := MyGui.AddText("x157 y150 w260 c" sub, "Clicks fire at your current mouse")
txtNormalHint2 := MyGui.AddText("x157 y166 w260 c" sub, "cursor position, using the button")
txtNormalHint3 := MyGui.AddText("x157 y182 w260 c" sub, "and type set under CLICK OPTIONS.")

grpTarget := MyGui.AddGroupBox("x145 y120 w280 h190 c" sub, "Target Window")
txtWinLabel := MyGui.AddText("x157 y142 w70", "Window")
ddWinList := MyGui.AddDropDownList("x231 y140 w140 c000000", ["(click Refresh)"])
btnRefresh := MakeStyledButton(MyGui, 375, 139, 40, 22, "⟳", (*) => RefreshWindowList(), "7D1F46", "52132F")
btnUseSelected := MakeStyledButton(MyGui, 157, 172, 126, 26, "Use Selected", (*) => UseSelectedWindow(), "A43B68", "6F2147")
btnPickSpot    := MakeStyledButton(MyGui, 289, 172, 126, 26, "Set Spot (F3)", (*) => BeginPickSpot(), "C34778", "86254F")
txtTarget := MyGui.AddText("x157 y204 w268 c" sub, "No window selected")
txtCoords := MyGui.AddText("x157 y222 w268 c" sub, "Click position: -")

grpKey := MyGui.AddGroupBox("x145 y120 w280 h190 c" sub, "Key To Press")
txtKeyLabel := MyGui.AddText("x157 y146 w120", "Key")
ddKeyPress := MyGui.AddDropDownList("x157 y166 w128 c000000", KeyPressOptions())
ddKeyPress.Choose(1)
txtKeyHint1 := MyGui.AddText("x157 y200 w260 c" sub, "The clicker will press this key")
txtKeyHint2 := MyGui.AddText("x157 y216 w260 c" sub, "on your keyboard (down + up) instead")
txtKeyHint3 := MyGui.AddText("x157 y232 w260 c" sub, "of performing a mouse click.")

btnTest := MakeStyledButton(MyGui, 157, 258, 258, 24, "Test Click Once", (*) => TestClick(), "E0568C", "8C2F57")

anon_pageautoclickertxt_2 := MyGui.AddText("x145 y320 w280 c" accent, "HOTKEY  /  SAFETY")
anon_pageautoclickertxt_2.SetFont("s9 bold")
anon_pageautoclickertxt_3 := MyGui.AddText("x145 y340 w80", "Toggle key")
; A Hotkey control (not a fixed dropdown) so the toggle key can be ANY key
; or combo — letters, numbers, Ctrl/Alt/Shift combos, mouse side buttons, etc.
ddHotkey := MyGui.AddHotkey("x228 y338 w70 c000000", "F6")
chkFailsafe := MyGui.AddCheckbox("x145 y368 w280 c" fg, "Failsafe: stop at bottom of screen")
chkFailsafe.Value := 1

; -- Right column: interval + options + status --
anon_pageautoclickertxt_4 := MyGui.AddText("x453 y70 w280 c" accent, "CLICK INTERVAL")
anon_pageautoclickertxt_4.SetFont("s9 bold")
anon_pageautoclickertxt_5 := MyGui.AddText("x453 y92 w50", "Hours")
eHours := MyGui.AddEdit("x498 y90 w40 Center c000000", "0")
anon_pageautoclickertxt_6 := MyGui.AddText("x545 y92 w50", "Min")
eMins := MyGui.AddEdit("x580 y90 w40 Center c000000", "0")
anon_pageautoclickertxt_7 := MyGui.AddText("x453 y120 w50", "Sec")
eSecs := MyGui.AddEdit("x498 y118 w40 Center c000000", "0")
anon_pageautoclickertxt_8 := MyGui.AddText("x545 y120 w50", "Ms")
eMs := MyGui.AddEdit("x580 y118 w40 Center c000000", "50")

anon_pageautoclickertxt_9 := MyGui.AddText("x453 y155 w280 c" accent, "CLICK OPTIONS")
anon_pageautoclickertxt_9.SetFont("s9 bold")
anon_pageautoclickertxt_10 := MyGui.AddText("x453 y177 w60", "Button")
ddButton := MyGui.AddDropDownList("x508 y175 w80 c000000", ["Left", "Right", "Middle"])
ddButton.Choose(1)
anon_pageautoclickertxt_11 := MyGui.AddText("x596 y177 w40", "Type")
ddType := MyGui.AddDropDownList("x638 y175 w95 c000000", ["Single", "Double"])
ddType.Choose(1)

anon_pageautoclickertxt_12 := MyGui.AddText("x453 y207 w60", "Repeat")
ddRepeat := MyGui.AddDropDownList("x508 y205 w110 c000000", ["Until Stopped", "Fixed Count"])
ddRepeat.Choose(1)
eCount := MyGui.AddEdit("x623 y207 w45 Center c000000", "10")
eCount.Enabled := false

MyGui.SetFont("s12 bold c" red, "Bahnschrift")
txtStatus := MyGui.AddText("x453 y248 w280 h22 Center", "STOPPED")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

MyGui.SetFont("s10 bold c" fg, "Bahnschrift")
btnStart := MakeStyledButton(MyGui, 453, 276, 135, 34, "Start (F6)", (*) => StartClicking(), "E0568C", "9C2C5D")
btnStop := MakeStyledButton(MyGui, 598, 276, 135, 34, "Stop (F6)", (*) => StopClicking(), "FF4F7B", "A62E50")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

txtHint := MyGui.AddText("x453 y318 w280 c" sub, "Window Focus won't reach a background tab.")
anon_pageautoclickertxt_13 := MyGui.AddText("x453 y334 w280 c" sub, "Key Press sends to whatever window has focus.")

; -- High Speed Mode --
chkHighSpeed := MyGui.AddCheckbox("x453 y358 w150 c" fg, "High Speed Mode")
anon_hs_label := MyGui.AddText("x612 y360 w62 c" fg, "Target CPS")
eHsCps := MyGui.AddEdit("x676 y356 w56 Center c000000", "200")
anon_hs_hint := MyGui.AddText("x453 y384 w280 h48 c" sub, "Breaks the ~64 CPS timer limit by sending clicks in batches. Uses Target CPS (max 10000) instead of the interval fields.")


pageAutoClicker := [anon_pageautoclickertxt_1,ddMode,grpNormal,txtNormalHint1,txtNormalHint2,txtNormalHint3,grpTarget,txtWinLabel,ddWinList,btnRefresh,btnUseSelected,btnPickSpot,txtTarget,txtCoords,grpKey,txtKeyLabel,ddKeyPress,txtKeyHint1,txtKeyHint2,txtKeyHint3,btnTest,anon_pageautoclickertxt_2,anon_pageautoclickertxt_3,ddHotkey,chkFailsafe,anon_pageautoclickertxt_4,anon_pageautoclickertxt_5,eHours,anon_pageautoclickertxt_6,eMins,anon_pageautoclickertxt_7,eSecs,anon_pageautoclickertxt_8,eMs,anon_pageautoclickertxt_9,anon_pageautoclickertxt_10,ddButton,anon_pageautoclickertxt_11,ddType,anon_pageautoclickertxt_12,ddRepeat,eCount,txtStatus,btnStart,btnStop,txtHint,anon_pageautoclickertxt_13]
pageAutoClicker.Push(chkHighSpeed, anon_hs_label, eHsCps, anon_hs_hint)
; ============================================================
; TAB 2 — SESSION STATISTICS (compact grid)
; ============================================================

grpSession := MyGui.AddGroupBox("x145 y66 w190 h100 c" accent, "SESSION CLICKS")
MyGui.SetFont("s26 bold c" fg, "Bahnschrift")
txtSessionClicks := MyGui.AddText("x157 y88 w170 h40", "0")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_sessionclicks_label := MyGui.AddText("x157 y142 w170", "clicks this session")
grpLive := MyGui.AddGroupBox("x343 y66 w120 h100 c" fg, "LIVE CPS")
MyGui.SetFont("s20 bold c" accent, "Bahnschrift")
txtLiveCps := MyGui.AddText("x353 y90 w100 h34", "0.0")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_livecps_label := MyGui.AddText("x353 y142 w100", "per sec")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

grpPeakEver := MyGui.AddGroupBox("x471 y66 w278 h100 c" fg, "LIFETIME PEAK CPS")
MyGui.SetFont("s20 bold c" fg, "Bahnschrift")
txtPeakEver := MyGui.AddText("x483 y90 w260 h34", "0.0 CPS")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

; Returns [groupbox, textControl] so callers can hide both together.
MakeStatCard(x, y, w, h, label) {
    global MyGui, fg
    grp := MyGui.AddGroupBox("x" x " y" y " w" w " h" h " c" fg, label)
    MyGui.SetFont("s15 bold c" fg, "Bahnschrift")
    t := MyGui.AddText("x" (x+12) " y" (y+22) " w" (w-24) " h" (h-30), "-")
    MyGui.SetFont("s9 c" fg, "Bahnschrift")
    return [grp, t]
}

avgCard := MakeStatCard(202, 176, 190, 64, "AVG CPS")
peakCard := MakeStatCard(400, 176, 120, 64, "PEAK CPS")
durationCard := MakeStatCard(528, 176, 278, 64, "SESSION TIME")
lifeClicksCard := MakeStatCard(202, 250, 190, 64, "LIFETIME CLICKS")
totalSessionsCard := MakeStatCard(400, 250, 120, 64, "SESSIONS")
longestSessionCard := MakeStatCard(528, 250, 278, 64, "LONGEST SESSION")
txtAvgCps := avgCard[2], txtPeakCps := peakCard[2], txtDuration := durationCard[2]
txtLifeClicks := lifeClicksCard[2], txtTotalSessions := totalSessionsCard[2], txtLongestSession := longestSessionCard[2]

btnResetSession := MakeStyledButton(MyGui, 145, 326, 190, 30, "Reset Session", (*) => ResetSession(), "A43B68", "6F2147")
btnResetLifetime := MakeStyledButton(MyGui, 343, 326, 248, 30, "Reset Lifetime Stats", (*) => ResetLifetime(), "C34778", "86254F")
btnCopyStats := MakeStyledButton(MyGui, 599, 326, 150, 30, "Copy Stats", (*) => CopyStats(), "E0568C", "8C2F57")

pageSessionStats := [grpSession, txtSessionClicks, anon_sessionclicks_label, grpLive, txtLiveCps, anon_livecps_label
    , grpPeakEver, txtPeakEver, avgCard[1], avgCard[2], peakCard[1], peakCard[2], durationCard[1], durationCard[2]
    , lifeClicksCard[1], lifeClicksCard[2], totalSessionsCard[1], totalSessionsCard[2], longestSessionCard[1], longestSessionCard[2]
    , btnResetSession, btnResetLifetime, btnCopyStats]

; ============================================================
; TAB 3 — CPS TEST (compact)
; ============================================================

anon_pagecpstesttxt_1 := MyGui.AddText("x145 y66 w580 c" sub, "Click the box as fast as you can. This tests your raw clicking speed - it never fires the autoclicker.")

anon_pagecpstesttxt_2 := MyGui.AddText("x145 y92 w60", "Duration")
ddCpsDuration := MyGui.AddDropDownList("x208 y90 w110 c000000", ["5 seconds", "10 seconds", "15 seconds", "30 seconds"])
ddCpsDuration.Choose(1)

MyGui.SetFont("s15 bold c" fg, "Bahnschrift")
btnCpsBox := MakeStyledButton(MyGui, 145, 122, 580, 150, "Click here to start", (*) => CpsTestClick(), "7D1F46", "421125")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

MyGui.SetFont("s11 bold c" fg, "Bahnschrift")
txtCpsTimer := MyGui.AddText("x145 y282 w280 h22", "Time left: -")
txtCpsCount := MyGui.AddText("x445 y282 w280 h22", "Clicks: 0")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

grpCpsResult := MyGui.AddGroupBox("x145 y312 w580 h70 c" accent, "RESULT")
MyGui.SetFont("s14 bold c" fg, "Bahnschrift")
txtCpsResult := MyGui.AddText("x157 y336 w560 h32", "Run a test to see your CPS.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")


pageCpsTest := [anon_pagecpstesttxt_1,anon_pagecpstesttxt_2,ddCpsDuration,btnCpsBox,txtCpsTimer,txtCpsCount,grpCpsResult,txtCpsResult]
; ============================================================
; TAB 4 — RECORDER  (compact toolbar-style macro UI)
; ============================================================
; Compact toolbar layout inspired by the supplied reference image.
; Recorder settings are kept on the main Macro page — there is no
; separate Preferences window anymore. Saving creates a named profile.
MyGui.SetFont("s9 c" fg, "Bahnschrift")

macroStatusText := MyGui.AddText("x145 y66 w430 h18 c" sub, "Idle — ready")
macroSpeedText := MyGui.AddText("x665 y66 w60 h18 Right c" sub, "100%")

ddMacroRecording := MyGui.AddDropDownList("x145 y88 w330 h24 c000000", ["New recording"])
ddMacroRecording.Choose(1)

btnMacroImport := MakeStyledButton(MyGui, 483, 88, 76, 24, "Import", (*) => DoLoadRecording(), "7D1F46", "52132F")
btnMacroExport := MakeStyledButton(MyGui, 563, 88, 76, 24, "Export", (*) => DoExportRecording(), "A43B68", "6F2147")
btnMacroDelete := MakeStyledButton(MyGui, 643, 88, 76, 24, "Del", (*) => ClearRecording(), "FF4F7B", "A62E50")

btnMacroSave := MakeStyledButton(MyGui, 145, 122, 76, 34, "Save", (*) => SaveRecordingCurrent(), "A43B68", "6F2147")
btnMacroRecord := MakeStyledButton(MyGui, 225, 122, 76, 34, "● Rec", (*) => ToggleRecording(), "E0568C", "8C2F57")
btnMacroPlay := MakeStyledButton(MyGui, 305, 122, 76, 34, "▶ Play", (*) => StartPlayback(), "C34778", "81254F")
btnMacroPause := MakeStyledButton(MyGui, 385, 122, 76, 34, "Ⅱ Pause", (*) => TogglePlaybackPause(), "D66A9C", "8E3C64")
btnMacroStop := MakeStyledButton(MyGui, 465, 122, 76, 34, "■ Stop", (*) => StopMacroActivity(), "C34778", "81254F")

; Main-page recorder settings. Kept compact and isolated from the status row
; so no labels/controls overlap when the GUI repaints or is resized.
chkRecordMoves := MyGui.AddCheckbox("x550 y122 w175 c" fg, "Record mouse movement")
chkRecordMoves.Value := 1
MyGui.SetFont("s8 c" sub, "Bahnschrift")
txtSpeedLabel := MyGui.AddText("x550 y151 w38 h18", "Speed")
eSpeed := MyGui.AddEdit("x592 y149 w48 h22 Center c000000", "100")
txtSpeedPct := MyGui.AddText("x644 y151 w18 h18", "%")
txtRepeatLabel := MyGui.AddText("x550 y181 w38 h18", "Repeat")
ddPlayRepeat := MyGui.AddDropDownList("x592 y178 w133 h22 c000000", ["Play Once", "Repeat 3x", "Repeat 5x", "Repeat 10x", "Loop Until Stopped"])
ddPlayRepeat.Choose(1)
MyGui.SetFont("s9 c" fg, "Bahnschrift")

txtRecCount := MyGui.AddText("x145 y166 w270 c" sub, "Events: 0")
txtRecDuration := MyGui.AddText("x420 y166 w120 Right c" sub, "Duration: 00:00:00")
txtRecFile := MyGui.AddText("x145 y208 w574 c" sub, "No recording yet.")

; Playback keybind - record a combo in the box, then click Save to bind it.
; (Same explicit-save pattern as the Typing Test keybind, since relying on
; the box's live Change event alone wasn't reliable.) It's also written to
; the data ini so it's remembered the next time the app is opened.
MyGui.SetFont("s8 c" sub, "Bahnschrift")
txtPlaybackKeyLabel := MyGui.AddText("x145 y238 w110 h24", "Playback keybind")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
ddPlaybackHotkey := MyGui.AddHotkey("x255 y236 w80 c000000", playbackToggleKey)
btnPlaybackSaveKey := MakeStyledButton(MyGui, 343, 234, 110, 26, "Save Keybind", (*) => UpdatePlaybackHotkey(), "C34778", "81254F")
txtPlaybackKeyStatus := MyGui.AddText("x459 y238 w260 h24 c" sub, "Toggle key: " playbackToggleKey)

pageMacro := [macroStatusText,macroSpeedText,ddMacroRecording,btnMacroImport,btnMacroExport,btnMacroDelete
    ,btnMacroSave,btnMacroRecord,btnMacroPlay,btnMacroPause,btnMacroStop
    ,chkRecordMoves,txtSpeedLabel,eSpeed,txtSpeedPct,txtRepeatLabel,ddPlayRepeat
    ,txtRecCount,txtRecDuration,txtRecFile
    ,txtPlaybackKeyLabel,ddPlaybackHotkey,btnPlaybackSaveKey,txtPlaybackKeyStatus]
; ============================================================
; TAB 5 — PROFILES  (save/load named setups + recordings)
; ============================================================

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
anon_pagemacroprofilestxt_1 := MyGui.AddText("x145 y66 w580", "PROFILE MANAGER")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_pagemacroprofilestxt_2 := MyGui.AddText("x145 y86 w580 h38", "Save your current mode, interval, hotkey, target window and recording as a named profile so you can jump between games/tasks instantly.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

anon_pagemacroprofilestxt_3 := MyGui.AddText("x145 y128 w80", "Profile")
ddProfiles := MyGui.AddDropDownList("x213 y126 w300 c000000", ["(no profiles saved)"])
btnRefreshProfiles := MakeStyledButton(MyGui, 521, 125, 40, 22, "⟳", (*) => RefreshProfileList(), "A43B68", "6F2147")

btnSaveProfile := MakeStyledButton(MyGui, 145, 162, 180, 30, "Save Current As...", (*) => DoSaveProfile(), "A43B68", "6F2147")
btnLoadProfile := MakeStyledButton(MyGui, 331, 162, 180, 30, "Load Selected", (*) => DoLoadProfile(), "C34778", "81254F")
btnDeleteProfile := MakeStyledButton(MyGui, 517, 162, 130, 30, "Delete Selected", (*) => DoDeleteProfile(), "FF4F7B", "A62E50")

txtProfileStatus := MyGui.AddText("x145 y204 w580 c" sub, "No profile loaded.")

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
anon_pagemacroprofilestxt_4 := MyGui.AddText("x145 y240 w580", "WHAT GETS SAVED")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
anon_pagemacroprofilestxt_5 := MyGui.AddText("x145 y260 w580 h70", "Mode, interval, button/click type, repeat count, hotkey, failsafe, key-to-press, target window title, and the full recorder macro (mouse moves, clicks, keystrokes) currently in the Recorder tab.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")



pageMacroProfiles := [anon_pagemacroprofilestxt_1,anon_pagemacroprofilestxt_2,anon_pagemacroprofilestxt_3,ddProfiles,btnRefreshProfiles,btnSaveProfile,btnLoadProfile,btnDeleteProfile,txtProfileStatus,anon_pagemacroprofilestxt_4,anon_pagemacroprofilestxt_5]
; ============================================================
; TAB 6 — ACTIONS  (build a step-by-step sequence: clicks, image search, delays, ...)
; ============================================================
; Design-size coordinates like every other page; ScaleUI() shrinks the whole window later.
actSteps   := []
actRunning := false
actRunKey  := ""
actLastImageFound := false
actFile    := A_ScriptDir "\AutoClicker_actions.txt"

ACT_TYPES := ["Click", "Move Mouse", "Drag Mouse", "Scroll", "Key Press", "Hold Key", "Type Text"
    , "Delay", "Random Delay", "Find Image", "Wait For Image", "Activate Window", "Run / Open"]
ACT_BTNS := ["Left", "Right", "Middle"]

; Per action: hint text + which input slots (a-d = text boxes, o1/o2 = dropdowns) it uses, as [label, default]
ActSpecs := Map()
ActSpecs["Click"] := Map("hint", "Clicks at a screen position. Leave X and Y empty to click wherever the cursor is."
    , "a", ["X", ""], "b", ["Y", ""], "c", ["Click count", "1"], "o1", ["Button", ACT_BTNS])
ActSpecs["Move Mouse"] := Map("hint", "Moves the cursor to a screen position."
    , "a", ["X", "0"], "b", ["Y", "0"])
ActSpecs["Drag Mouse"] := Map("hint", "Holds the button at the start point, drags to the end point and lets go."
    , "a", ["From X", "0"], "b", ["From Y", "0"], "c", ["To X", "0"], "d", ["To Y", "0"], "o1", ["Button", ACT_BTNS])
ActSpecs["Scroll"] := Map("hint", "Turns the mouse wheel. Positive scrolls up, negative scrolls down."
    , "a", ["Notches", "-3"])
ActSpecs["Key Press"] := Map("hint", "Presses a key (Enter, Tab, F5, a ...) or a combo like ^c  (^ Ctrl, + Shift, ! Alt, # Win)."
    , "a", ["Key", "Enter"])
ActSpecs["Hold Key"] := Map("hint", "Holds a key down for a set time, then releases it."
    , "a", ["Key", "w"], "b", ["Hold for (ms)", "500"])
ActSpecs["Type Text"] := Map("hint", "Types the text exactly as written."
    , "a", ["Text", ""])
ActSpecs["Delay"] := Map("hint", "Pauses the sequence for a set time."
    , "a", ["Delay (ms)", "1000"])
ActSpecs["Random Delay"] := Map("hint", "Pauses for a random time between the two values."
    , "a", ["Min (ms)", "500"], "b", ["Max (ms)", "1500"])
ActSpecs["Find Image"] := Map("hint", "Looks for a picture on screen (use a cropped screenshot: PNG, BMP or JPG)."
    , "a", ["Image file", ""], "b", ["Tolerance (0-255)", "30"], "c", ["Search up to (ms)", "0"]
    , "o1", ["When found", ["Click it", "Move mouse to it", "Just continue"]]
    , "o2", ["If not found", ["Continue", "Stop the sequence"]])
ActSpecs["Wait For Image"] := Map("hint", "Waits until the picture appears on screen, then carries on."
    , "a", ["Image file", ""], "b", ["Tolerance (0-255)", "30"], "c", ["Give up after (ms)", "10000"]
    , "o1", ["If it never shows", ["Continue", "Stop the sequence"]])
ActSpecs["Activate Window"] := Map("hint", "Brings a window to the front. Part of its title is enough."
    , "a", ["Window title", ""])
ActSpecs["Run / Open"] := Map("hint", "Opens a program, file or web address."
    , "a", ["Path or URL", ""])

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
actHdr1 := MyGui.AddText("x145 y66 w285", "ADD ACTION")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
ddActType := MyGui.AddDropDownList("x145 y86 w285 c000000", ACT_TYPES)
ddActType.Choose(1)
MyGui.SetFont("s9 c" sub, "Bahnschrift")
txtActHint := MyGui.AddText("x145 y114 w285 h32", "")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

actLblA := MyGui.AddText("x145 y152 w100 h18", "")
actEdA  := MyGui.AddEdit("x248 y148 w134 c000000", "")
btnActBrowse := MakeStyledButton(MyGui, 386, 148, 44, 21, "...", (*) => ActBrowseImage(), "A43B68", "6F2147")
actLblB := MyGui.AddText("x145 y178 w100 h18", "")
actEdB  := MyGui.AddEdit("x248 y174 w182 c000000", "")
actLblC := MyGui.AddText("x145 y204 w100 h18", "")
actEdC  := MyGui.AddEdit("x248 y200 w182 c000000", "")
actLblD := MyGui.AddText("x145 y230 w100 h18", "")
actEdD  := MyGui.AddEdit("x248 y226 w182 c000000", "")
actLblO1 := MyGui.AddText("x145 y256 w100 h18", "")
ddActO1 := MyGui.AddDropDownList("x248 y252 w182 c000000", ACT_BTNS)
actLblO2 := MyGui.AddText("x145 y282 w100 h18", "")
ddActO2 := MyGui.AddDropDownList("x248 y278 w182 c000000", ACT_BTNS)

btnActAdd     := MakeStyledButton(MyGui, 145, 312, 139, 26, "Add Action", (*) => ActAdd(), "C34778", "81254F")
btnActReplace := MakeStyledButton(MyGui, 291, 312, 139, 26, "Replace Selected", (*) => ActReplace(), "A43B68", "6F2147")
btnActTest    := MakeStyledButton(MyGui, 145, 344, 285, 24, "Test This Action (runs in 2 seconds)", (*) => ActTest(), "7D1F46", "52132F")

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
actHdr2 := MyGui.AddText("x445 y66 w280", "SEQUENCE  (double-click a row to edit it)")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
lvActs := MyGui.AddListView("x445 y86 w280 h250 -Multi Grid c000000", ["#", "Action", "Details"])
lvActs.ModifyCol(1, 28)
lvActs.ModifyCol(2, 92)
lvActs.ModifyCol(3, 136)
btnActUp     := MakeStyledButton(MyGui, 445, 342, 66, 24, "▲ Up", (*) => ActMove(-1), "A43B68", "6F2147")
btnActDown   := MakeStyledButton(MyGui, 517, 342, 66, 24, "▼ Down", (*) => ActMove(1), "A43B68", "6F2147")
btnActRemove := MakeStyledButton(MyGui, 589, 342, 66, 24, "Remove", (*) => ActRemove(), "FF4F7B", "A62E50")
btnActClear  := MakeStyledButton(MyGui, 661, 342, 64, 24, "Clear", (*) => ActClear(), "FF4F7B", "A62E50")
btnActSave   := MakeStyledButton(MyGui, 445, 372, 137, 24, "Save List...", (*) => ActSaveAs(), "A43B68", "6F2147")
btnActLoad   := MakeStyledButton(MyGui, 588, 372, 137, 24, "Load List...", (*) => ActLoadFrom(), "A43B68", "6F2147")

MyGui.SetFont("s9 bold c" accent, "Bahnschrift")
actHdr3 := MyGui.AddText("x145 y408 w285", "RUN")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
actLblRep := MyGui.AddText("x145 y434 w55", "Repeat")
ddActRepeat := MyGui.AddDropDownList("x203 y430 w140 c000000", ["Run once", "Repeat 3x", "Repeat 5x", "Repeat 10x", "Loop until stopped"])
ddActRepeat.Choose(1)
actLblStart := MyGui.AddText("x362 y434 w95", "Start after (s)")
eActStart := MyGui.AddEdit("x460 y430 w50 Center c000000", "0")
actLblGap := MyGui.AddText("x145 y464 w185", "Pause between actions (ms)")
eActGap := MyGui.AddEdit("x333 y460 w50 Center c000000", "100")
actLblKey := MyGui.AddText("x400 y464 w55", "Run key")
hkActRun := MyGui.AddHotkey("x458 y460 w70 c000000", "F7")
btnActRun  := MakeStyledButton(MyGui, 145, 494, 200, 30, "Run Sequence", (*) => ActToggle(), "E0568C", "8C2F57")
btnActStop := MakeStyledButton(MyGui, 351, 494, 110, 30, "Stop", (*) => ActStop("Stopped."), "FF4F7B", "A62E50")
MyGui.SetFont("s9 c" sub, "Bahnschrift")
txtActStatus := MyGui.AddText("x470 y500 w255 h20", "Idle")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

pageActions := [actHdr1, ddActType, txtActHint, actLblA, actEdA, btnActBrowse, actLblB, actEdB, actLblC, actEdC
    , actLblD, actEdD, actLblO1, ddActO1, actLblO2, ddActO2, btnActAdd, btnActReplace, btnActTest
    , actHdr2, lvActs, btnActUp, btnActDown, btnActRemove, btnActClear, btnActSave, btnActLoad
    , actHdr3, actLblRep, ddActRepeat, actLblStart, eActStart, actLblGap, eActGap, actLblKey, hkActRun
    , btnActRun, btnActStop, txtActStatus]

ddActType.OnEvent("Change", (*) => ActApplyFields(true))
lvActs.OnEvent("DoubleClick", (*) => ActLoadRowIntoForm())
hkActRun.OnEvent("Change", (*) => ActBindRunKey())
ActApplyFields(true)

; ---- Crash / exit log: if the macro ever closes by itself, macro_error.txt (next to it) says why ----
OnError(MacroLogError)
MacroLogError(e, mode) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  ERROR: " e.Message "  (" e.What ")  line " e.Line "`n" e.Stack "`n`n", A_ScriptDir "\macro_error.txt")
    return 0
}
OnExit(MacroLogExit)
MacroLogExit(reason, code) {
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  EXIT: " reason " (code " code ")`n", A_ScriptDir "\macro_error.txt")
}
; ---- Flicker-free page switching ----
; Switching tabs shows/hides dozens of controls one at a time; painting between
; those steps is what briefly flashes every button. Pausing the window's
; repainting (WM_SETREDRAW) until the page is fully set up, then repainting once,
; hides all of that. A depth counter keeps nested calls from re-enabling early.
guiRedrawDepth := 0
GuiRedrawOff() {
    global guiRedrawDepth, MyGui
    guiRedrawDepth += 1
    if guiRedrawDepth = 1
        DllCall("SendMessage", "ptr", MyGui.Hwnd, "uint", 0x000B, "ptr", 0, "ptr", 0)
}
GuiRedrawOn() {
    global guiRedrawDepth, MyGui
    guiRedrawDepth -= 1
    if guiRedrawDepth > 0
        return
    guiRedrawDepth := 0
    DllCall("SendMessage", "ptr", MyGui.Hwnd, "uint", 0x000B, "ptr", 1, "ptr", 0)
    ; RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
    DllCall("RedrawWindow", "ptr", MyGui.Hwnd, "ptr", 0, "ptr", 0, "uint", 0x0001 | 0x0004 | 0x0080 | 0x0100)
}
monitorEnabled := (IniRead(dataFile, "Settings", "LiveMonitor", "1") = "1")
recMon := ""


; ============================================================
; PAGE - SETTINGS
; ============================================================
MyGui.SetFont("s12 bold c" accent, "Bahnschrift")
setTitle := MyGui.AddText("x157 y78 w300 h26", "Settings")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
grpSettings := MyGui.AddGroupBox("x145 y112 w600 h100 c" fg, "General")
chkLiveMon := MyGui.AddCheckbox("x165 y140 w300 c" fg, "Show live monitor window")
chkLiveMon.Value := monitorEnabled ? 1 : 0
chkLiveMon.OnEvent("Click", (*) => ToggleLiveMonitor())
MyGui.SetFont("s8 c" sub, "Bahnschrift")
setMonNote := MyGui.AddText("x165 y166 w560 h30", "Pops out a status window (current action, loops completed, timers) while the Recorder is playing on Loop Until Stopped.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")

; ---- Customize: dashboard picture + window background image ----
grpCustom := MyGui.AddGroupBox("x145 y222 w600 h200 c" fg, "Customize")
lblDashPic := MyGui.AddText("x165 y252 w140 c" fg, "Dashboard picture")
dashBtnPic := MakeStyledButton(MyGui, 315, 247, 190, 28, "Set Dashboard Picture...", (*) => ChooseDashboardImage(), "A43B68", "6F2147")
MyGui.SetFont("s8 c" sub, "Bahnschrift")
dashPicHint := MyGui.AddText("x165 y282 w560 h16 c" sub, dashboardImagePath != "" ? dashboardImagePath : "No custom picture set.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
lblBgImg := MyGui.AddText("x165 y320 w140 c" fg, "Background image")
bgBtnChoose := MakeStyledButton(MyGui, 315, 315, 190, 28, "Choose Background...", (*) => BgChoose(), "A43B68", "6F2147")
bgBtnClear := MakeStyledButton(MyGui, 513, 315, 80, 28, "Clear", (*) => BgClear(), "6B2D45", "401A29")
MyGui.SetFont("s8 c" sub, "Bahnschrift")
bgHint := MyGui.AddText("x165 y349 w560 h16 c" sub, bgImagePath != "" ? bgImagePath : "No background image set.")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
lblBgDim := MyGui.AddText("x165 y382 w80 c" fg, "Dimming")
sldBgDim := MyGui.AddSlider("x250 y377 w250 h26 Range0-90 ToolTip Background" bg, bgDim)
txtBgDim := MyGui.AddText("x508 y382 w60 c" fg, bgDim "%")
sldBgDim.OnEvent("Change", (*) => BgDimChanged())

; ---- Updates ----
grpUpdates := MyGui.AddGroupBox("x145 y430 w600 h112 c" fg, "Updates")
MyGui.SetFont("s9 c" fg, "Bahnschrift")
txtUpdStatus := MyGui.AddText("x165 y452 w280 h32 c" fg, "Version v" APP_VERSION)
btnUpdCheck := MakeStyledButton(MyGui, 455, 449, 140, 28, "Check for updates", (*) => UpdCheck(false), "A43B68", "6F2147")
btnUpdNow := MakeStyledButton(MyGui, 603, 449, 120, 28, "Update now", (*) => UpdInstall(), "E0568C", "8C2F57")
lblUpdSrc := MyGui.AddText("x165 y490 w56 c" fg, "Source")
eUpdSrc := MyGui.AddEdit("x225 y487 w498 h22 c000000", updSource)
chkUpdLaunch := MyGui.AddCheckbox("x165 y515 w300 c" fg, "Check for updates when the macro starts")
chkUpdLaunch.Value := updCheckOnLaunch ? 1 : 0
chkUpdLaunch.OnEvent("Click", (*) => UpdSaveSettings())
eUpdSrc.OnEvent("LoseFocus", (*) => UpdSaveSettings())
pageSettings := [setTitle, grpSettings, chkLiveMon, setMonNote, grpCustom, lblDashPic, dashBtnPic, dashPicHint
    , lblBgImg, bgBtnChoose, bgBtnClear, bgHint, lblBgDim, sldBgDim, txtBgDim
    , grpUpdates, txtUpdStatus, btnUpdCheck, btnUpdNow, lblUpdSrc, eUpdSrc, chkUpdLaunch]

ToggleLiveMonitor() {
    global monitorEnabled, chkLiveMon, dataFile
    monitorEnabled := chkLiveMon.Value ? true : false
    try IniWrite(monitorEnabled ? "1" : "0", dataFile, "Settings", "LiveMonitor")
    if !monitorEnabled
        RecMonClose()
}


; ============================================================
; CUSTOM BACKGROUND IMAGE
; ============================================================
; The picture is painted as the window's own background (WM_ERASEBKGND) inside a
; rounded panel over the content area only - the sidebar stays plain. Labels, group
; outlines and checkboxes on the content pages are made transparent so they draw on
; top of the picture; buttons, inputs and lists stay solid.
BG_PANEL_X := Round(140 * UI_SCALE)
BG_PANEL_Y := Round(44 * UI_SCALE)
BG_RADIUS := Round(16 * UI_SCALE)

BgBuild() {
    global MyGui, bgImagePath, bgDim, bgHbm, bgBmpW, bgBmpH, bg, BG_PANEL_X, BG_PANEL_Y, BG_RADIUS
    if bgHbm {
        DllCall("DeleteObject", "Ptr", bgHbm)
        bgHbm := 0
    }
    if bgImagePath = "" || !FileExist(bgImagePath)
        return
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", MyGui.Hwnd, "Ptr", rc)
    W := NumGet(rc, 8, "Int"), H := NumGet(rc, 12, "Int")
    if W < 300 || H < 200
        return
    img := 0
    DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", bgImagePath, "Ptr*", &img)
    if !img
        return
    iw := 0, ih := 0
    DllCall("gdiplus\GdipGetImageWidth", "Ptr", img, "UInt*", &iw)
    DllCall("gdiplus\GdipGetImageHeight", "Ptr", img, "UInt*", &ih)
    bm := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", W, "Int", H, "Int", 0, "Int", 0x26200A, "Ptr", 0, "Ptr*", &bm)
    G := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", bm, "Ptr*", &G)
    DllCall("gdiplus\GdipSetInterpolationMode", "Ptr", G, "Int", 7)
    bgArgb := 0xFF000000 | Integer("0x" bg)
    br := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", bgArgb, "Ptr*", &br)
    DllCall("gdiplus\GdipFillRectangleI", "Ptr", G, "Ptr", br, "Int", 0, "Int", 0, "Int", W, "Int", H)
    px := BG_PANEL_X, py := BG_PANEL_Y, pw := W - BG_PANEL_X - 8, ph := H - BG_PANEL_Y - 8
    if iw > 0 && ih > 0 && pw > 40 && ph > 40 {
        ; "cover": scale to fill the panel, crop the overflow evenly
        sc := Max(pw / iw, ph / ih)
        sw := pw / sc, sh := ph / sc
        sx := (iw - sw) / 2, sy := (ih - sh) / 2
        DllCall("gdiplus\GdipDrawImageRectRect", "Ptr", G, "Ptr", img
            , "Float", px, "Float", py, "Float", pw, "Float", ph
            , "Float", sx, "Float", sy, "Float", sw, "Float", sh
            , "Int", 2, "Ptr", 0, "Ptr", 0, "Ptr", 0)
        ; dimming layer so text stays readable
        a := Round(bgDim / 100 * 255)
        if a > 0 {
            dbr := 0
            DllCall("gdiplus\GdipCreateSolidFill", "UInt", (a << 24), "Ptr*", &dbr)
            DllCall("gdiplus\GdipFillRectangleI", "Ptr", G, "Ptr", dbr, "Int", px, "Int", py, "Int", pw, "Int", ph)
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", dbr)
        }
        ; rounded corners: paint the 4 corner slivers in the window colour (anti-aliased)
        DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", G, "Int", 4)
        path := 0
        DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path)
        DllCall("gdiplus\GdipAddPathRectangleI", "Ptr", path, "Int", px - 1, "Int", py - 1, "Int", pw + 2, "Int", ph + 2)
        DllCall("gdiplus\GdipStartPathFigure", "Ptr", path)
        d := BG_RADIUS * 2
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", px, "Float", py, "Float", d, "Float", d, "Float", 180, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", px + pw - d, "Float", py, "Float", d, "Float", d, "Float", 270, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", px + pw - d, "Float", py + ph - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
        DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", px, "Float", py + ph - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
        DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
        DllCall("gdiplus\GdipFillPath", "Ptr", G, "Ptr", br, "Ptr", path)
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    }
    hbm := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", bm, "Ptr*", &hbm, "UInt", bgArgb)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", br)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", G)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", bm)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", img)
    bgHbm := hbm
    bgBmpW := W
    bgBmpH := H
}

; Bounding box (plus margin) of everything currently visible on the open page, kept inside the content area.
BgPageBounds() {
    global pageBasePos, currentPage, MyGui, BG_PANEL_X, BG_PANEL_Y
    if !pageBasePos.Has(currentPage)
        return []
    x1 := 99999, y1 := 99999, x2 := -1, y2 := -1
    for it in pageBasePos[currentPage] {
        try {
            c := it[1]
            if !c.Visible
                continue
            c.GetPos(&x, &y, &w, &h)
            x1 := Min(x1, x), y1 := Min(y1, y), x2 := Max(x2, x + w), y2 := Max(y2, y + h)
        }
    }
    if x2 < 0
        return []
    crc := Buffer(16, 0)
    DllCall("GetClientRect", "Ptr", MyGui.Hwnd, "Ptr", crc)
    cw := NumGet(crc, 8, "Int"), ch := NumGet(crc, 12, "Int")
    return [Max(BG_PANEL_X + 2, x1 - 12), Max(BG_PANEL_Y + 2, y1 - 10), Min(cw - 10, x2 + 12), Min(ch - 10, y2 + 10)]
}

BgAddRoundRect(path, x, y, w, h, r) {
    d := r * 2
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y, "Float", d, "Float", d, "Float", 180, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y, "Float", d, "Float", d, "Float", 270, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x + w - d, "Float", y + h - d, "Float", d, "Float", d, "Float", 0, "Float", 90)
    DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", x, "Float", y + h - d, "Float", d, "Float", d, "Float", 90, "Float", 90)
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", path)
}

; Paints the window background (picture if set) and then draws every visible outlined box
; as a rounded, anti-aliased outline with a solid dark inside. The boxes' own square frames
; are clipped away in BgStyleInit, so only these rounded ones show.
BgErase(wParam, lParam, msg, hwnd) {
    global MyGui, bgHbm, bgBmpW, bgBmpH, bgGroups, bgGroupBrush, bg, fg, pageBasePos, currentPage
    if hwnd != MyGui.Hwnd
        return
    ; a control asking the parent to paint its background hands over its own DC - leave those alone
    if DllCall("WindowFromDC", "Ptr", wParam, "Ptr") != MyGui.Hwnd
        return
    if !bgGroupBrush {
        c := Integer("0x" bg)   ; RGB -> BGR for GDI
        bgGroupBrush := DllCall("CreateSolidBrush", "UInt", ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF), "Ptr")
    }
    if bgHbm {
        mdc := DllCall("CreateCompatibleDC", "Ptr", wParam, "Ptr")
        old := DllCall("SelectObject", "Ptr", mdc, "Ptr", bgHbm, "Ptr")
        DllCall("BitBlt", "Ptr", wParam, "Int", 0, "Int", 0, "Int", bgBmpW, "Int", bgBmpH, "Ptr", mdc, "Int", 0, "Int", 0, "UInt", 0x00CC0020)
        DllCall("SelectObject", "Ptr", mdc, "Ptr", old)
        DllCall("DeleteDC", "Ptr", mdc)
    } else {
        crc := Buffer(16, 0)
        DllCall("GetClientRect", "Ptr", hwnd, "Ptr", crc)
        DllCall("FillRect", "Ptr", wParam, "Ptr", crc, "Ptr", bgGroupBrush)
    }
    if bgGroups.Length = 0 && !bgHbm
        return 1
    G := 0
    DllCall("gdiplus\GdipCreateFromHDC", "Ptr", wParam, "Ptr*", &G)
    if !G
        return 1
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", G, "Int", 4)
    fillBr := 0, pen := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFF000000 | Integer("0x" bg), "Ptr*", &fillBr)
    ; with a picture set: one solid dark rounded panel behind everything on the current page,
    ; so the gaps between labels/buttons fill in and the page reads as one big block
    if bgHbm {
        pr := BgPageBounds()
        if pr.Length = 4 {
            ppath := 0
            DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &ppath)
            BgAddRoundRect(ppath, pr[1], pr[2], pr[3] - pr[1], pr[4] - pr[2], 16)
            DllCall("gdiplus\GdipFillPath", "Ptr", G, "Ptr", fillBr, "Ptr", ppath)
            DllCall("gdiplus\GdipDeletePath", "Ptr", ppath)
        }
    }
    DllCall("gdiplus\GdipCreatePen1", "UInt", 0xFF000000 | Integer("0x" fg), "Float", 1.5, "Int", 2, "Ptr*", &pen)
    for g in bgGroups {
        try {
            if !g.Visible
                continue
            g.GetPos(&gx, &gy, &gw, &gh)
            path := 0
            DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path)
            BgAddRoundRect(path, gx + 0.75, gy + 8, gw - 1.5, gh - 9, 10)
            DllCall("gdiplus\GdipFillPath", "Ptr", G, "Ptr", fillBr, "Ptr", path)
            DllCall("gdiplus\GdipDrawPath", "Ptr", G, "Ptr", pen, "Ptr", path)
            DllCall("gdiplus\GdipDeletePath", "Ptr", path)
        }
    }
    DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
    DllCall("gdiplus\GdipDeleteBrush", "Ptr", fillBr)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", G)
    return 1
}
OnMessage(0x14, BgErase)

; Content-page labels/outlines/checkboxes (not buttons, rows or inputs) - these get a
; transparent background so the picture shows behind them.
BgCollectTransparent() {
    global pages, pageBasePos, bgTransCtrls, bgPlain, bgGroups, dashTitle, dashCredit, setTitle, navButtons, gdipButtons, BG_PANEL_X, BG_PANEL_Y
    skip := Map()
    for _, b in navButtons
        skip[b.Hwnd] := 1
    for b in gdipButtons
        skip[b["ctrl"].Hwnd] := 1
    bgTransCtrls := []
    bgPlain := []
    bgGroups := []
    ; Only the big page titles (text that never changes) are ever made see-through. Labels that the
    ; macro updates while running (status lines, counters) must stay solid: a see-through label that
    ; keeps getting new text keeps repainting itself on top of the picture and smears into bars.
    keep := Map()
    for c in [dashTitle, dashCredit, setTitle]
        keep[c.Hwnd] := 1
    ; Only labels that sit OUTSIDE every outlined box of their page (titles, hints) are made
    ; transparent. Everything inside a box stays opaque on the box's solid fill, which is what
    ; keeps the page free of ghosting / overlapping paint.
    for key, items in pageBasePos {
        rects := []
        for it in items {
            if it[1].Type = "GroupBox" {
                try {
                    it[1].GetPos(, , &w, &h)
                    rects.Push([it[2], it[3], it[2] + w, it[3] + h])
                    if it[2] >= BG_PANEL_X && it[3] >= BG_PANEL_Y
                        bgGroups.Push(it[1])
                }
            }
        }
        for it in items {
            ctrl := it[1]
            if !(ctrl.Type = "Text" || ctrl.Type = "CheckBox" || ctrl.Type = "Radio")
                continue
            if skip.Has(ctrl.Hwnd)
                continue
            try {
                ctrl.GetPos(, , &w, &h)
                cx := it[2] + w / 2, cy := it[3] + h / 2
                inside := false
                for r in rects {
                    if cx >= r[1] && cx <= r[3] && cy >= r[2] && cy <= r[4] {
                        inside := true
                        break
                    }
                }
                if !inside && it[2] >= BG_PANEL_X && it[3] >= BG_PANEL_Y {
                    if keep.Has(ctrl.Hwnd)
                        bgTransCtrls.Push(ctrl)
                    else
                        bgPlain.Push(ctrl)
                }
            }
        }
    }
}

BgSetTransparent(on) {
    global bgTransCtrls, bgPlain, bgTransOn, bgLastText
    if on = bgTransOn
        return
    bgTransOn := on
    if bgTransCtrls.Length = 0
        BgCollectTransparent()
    for ctrl in bgTransCtrls
        try ctrl.Opt(on ? "+BackgroundTrans" : "-BackgroundTrans")
    bgLastText := Map()
    SetTimer(BgGhostFix, on ? 200 : 0)
}

; A transparent label that changes its text would leave the old text behind, so
; whenever a visible one changes, repaint the picture under it.
BgGhostFix() {
    global bgTransCtrls, bgLastText
    for ctrl in bgTransCtrls {
        try {
            if !ctrl.Visible
                continue
            t := ctrl.Text
            h := ctrl.Hwnd
            if !bgLastText.Has(h) || bgLastText[h] != t {
                if bgLastText.Has(h)
                    ctrl.Redraw()
                bgLastText[h] := t
            }
        }
    }
}

; Clips controls to rounded shapes (loose labels, buttons, sidebar items) and strips the
; square frame off every outlined box (keeping just its title) - BgErase draws the rounded one.
BgRoundCtrl(ctrl, r) {
    global bgRoundOk, bgRoundFail, bgRoundErr
    try {
        ctrl.GetPos(, , &w, &h)
        rgn := DllCall("CreateRoundRectRgn", "Int", 0, "Int", 0, "Int", w + 1, "Int", h + 1, "Int", r, "Int", r, "Ptr")
        ok := DllCall("SetWindowRgn", "Ptr", ctrl.Hwnd, "Ptr", rgn, "Int", 1, "Int")
        if ok
            bgRoundOk += 1
        else
            bgRoundFail += 1
    } catch as err {
        bgRoundFail += 1
        if bgRoundErr = ""
            bgRoundErr := err.Message " @ " err.Line
    }
}

BgClipTitle(g) {
    try {
        g.GetPos(, , &w)
        txt := g.Text
        tw := 0, th := 14
        if txt != "" {
            hdc := DllCall("GetDC", "Ptr", g.Hwnd, "Ptr")
            hf := SendMessage(0x31, 0, 0, g)
            old := DllCall("SelectObject", "Ptr", hdc, "Ptr", hf, "Ptr")
            sz := Buffer(8, 0)
            DllCall("GetTextExtentPoint32W", "Ptr", hdc, "WStr", txt, "Int", StrLen(txt), "Ptr", sz)
            tw := NumGet(sz, 0, "Int"), th := NumGet(sz, 4, "Int")
            DllCall("SelectObject", "Ptr", hdc, "Ptr", old)
            DllCall("ReleaseDC", "Ptr", g.Hwnd, "Ptr", hdc)
        }
        rgn := txt = "" ? DllCall("CreateRectRgn", "Int", 0, "Int", 0, "Int", 1, "Int", 1, "Ptr")
            : DllCall("CreateRectRgn", "Int", 5, "Int", 0, "Int", Min(w, 9 + tw + 6), "Int", th + 2, "Ptr")
        DllCall("SetWindowRgn", "Ptr", g.Hwnd, "Ptr", rgn, "Int", 1)
    }
}

BgStyleInit() {
    global bgPlain, bgGroups, MyGui, bgRoundOk, bgRoundFail, bgRoundErr, APP_VERSION
    ; WS_CLIPCHILDREN: the window background is never painted on top of the controls, which is
    ; what caused the black flashes on click and the occasional blank page (panel only).
    MyGui.Opt("+0x2000000")
    BgCollectTransparent()
    for g in bgGroups
        BgClipTitle(g)
    try FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") "  STYLE v" APP_VERSION ": groups=" bgGroups.Length "`n", A_ScriptDir "\macro_error.txt")
}

BgRefresh() {
    global MyGui, bgImagePath
    BgBuild()
    DllCall("RedrawWindow", "Ptr", MyGui.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0001 | 0x0004 | 0x0080 | 0x0100)
}

BgChoose() {
    global bgImagePath, bgHint, dataFile
    chosen := FileSelect(1, , "Choose a background image", "Images (*.png; *.jpg; *.jpeg; *.gif; *.bmp)")
    if chosen = ""
        return
    bgImagePath := chosen
    bgHint.Text := chosen
    try IniWrite(chosen, dataFile, "Background", "ImagePath")
    BgRefresh()
}

BgClear() {
    global bgImagePath, bgHint, dataFile
    bgImagePath := ""
    bgHint.Text := "No background image set."
    try IniWrite("", dataFile, "Background", "ImagePath")
    BgRefresh()
}

BgDimChanged() {
    global bgDim, sldBgDim, txtBgDim, dataFile
    bgDim := sldBgDim.Value
    txtBgDim.Text := bgDim "%"
    try IniWrite(bgDim, dataFile, "Background", "Dim")
    SetTimer(BgRefresh, -180)
}

BgOnSize(gui, minMax, w, h) {
    if minMax = -1
        return
    SetTimer(BgRefresh, -200)
}
MyGui.OnEvent("Size", BgOnSize)

; ============================================================
; AUTO UPDATE (reads version.txt + the macro file from the GitHub "raw" folder in Settings > Updates)
; ============================================================
UpdHttpGet(url) {
    req := ComObject("WinHttp.WinHttpRequest.5.1")
    req.Open("GET", url, false)
    req.SetRequestHeader("User-Agent", "MacroAIO-Updater")
    req.SetRequestHeader("Cache-Control", "no-cache")
    req.Send()
    if req.Status != 200
        throw Error("server answered " req.Status)
    return req.ResponseText
}

; true when version a is newer than b ("3.14" vs "3.9": parts compared as numbers)
UpdIsNewer(a, b) {
    pa := StrSplit(a, "."), pb := StrSplit(b, ".")
    loop Max(pa.Length, pb.Length) {
        x := A_Index <= pa.Length ? Integer(pa[A_Index]) : 0
        y := A_Index <= pb.Length ? Integer(pb[A_Index]) : 0
        if x != y
            return x > y
    }
    return false
}

UpdBase() {
    global eUpdSrc
    b := Trim(eUpdSrc.Text)
    if b != "" && SubStr(b, -1) != "/"
        b .= "/"
    return b
}

UpdSaveSettings() {
    global chkUpdLaunch, eUpdSrc, dataFile
    try IniWrite(chkUpdLaunch.Value ? "1" : "0", dataFile, "Updates", "CheckOnLaunch")
    try IniWrite(Trim(eUpdSrc.Text), dataFile, "Updates", "Source")
}

UpdCheck(silent := false) {
    global APP_VERSION, updLatest, updFilePath, txtUpdStatus
    if !silent
        txtUpdStatus.Text := "Checking..."
    try {
        txt := UpdHttpGet(UpdBase() "version.txt?t=" A_TickCount)
        lines := StrSplit(Trim(txt, " `t`r`n"), "`n", "`r")
        v := Trim(lines[1])
        updFilePath := (A_IsCompiled ? (lines.Length >= 3 ? Trim(lines[3]) : "") : (lines.Length >= 2 ? Trim(lines[2]) : ""))
        if !RegExMatch(v, "^\d+(\.\d+)*$")
            throw Error("version.txt doesn't contain a version number")
    } catch as err {
        if !silent
            txtUpdStatus.Text := "Couldn't check: " err.Message
        return
    }
    if UpdIsNewer(v, APP_VERSION) {
        updLatest := v
        txtUpdStatus.Text := "Update available: v" v " (you have v" APP_VERSION ") - click Update now."
        if silent
            ToolTip("Macro AIO update v" v " is available - Settings > Updates")
        if silent
            SetTimer(() => ToolTip(), -4000)
    } else {
        updLatest := ""
        txtUpdStatus.Text := "Up to date (v" APP_VERSION ")."
    }
}

UpdCheckSilent() {
    UpdCheck(true)
}

UpdInstall() {
    global updLatest, updFilePath, txtUpdStatus, MyGui
    if updLatest = "" {
        txtUpdStatus.Text := "No update found yet - click Check for updates first."
        return
    }
    isExe := A_IsCompiled ? true : false
    file := isExe ? "Autoclicker-Main.exe" : "Autoclicker-Main.ahk"
    dest := A_ScriptFullPath ".new"
    txtUpdStatus.Text := "Downloading v" updLatest "..."
    try {
        FileDelete(dest)
    }
    try {
        ; where the file may live in the repository: the path from version.txt (if any), the top level,
        ; then the folder layout of the repo as it was first uploaded
        cands := []
        if updFilePath != ""
            cands.Push(updFilePath)
        cands.Push(file)
        got := false, lastErr := ""
        for cand in cands {
            try {
                Download(UpdBase() StrReplace(cand, " ", "%20") "?t=" A_TickCount, dest)
                if FileExist(dest) && FileGetSize(dest) >= 20000 {
                    got := true
                    break
                }
            } catch as e2 {
                lastErr := e2.Message
            }
        }
        if !got
            throw Error(file " wasn't found in the repository (tried " cands.Length " locations)")
        sz := FileGetSize(dest)
        if sz < 20000
            throw Error("downloaded file is too small (" sz " bytes) - is " file " in the repository?")
        if !isExe && !InStr(FileRead(dest, "UTF-8 m400"), "AutoHotkey")
            throw Error("downloaded file doesn't look like the macro script")
    } catch as err {
        try FileDelete(dest)
        txtUpdStatus.Text := "Update failed: " err.Message
        return
    }
    bat := A_Temp "\macro_aio_update.bat"
    cur := A_ScriptFullPath
    try FileDelete(bat)
    FileAppend("@echo off`r`n"
        . "set n=0`r`n"
        . ":retry`r`n"
        . "ping 127.0.0.1 -n 2 >nul`r`n"
        . 'move /y "' dest '" "' cur '" >nul 2>&1`r`n'
        . "if errorlevel 1 (`r`n"
        . "  set /a n+=1`r`n"
        . "  if %n% lss 15 goto retry`r`n"
        . "  exit /b 1`r`n"
        . ")`r`n"
        . 'start "" "' cur '"`r`n'
        . 'del "%~f0"`r`n', bat)
    txtUpdStatus.Text := "Installing v" updLatest " - restarting..."
    try SaveLifetimeData()
    Run(A_ComSpec ' /c "' bat '"', , "Hide")
    ExitApp()
}

; ============================================================
; PAGE SWITCHING
; ============================================================
; ---- Compact window: every control (and its text) is shrunk once, here, after the whole UI has been
; built and before the scroll positions below are captured. See UI_SCALE / UI_FONT_SCALE at the top. ----
ScaleUI(gs, fs) {
    global MyGui, gdipButtons
    fonts := Map()
    minPx := Round(7 * A_ScreenDPI / 72)
    for hwnd, ctrl in MyGui {
        try {
            ctrl.GetPos(&x, &y, &w, &h)
            nx := Round(x * gs), ny := Round(y * gs), nw := Round(w * gs)
            t := ctrl.Type
            if (t = "DDL" || t = "ComboBox")
                ctrl.Move(nx, ny, nw)
            else if (t = "Edit" || t = "Hotkey")
                ctrl.Move(nx, ny, nw, Round(h * fs))
            else
                ctrl.Move(nx, ny, nw, Round(h * gs))
            if t = "ListView" {
                loop ctrl.GetCount("Col") {
                    cw := SendMessage(0x101D, A_Index - 1, 0, ctrl)
                    SendMessage(0x101E, A_Index - 1, Round(cw * gs), ctrl)
                }
            }
        }
        try {
            hf := SendMessage(0x31, 0, 0, ctrl)
            if hf {
                if !fonts.Has(hf) {
                    lf := Buffer(92, 0)
                    if DllCall("GetObject", "Ptr", hf, "Int", 92, "Ptr", lf) {
                        h0 := Abs(NumGet(lf, 0, "Int"))
                        NumPut("Int", -Max(Round(h0 * fs), minPx), lf, 0)
                        NumPut("Int", 0, lf, 4)
                        fonts[hf] := DllCall("CreateFontIndirectW", "Ptr", lf, "Ptr")
                    } else {
                        fonts[hf] := 0
                    }
                }
                if fonts[hf]
                    SendMessage(0x30, fonts[hf], 1, ctrl)
            }
        }
    }
    ; hover hit-boxes of the styled buttons
    for b in gdipButtons {
        b["x"] := Round(b["x"] * gs)
        b["y"] := Round(b["y"] * gs)
        b["w"] := Round(b["w"] * gs)
        b["h"] := Round(b["h"] * gs)
    }
}

; Always-on-top scroll affordance (created last, after every tab's own
; controls, so it draws above them and is never part of any page's control
; list — it stays visible no matter which tab is showing). Visibility is
; toggled per-page in ShowPage/UpdateScrollArrows - only shown on pages
; that actually overflow the window.
btnScrollUp := MakeStyledButton(MyGui, 737, 118, 16, 22, "▲", (*) => ScrollPageBy(-60), "C34778", "81254F")
btnScrollDown := MakeStyledButton(MyGui, 737, 500, 16, 22, "▼", (*) => ScrollPageBy(60), "C34778", "81254F")

ScaleUI(UI_SCALE, UI_FONT_SCALE)
; a picture control keeps its old bitmap size when moved, so load the dashboard picture again at the new size
try dashPic.Value := dashInitialPic

pages := Map("dashboard", pageDashboard, "autoclicker", pageAutoClicker
    , "cpstest", pageCpsTest, "sessionstats", pageSessionStats
    , "macro", pageMacro, "macroprofiles", pageMacroProfiles
    , "actions", pageActions, "settings", pageSettings)

; ---- Per-page scroll (safety net for any page taller than the window) ----
; Base (x,y) of every control on every page, captured once so scrolling can
; always reposition from a known-good absolute position instead of drifting.
pageBasePos := Map()
for pKey, pArr in pages {
    basePositions := []
    for ctrl in pArr {
        try {
            ctrl.GetPos(&cx, &cy)
            basePositions.Push([ctrl, cx, cy])
        }
    }
    pageBasePos[pKey] := basePositions
}
pageScrollY := Map()
for pKey, pArr in pages
    pageScrollY[pKey] := 0

PageContentBottom(key) {
    global pageBasePos
    maxBottom := 0
    for item in pageBasePos[key] {
        try {
            item[1].GetPos(, , , &ch)
            bottom := item[3] + ch
            if bottom > maxBottom
                maxBottom := bottom
        }
    }
    return maxBottom
}

; Moving dozens of native controls one at a time, each repainting itself as it goes, is what
; left streaks and ghost text behind during a scroll - suppressing the window's own repaint
; for the whole batch and forcing exactly one clean redraw afterward gets rid of that.
ApplyPageScroll(key) {
    global pageBasePos, pageScrollY
    off := Round(pageScrollY[key])
    GuiRedrawOff()
    try {
        for item in pageBasePos[key] {
            try item[1].Move(item[2], item[3] - off)
        }
    } finally {
        GuiRedrawOn()
    }
}

OnMouseWheelScroll(wParam, lParam, msg, hwnd) {
    global pages, currentPage, pageScrollY, MyGui
    if !pages.Has(currentPage)
        return
    WinGetClientPos(, , , &winH, "ahk_id " MyGui.Hwnd)
    maxScroll := PageContentBottom(currentPage) - (winH - 12)
    if maxScroll < 0
        maxScroll := 0
    if maxScroll = 0
        return  ; this page already fits - nothing to scroll

    deltaNotches := (wParam >> 16) & 0xFFFF
    if deltaNotches > 0x7FFF
        deltaNotches -= 0x10000

    ScrollPageBy(deltaNotches > 0 ? -40 : 40)
}
OnMessage(0x20A, OnMouseWheelScroll)

; Shared by the mouse-wheel handler and the always-visible scroll buttons
; below, so every tab can be scrolled the same way even if a wheel event
; doesn't reach a particular control (e.g. while a dropdown has focus).
; Smooth scrolling: a wheel tick (or the arrow buttons) moves a target, and a short-lived
; timer eases pageScrollY toward it a few times a second instead of jumping straight there.
scrollTargetY := Map()
for pKey, pArr in pages
    scrollTargetY[pKey] := 0
scrollAnimOn := false

ScrollPageBy(amount) {
    global pages, currentPage, pageScrollY, scrollTargetY, MyGui
    if !pages.Has(currentPage)
        return
    WinGetClientPos(, , , &winH, "ahk_id " MyGui.Hwnd)
    maxScroll := PageContentBottom(currentPage) - (winH - 12)
    if maxScroll < 0
        maxScroll := 0
    base := scrollTargetY.Has(currentPage) ? scrollTargetY[currentPage] : pageScrollY[currentPage]
    scrollTargetY[currentPage] := Max(0, Min(base + amount, maxScroll))
    ScrollAnimStart()
}

ScrollAnimStart() {
    global scrollAnimOn
    if scrollAnimOn
        return
    scrollAnimOn := true
    SetTimer(ScrollAnimStep, 10)
}

ScrollAnimStep() {
    global pages, currentPage, pageScrollY, scrollTargetY, scrollAnimOn
    if !pages.Has(currentPage) {
        SetTimer(ScrollAnimStep, 0)
        scrollAnimOn := false
        return
    }
    cur := pageScrollY[currentPage]
    tgt := scrollTargetY.Has(currentPage) ? scrollTargetY[currentPage] : cur
    diff := tgt - cur
    if Abs(diff) < 0.5 {
        if cur != tgt {
            pageScrollY[currentPage] := tgt
            ApplyPageScroll(currentPage)
        }
        SetTimer(ScrollAnimStep, 0)
        scrollAnimOn := false
        return
    }
    pageScrollY[currentPage] := cur + diff * 0.45
    ApplyPageScroll(currentPage)
}


UpdateScrollArrows() {
    global pages, currentPage, btnScrollUp, btnScrollDown, MyGui
    needed := false
    if pages.Has(currentPage) {
        ; Fails before the window is first shown (e.g. the initial
        ; ShowPage("dashboard") at startup, which runs before MyGui.Show());
        ; just skip the check then - it runs again on every real tab switch.
        try {
            WinGetClientPos(, , , &winH, "ahk_id " MyGui.Hwnd)
            needed := PageContentBottom(currentPage) > (winH - 12)
        }
    }
    try btnScrollUp.Visible := needed
    try btnScrollDown.Visible := needed
}

ShowPage(key) {
    GuiRedrawOff()
    try {
        ShowPageInner(key)
    } finally {
        GuiRedrawOn()
    }
}

ShowPageInner(key) {
    global pages, navLabels, navButtons, currentPage, pageScrollY, scrollTargetY, accent, bg, fg, MyGui
    if !pages.Has(key)
        return
    for k, arr in pages {
        visible := (k = key)
        for ctrl in arr
            try ctrl.Opt(visible ? "-Hidden" : "+Hidden")
    }
    for k, btn in navButtons {
        btn.Text := (k = key ? "> " : "") . navLabels[k]
        try btn.Opt("Background" (k = key ? accent : bg) " c" fg)
    }
    currentPage := key
    pageScrollY[key] := 0
    scrollTargetY[key] := 0
    ApplyPageScroll(key)
    if key = "autoclicker"
        UpdateModeUI()
    if key = "actions"
        ActApplyFields()
    UpdateScrollArrows()
}

ChooseDashboardImage() {
    global dashboardImagePath, dashPic, dashPicHint, dataFile
    chosen := FileSelect(1, , "Choose a dashboard picture", "Images (*.png; *.jpg; *.jpeg; *.gif; *.bmp)")
    if chosen = ""
        return
    dashboardImagePath := chosen
    dashPic.Value := chosen
    dashPicHint.Text := chosen
    IniWrite(chosen, dataFile, "Dashboard", "ImagePath")
}

; Start with no content page selected. Pages are laid out and shown only
; after the user clicks a sidebar item, which avoids the first-render clipping
; caused by hidden controls being created before their page is activated.
for k, arr in pages {
    for ctrl in arr
        try ctrl.Opt("+Hidden")
}
for k, btn in navButtons {
    btn.Text := navLabels[k]
    try btn.Opt("Background" bg " c" fg)
}
; Show the Dashboard on startup. Only the Dashboard is visible initially;
; Auto Clicker and its mode panels remain hidden until that page is opened.
ShowPage("dashboard")
; ================= Events =================
ddRepeat.OnEvent("Change", (*) => eCount.Enabled := (ddRepeat.Text = "Fixed Count"))
ddHotkey.OnEvent("Change", (*) => UpdateHotkey())
ddMode.OnEvent("Change", (*) => UpdateModeUI())

; ---------------- Mode helpers ----------------
KeyPressOptions() {
    keys := []
    loop 9
        keys.Push(String(A_Index))
    keys.Push("0")
    loop 26
        keys.Push(Chr(64 + A_Index))
    special := ["Space", "Enter", "Tab", "Escape", "Backspace", "Delete", "Insert"
        , "Home", "End", "PgUp", "PgDn", "Up", "Down", "Left", "Right"
        , "LShift", "RShift", "LCtrl", "RCtrl", "LAlt", "RAlt", "LWin", "RWin"
        , "CapsLock", "AppsKey", "PrintScreen", "ScrollLock", "Pause", "NumLock"
        , "F1", "F3", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
        , "Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9"
        , "NumpadDot", "NumpadAdd", "NumpadSub", "NumpadMult", "NumpadDiv", "NumpadEnter"
        , "-", "=", "[", "]", "\", "``", ";", "'", ",", ".", "/"]
    for k in special
        keys.Push(k)
    return keys
}

CurrentMode() {
    global ddMode
    t := ddMode.Text
    if InStr(t, "Window Focus")
        return "Window"
    if InStr(t, "Key Press")
        return "Key"
    return "Normal"
}

UpdateModeUI() {
    global ddMode, accent, sub
    global grpNormal, txtNormalHint1, txtNormalHint2, txtNormalHint3
    global grpTarget, txtWinLabel, ddWinList, btnRefresh, btnUseSelected, btnPickSpot, txtTarget, txtCoords
    global grpKey, txtKeyLabel, ddKeyPress, txtKeyHint1, txtKeyHint2, txtKeyHint3
    global ddButton, ddType, btnTest

    mode := CurrentMode()
    normalMode := (mode = "Normal")
    windowMode := (mode = "Window")
    keyMode    := (mode = "Key")

    for ctrl in [grpNormal, txtNormalHint1, txtNormalHint2, txtNormalHint3]
        ctrl.Visible := normalMode
    grpNormal.Opt(normalMode ? "c" accent : "c" sub)

    for ctrl in [grpTarget, txtWinLabel, ddWinList, btnRefresh, btnUseSelected, btnPickSpot, txtTarget, txtCoords]
        ctrl.Visible := windowMode
    grpTarget.Opt(windowMode ? "c" accent : "c" sub)

    for ctrl in [grpKey, txtKeyLabel, ddKeyPress, txtKeyHint1, txtKeyHint2, txtKeyHint3]
        ctrl.Visible := keyMode
    grpKey.Opt(keyMode ? "c" accent : "c" sub)

    ; Button/double-click type only apply to real mouse clicks
    ddButton.Enabled := !keyMode
    ddType.Enabled := !keyMode

    btnTest.Text := keyMode ? "Test Key Press Once" : "Test Click Once"
}
; Do not initialize the Auto Clicker mode panel at startup.
; It stays hidden until the Auto Clicker page is opened, where ShowPage() initializes it.
RefreshWindowList()

; ---------------- Window picker list ----------------
RefreshWindowList() {
    global winList, ddWinList
    winList := Map()
    items := []
    idx := 1
    for hwnd in WinGetList() {
        try t := WinGetTitle("ahk_id " hwnd)
        catch {
            continue
        }
        if (t = "" || t = "Macro AIO")
            continue
        winList[idx] := hwnd
        display := StrLen(t) > 40 ? SubStr(t, 1, 40) "..." : t
        items.Push(display)
        idx += 1
    }
    if items.Length = 0
        items.Push("(no windows found)")
    ddWinList.Delete()
    ddWinList.Add(items)
    ddWinList.Choose(1)
}

UseSelectedWindow() {
    global targetTopHwnd, targetTitle, targetHwnd, clickX, clickY, winList
    global ddWinList, txtTarget, txtCoords
    i := ddWinList.Value
    if !winList.Has(i) {
        MsgBox("Pick a valid window from the list first (hit Refresh if empty).", "Macro AIO", 48)
        return
    }
    targetTopHwnd := winList[i]
    targetTitle := WinGetTitle("ahk_id " targetTopHwnd)
    targetHwnd := 0
    clickX := 0, clickY := 0
    shortTitle := StrLen(targetTitle) > 32 ? SubStr(targetTitle, 1, 32) "..." : targetTitle
    txtTarget.Text := "Selected: " shortTitle
    txtCoords.Text := "Now click 'Set Spot' and press F3 over the exact spot."
}

; ---------------- Click-spot picking ----------------
BeginPickSpot() {
    global pickMode, targetTopHwnd
    if !targetTopHwnd {
        MsgBox("Select a window from the list first, then click 'Use Selected'.", "Macro AIO", 48)
        return
    }
    pickMode := true
    ToolTip("Hover the exact click-spot inside that window and press F3. Esc to cancel.")
    SetTimer(WatchPick, 50)
}

WatchPick() {
    global pickMode, targetHwnd, clickX, clickY, txtCoords
    if !pickMode
        return
    if GetKeyState("F3", "P") {
        MouseGetPos(&mx, &my)
        child := GetDeepestChildAtScreenPoint(mx, my)
        if child {
            targetHwnd := child
            pt := Buffer(8, 0)
            NumPut("int", mx, pt, 0)
            NumPut("int", my, pt, 4)
            DllCall("ScreenToClient", "ptr", child, "ptr", pt)
            clickX := NumGet(pt, 0, "int")
            clickY := NumGet(pt, 4, "int")
            txtCoords.Text := "Position set: x=" clickX ", y=" clickY " (locked)"
        }
        ToolTip()
        SetTimer(WatchPick, 0)
        pickMode := false
    } else if GetKeyState("Escape", "P") {
        ToolTip()
        SetTimer(WatchPick, 0)
        pickMode := false
    }
}

GetDeepestChildAtScreenPoint(sx, sy) {
    hwnd := DllCall("WindowFromPoint", "int64", (sy << 32) | (sx & 0xFFFFFFFF), "ptr")
    if !hwnd
        return 0
    loop {
        pt := Buffer(8, 0)
        NumPut("int", sx, pt, 0)
        NumPut("int", sy, pt, 4)
        DllCall("ScreenToClient", "ptr", hwnd, "ptr", pt)
        cx := NumGet(pt, 0, "int"), cy := NumGet(pt, 4, "int")
        child := DllCall("ChildWindowFromPointEx", "ptr", hwnd, "int64", (cy << 32) | (cx & 0xFFFFFFFF), "uint", 1, "ptr")
        if !child || child = hwnd
            break
        hwnd := child
    }
    return hwnd
}

; ---------------- Hotkey management ----------------
; Note: the Hotkey control fires "Change" on every in-progress keystroke
; while recording a combo (e.g. once for just Ctrl, again once the full
; combo is pressed) - not just once at the end. This only acts on a real,
; different, bindable key, and never writes back into the control itself
; (doing that mid-recording cancels the recording).
UpdateHotkey() {
    global toggleKey, ddHotkey, btnStart, btnStop

    newKey := ddHotkey.Value
    if newKey = toggleKey
        return  ; not an actual change (duplicate/partial Change event) - ignore it

    if newKey = "" {
        try Hotkey(toggleKey, ToggleClicking, "Off")
        toggleKey := ""
        btnStart.Text := "Start (no hotkey)"
        btnStop.Text := "Stop (no hotkey)"
        return
    }

    try {
        ; Confirm the new key actually works BEFORE giving up the old one.
        Hotkey(newKey, ToggleClicking, "On")
        if toggleKey != ""
            try Hotkey(toggleKey, ToggleClicking, "Off")
        toggleKey := newKey
        btnStart.Text := "Start (" toggleKey ")"
        btnStop.Text := "Stop (" toggleKey ")"
    } catch {
        ; Not bindable yet (mid-recording a combo) - leave the old binding
        ; and the control alone; it'll settle on the next keypress.
    }
}

ToggleClicking(*) {
    global clicking
    if clicking
        StopClicking()
    else
        StartClicking()
}

; ---------------- Start / Stop ----------------
StartClicking() {
    global clicking, cpsWindowStart, cpsWindowCount, targetHwnd, txtStatus, green, chkHighSpeed
    if CurrentMode() = "Window" && !targetHwnd {
        MsgBox("Select a window AND set a click spot first.", "Macro AIO", 48)
        return
    }
    if clicking
        return
    clicking := true
    cpsWindowStart := A_TickCount
    cpsWindowCount := 0
    txtStatus.Text := "RUNNING"
    txtStatus.Opt("c" green)
    if chkHighSpeed.Value
        StartHighSpeed()
    else
        SetTimer(DoClick, -1)
}

StopClicking() {
    global clicking, txtStatus, red, txtLiveCps
    clicking := false
    SetTimer(DoClick, 0)
    SetTimer(HighSpeedTick, 0)
    txtStatus.Text := "STOPPED"
    txtStatus.Opt("c" red)
    txtLiveCps.Text := "0.0"
}

TestClick() {
    global ddButton, ddKeyPress, targetHwnd, clickX, clickY
    mode := CurrentMode()
    btn := ddButton.Text
    if mode = "Window" {
        if !targetHwnd {
            MsgBox("Select a window and set a click spot first.", "Macro AIO", 48)
            return
        }
        SendBackgroundClick(targetHwnd, clickX, clickY, btn)
        ToolTip("Sent 1 test click.")
        SetTimer(() => ToolTip(), -1000)
    } else if mode = "Key" {
        key := ddKeyPress.Text
        Send("{" key " down}")
        Send("{" key " up}")
        ToolTip("Sent 1 test key press: " key)
        SetTimer(() => ToolTip(), -1000)
    } else {
        Click(btn)
    }
}

; ---------------- Click logic ----------------
DoClick() {
    global clicking, sessionClicks, lifetimeClicks, targetHwnd, targetTopHwnd
    global clickX, clickY, cpsWindowStart, cpsWindowCount, sessionPeakCps
    global chkFailsafe, eHours, eMins, eSecs, eMs, ddButton, ddType, ddKeyPress
    global ddRepeat, eCount, txtLiveCps, txtSessionClicks, currentPage

    if !clicking
        return

    if chkFailsafe.Value {
        MouseGetPos(&fmx, &fmy)
        if fmy >= A_ScreenHeight - 2 {
            StopClicking()
            ToolTip("Failsafe triggered - cursor hit bottom of screen.")
            SetTimer(() => ToolTip(), -2000)
            return
        }
    }

    h := Integer(eHours.Text = "" ? 0 : eHours.Text)
    m := Integer(eMins.Text = "" ? 0 : eMins.Text)
    s := Integer(eSecs.Text = "" ? 0 : eSecs.Text)
    ms := Integer(eMs.Text = "" ? 0 : eMs.Text)
    interval := ms + (s * 1000) + (m * 60000) + (h * 3600000)
    if interval < 1
        interval := 1

    mode := CurrentMode()
    btn := ddButton.Text
    doubleClick := ddType.Text = "Double"

    if mode = "Window" {
        if !WinExist("ahk_id " targetTopHwnd) {
            StopClicking()
            ToolTip("Target window closed - clicker stopped.")
            SetTimer(() => ToolTip(), -2000)
            return
        }
        SendBackgroundClick(targetHwnd, clickX, clickY, btn)
        if CurrentPageIsCpsTarget(targetHwnd)
            NotifyCpsAutoClick(1)
        if doubleClick {
            SendBackgroundClick(targetHwnd, clickX, clickY, btn)
            if CurrentPageIsCpsTarget(targetHwnd)
                NotifyCpsAutoClick(1)
        }
    } else if mode = "Key" {
        key := ddKeyPress.Text
        Send("{" key " down}")
        Send("{" key " up}")
        if doubleClick {
            Send("{" key " down}")
            Send("{" key " up}")
        }
    } else {
        clickCount := doubleClick ? 2 : 1
        Click(btn, clickCount)
        ; Feed our own synthetic clicks directly into the CPS engine.
        ; AHK-generated Click events do not reliably pass through the global
        ; physical LButton hotkey, so relying on that hook alone misses the
        ; autoclicker's clicks.
        if currentPage = "cpstest"
            NotifyCpsAutoClick(clickCount)
    }

    sessionClicks += 1
    lifetimeClicks += 1
    cpsWindowCount += 1
    txtSessionClicks.Text := sessionClicks

    elapsed := A_TickCount - cpsWindowStart
    if elapsed >= 400 {
        actualCps := Round(cpsWindowCount / (elapsed / 1000), 1)
        txtLiveCps.Text := actualCps
        if actualCps > sessionPeakCps
            sessionPeakCps := actualCps
        cpsWindowStart := A_TickCount
        cpsWindowCount := 0
    }

    if (ddRepeat.Text = "Fixed Count") {
        target := Integer(eCount.Text = "" ? 0 : eCount.Text)
        if sessionClicks >= target {
            StopClicking()
            return
        }
    }

    if clicking
        SetTimer(DoClick, -interval)
}

SendBackgroundClick(hwnd, x, y, button) {
    lParam := (y << 16) | (x & 0xFFFF)
    if (button = "Left") {
        downMsg := 0x201, upMsg := 0x202, wp := 1
    } else if (button = "Right") {
        downMsg := 0x204, upMsg := 0x205, wp := 2
    } else {
        downMsg := 0x207, upMsg := 0x208, wp := 0x10
    }
    PostMessage(0x200, 0, lParam, , "ahk_id " hwnd)
    PostMessage(downMsg, wp, lParam, , "ahk_id " hwnd)
    PostMessage(upMsg, 0, lParam, , "ahk_id " hwnd)
}

; ---------------- High Speed Mode ----------------
; Why the normal clicker stalls around 60-70 CPS: it fires ONE click per
; SetTimer callback, Windows timers only tick about every 15.6ms (~64 a
; second), and every click also does GUI work. High Speed Mode decouples the
; click rate from the timer rate: a short tick (every few ms) works out how
; many clicks are "owed" since the last tick using the high-resolution
; counter, then sends them all in ONE batched call. Ticks stay tiny, so the
; rest of the macro (recorder, GUI) keeps running smoothly.
; Everything is wrapped in try/catch so a problem stops the clicker quietly
; with a tooltip instead of throwing an AHK error dialog.

StartHighSpeed() {
    global hsFreq, hsLast, hsCarry, hsRunClicks
    freq := 0, startCount := 0
    try {
        DllCall("QueryPerformanceFrequency", "Int64*", &freq)
        DllCall("QueryPerformanceCounter", "Int64*", &startCount)
    } catch {
        freq := 0
    }
    if freq <= 0 {
        ; No high-res counter available - fall back to the normal clicker.
        SetTimer(DoClick, -1)
        return
    }
    hsFreq := freq
    hsLast := startCount
    hsCarry := 0.0
    hsRunClicks := 0
    SetTimer(HighSpeedTick, 5)
}

; Reads the Target CPS box without ever throwing on blank/garbage text.
HsReadCps() {
    global eHsCps
    t := Trim(eHsCps.Text)
    if !IsNumber(t)
        return 100
    return Min(Max(t + 0, 1), 10000)
}

HsInt(text, fallback := 0) {
    t := Trim(text)
    return IsInteger(t) ? Integer(t) : fallback
}

HighSpeedTick() {
    global clicking, hsFreq, hsLast, hsCarry, hsRunClicks
    global sessionClicks, lifetimeClicks, cpsWindowStart, cpsWindowCount, sessionPeakCps
    global chkFailsafe, ddButton, ddType, ddKeyPress, ddRepeat, eCount
    global targetHwnd, targetTopHwnd, clickX, clickY
    global txtSessionClicks, txtLiveCps, currentPage

    if !clicking {
        SetTimer(HighSpeedTick, 0)
        return
    }

    try {
        ; Same bottom-of-screen failsafe as the normal clicker.
        if chkFailsafe.Value {
            MouseGetPos(&fmx, &fmy)
            if fmy >= A_ScreenHeight - 2 {
                StopClicking()
                ToolTip("Failsafe triggered - cursor hit bottom of screen.")
                SetTimer(() => ToolTip(), -2000)
                return
            }
        }

        ; How many clicks are owed since the last tick?
        nowCount := 0
        DllCall("QueryPerformanceCounter", "Int64*", &nowCount)
        dt := (nowCount - hsLast) / hsFreq
        hsLast := nowCount
        if dt <= 0
            return
        if dt > 0.1
            dt := 0.02   ; the script stalled (window drag etc.) - don't dump a huge catch-up burst
        hsCarry += dt * HsReadCps()
        n := Floor(hsCarry)
        if n < 1
            return
        hsCarry -= n

        mode := CurrentMode()
        mult := (ddType.Text = "Double") ? 2 : 1

        ; Per-tick safety caps so one batch can never flood the input queue
        ; or the target window's message queue (Window mode is the touchiest).
        maxRaw := (mode = "Window") ? 25 : (mode = "Key") ? 60 : 300
        capActions := Max(1, maxRaw // mult)
        if n > capActions
            n := capActions   ; can't keep up this tick - drop the excess instead of building a backlog

        fixedCount := (ddRepeat.Text = "Fixed Count")
        target := 0
        if fixedCount {
            target := HsInt(eCount.Text, 0)
            if hsRunClicks >= target {
                StopClicking()
                return
            }
            if n > target - hsRunClicks
                n := target - hsRunClicks
        }

        ; Make sure no artificial per-click delay applies in this timer thread.
        SetMouseDelay(-1)
        SetKeyDelay(-1, -1)

        btn := ddButton.Text
        raw := n * mult

        if mode = "Window" {
            if !WinExist("ahk_id " targetTopHwnd) {
                StopClicking()
                ToolTip("Target window closed - clicker stopped.")
                SetTimer(() => ToolTip(), -2000)
                return
            }
            sent := 0
            loop raw {
                try {
                    SendBackgroundClick(targetHwnd, clickX, clickY, btn)
                } catch {
                    break   ; target's queue is full or the window vanished - skip the rest this tick
                }
                sent += 1
            }
            if sent = 0
                return
            raw := sent
            n := Ceil(sent / mult)
            if CurrentPageIsCpsTarget(targetHwnd)
                NotifyCpsAutoClick(raw)
        } else if mode = "Key" {
            key := ddKeyPress.Text
            one := "{" key " down}{" key " up}"
            seq := ""
            loop raw
                seq .= one
            Send(seq)
        } else {
            Click(btn, raw)
            if currentPage = "cpstest"
                NotifyCpsAutoClick(raw)
        }

        hsRunClicks += n
        sessionClicks += n
        lifetimeClicks += n
        cpsWindowCount += n

        ; GUI text is only refreshed a few times a second - updating it on
        ; every batch is exactly the kind of overhead that causes lag.
        nowTick := A_TickCount
        elapsed := nowTick - cpsWindowStart
        if elapsed >= 250 {
            actualCps := Round(cpsWindowCount / (elapsed / 1000), 1)
            txtLiveCps.Text := actualCps
            txtSessionClicks.Text := sessionClicks
            if actualCps > sessionPeakCps
                sessionPeakCps := actualCps
            cpsWindowStart := nowTick
            cpsWindowCount := 0
        }

        if fixedCount && hsRunClicks >= target
            StopClicking()
    } catch as err {
        HighSpeedFail(err)
    }
}

; Any unexpected problem lands here: stop quietly, never show an error dialog.
HighSpeedFail(err) {
    try {
        StopClicking()
    } catch {
    }
    try {
        msg := ""
        try {
            msg := err.Message
        } catch {
            msg := "unknown error"
        }
        ToolTip("High Speed Mode stopped: " msg)
        SetTimer(() => ToolTip(), -3000)
    } catch {
    }
}

; ---------------- CPS Test ----------------
CurrentPageIsCpsTarget(hwnd) {
    global currentPage, btnCpsBox
    if currentPage != "cpstest" || !btnCpsBox.Enabled
        return false
    return hwnd = btnCpsBox.Hwnd
}

NotifyCpsAutoClick(count := 1) {
    global currentPage, cpsTestRunning, cpsTestClicks, cpsTestEndTick, btnCpsBox, txtCpsCount
    if currentPage != "cpstest" || !btnCpsBox.Enabled
        return

    now := A_TickCount
    if !cpsTestRunning {
        ; The first synthetic click starts the test and is itself a counted
        ; click, matching the physical-click path.
        CpsTestBegin()
    }

    if !cpsTestRunning
        return

    if now >= cpsTestEndTick {
        CpsTestTick()
        return
    }

    cpsTestClicks += count
    txtCpsCount.Text := "Clicks: " cpsTestClicks
}

CpsTestClick() {
    ; Fallback for the GUI control's Click notification. The actual CPS
    ; counting is handled by the global physical-mouse hook below so rapid
    ; clicks are not lost by GUI command/event throttling.
    global cpsTestRunning, btnCpsBox
    if !btnCpsBox.Enabled
        return
    if !cpsTestRunning
        CpsTestBegin()
}

CpsTestBegin() {
    global cpsTestRunning, cpsTestClicks, cpsTestEndTick, ddCpsDuration
    global btnCpsBox, txtCpsResult, txtCpsTimer, txtCpsCount
    durText := ddCpsDuration.Text
    durSec := Integer(StrSplit(durText, " ")[1])
    cpsTestRunning := true
    cpsTestClicks := 0
    cpsTestEndTick := A_TickCount + (durSec * 1000)
    btnCpsBox.Text := "GO! Keep clicking..."
    txtCpsResult.Text := "Testing..."
    txtCpsTimer.Text := "Time left: " durSec ".0s"
    txtCpsCount.Text := "Clicks: 0"
    SetTimer(CpsTestTick, 25)
}

CpsTestRawMouseDown(*) {
    global currentPage, cpsTestRunning, cpsTestClicks, cpsTestEndTick, btnCpsBox, txtCpsCount

    ; Only count physical left-button presses that actually land on the big
    ; CPS test surface. WindowFromPoint is much lighter than asking the GUI
    ; for positions on every click, which helps at high CPS.
    if currentPage != "cpstest" || !btnCpsBox.Enabled
        return

    MouseGetPos(&mx, &my)
    hitHwnd := DllCall("WindowFromPoint", "int64", (my << 32) | (mx & 0xFFFFFFFF), "ptr")
    if hitHwnd != btnCpsBox.Hwnd
        return

    now := A_TickCount
    if !cpsTestRunning {
        CpsTestBegin()
        return
    }

    ; Exclude a click that lands after the test window has expired but before
    ; the display timer gets its next 25 ms tick.
    if now >= cpsTestEndTick {
        CpsTestTick()
        return
    }

    cpsTestClicks += 1
    txtCpsCount.Text := "Clicks: " cpsTestClicks
}

CpsTestTick() {
    global cpsTestRunning, cpsTestClicks, cpsTestEndTick
    global ddCpsDuration, txtCpsResult, txtCpsTimer
    remaining := cpsTestEndTick - A_TickCount
    if remaining <= 0 {
        cpsTestRunning := false
        SetTimer(CpsTestTick, 0)
        durText := ddCpsDuration.Text
        durSec := Integer(StrSplit(durText, " ")[1])
        finalCps := Round(cpsTestClicks / durSec, 2)
        txtCpsResult.Text := finalCps " CPS  (" cpsTestClicks " clicks / " durSec "s)"
        txtCpsTimer.Text := "Time left: -"
        StartCpsCooldown()
        return
    }
    txtCpsTimer.Text := "Time left: " Round(remaining / 1000, 1) "s"
}

StartCpsCooldown() {
    global cpsCooldownEndTick, btnCpsBox
    cpsCooldownEndTick := A_TickCount + 5000
    btnCpsBox.Enabled := false
    SetTimer(CpsCooldownTick, 50)
}

CpsCooldownTick() {
    global cpsCooldownEndTick, btnCpsBox
    remaining := cpsCooldownEndTick - A_TickCount
    if remaining <= 0 {
        SetTimer(CpsCooldownTick, 0)
        btnCpsBox.Text := "Click here to start"
        btnCpsBox.Enabled := true
        return
    }
    btnCpsBox.Text := "Cooldown: " Round(remaining / 1000, 1) "s"
}

; ============================================================
; ACTIONS — logic
; ============================================================
ActInt(v, fallback := 0) {
    t := Trim(v)
    return IsInteger(t) ? Integer(t) : fallback
}

ActClean(s) {
    return StrReplace(StrReplace(StrReplace(s, "`t", " "), "`r", ""), "`n", " ")
}

; Shows/hides the input slots that the chosen action type uses. resetValues = true also
; refills them with that type's defaults (used when the type changes).
ActApplyFields(resetValues := false) {
    global ddActType, txtActHint, ActSpecs, btnActBrowse
    global actLblA, actEdA, actLblB, actEdB, actLblC, actEdC, actLblD, actEdD
    global actLblO1, ddActO1, actLblO2, ddActO2
    t := ddActType.Text
    if !ActSpecs.Has(t)
        return
    spec := ActSpecs[t]
    txtActHint.Text := spec["hint"]
    for slot in [["a", actLblA, actEdA], ["b", actLblB, actEdB], ["c", actLblC, actEdC], ["d", actLblD, actEdD]] {
        has := spec.Has(slot[1])
        slot[2].Visible := has
        slot[3].Visible := has
        if has {
            slot[2].Text := spec[slot[1]][1]
            if resetValues
                slot[3].Value := spec[slot[1]][2]
        }
    }
    for slot in [["o1", actLblO1, ddActO1], ["o2", actLblO2, ddActO2]] {
        has := spec.Has(slot[1])
        slot[2].Visible := has
        slot[3].Visible := has
        if has {
            slot[2].Text := spec[slot[1]][1]
            if resetValues {
                slot[3].Delete()
                slot[3].Add(spec[slot[1]][2])
                slot[3].Choose(1)
            }
        }
    }
    btnActBrowse.Visible := (t = "Find Image" || t = "Wait For Image")
}

ActBrowseImage() {
    global actEdA
    f := FileSelect(1, , "Choose the image to look for", "Images (*.png; *.bmp; *.jpg; *.jpeg; *.gif)")
    if f != ""
        actEdA.Value := f
}

ActReadForm() {
    global ddActType, ActSpecs, actEdA, actEdB, actEdC, actEdD, ddActO1, ddActO2
    t := ddActType.Text
    spec := ActSpecs[t]
    st := Map("type", t)
    for k, ctl in Map("a", actEdA, "b", actEdB, "c", actEdC, "d", actEdD)
        st[k] := spec.Has(k) ? ActClean(Trim(ctl.Value)) : ""
    st["o1"] := spec.Has("o1") ? ddActO1.Text : ""
    st["o2"] := spec.Has("o2") ? ddActO2.Text : ""
    return st
}

; Returns "" when the action is fine, otherwise a message saying what to fix.
ActValidate(st) {
    t := st["type"]
    switch t {
        case "Click":
            if (st["a"] = "") != (st["b"] = "")
                return "Fill in both X and Y, or leave both empty to click at the cursor."
            if st["a"] != "" && (!IsInteger(st["a"]) || !IsInteger(st["b"]))
                return "X and Y must be whole numbers."
            if !IsInteger(st["c"]) || Integer(st["c"]) < 1
                return "Click count must be 1 or more."
        case "Move Mouse":
            if !IsInteger(st["a"]) || !IsInteger(st["b"])
                return "X and Y must be whole numbers."
        case "Drag Mouse":
            for k in ["a", "b", "c", "d"] {
                if !IsInteger(st[k])
                    return "All four coordinates must be whole numbers."
            }
        case "Scroll":
            if !IsInteger(st["a"]) || Integer(st["a"]) = 0
                return "Notches must be a whole number other than 0."
        case "Key Press", "Hold Key":
            if st["a"] = ""
                return "Enter the key to press."
            if t = "Hold Key" && (!IsInteger(st["b"]) || Integer(st["b"]) < 0)
                return "Hold time must be 0 or more milliseconds."
        case "Type Text":
            if st["a"] = ""
                return "Enter the text to type."
        case "Delay":
            if !IsInteger(st["a"]) || Integer(st["a"]) < 0
                return "Delay must be 0 or more milliseconds."
        case "Random Delay":
            if !IsInteger(st["a"]) || !IsInteger(st["b"]) || Integer(st["a"]) < 0
                return "Min and Max must be whole milliseconds."
            if Integer(st["a"]) > Integer(st["b"])
                return "Min can't be bigger than Max."
        case "Find Image", "Wait For Image":
            if st["a"] = "" || !FileExist(st["a"])
                return "Pick an image file that exists (use the ... button)."
            if !IsInteger(st["b"]) || Integer(st["b"]) < 0 || Integer(st["b"]) > 255
                return "Tolerance must be between 0 and 255."
            if !IsInteger(st["c"]) || Integer(st["c"]) < 0
                return "The time limit must be 0 or more milliseconds."
        case "Activate Window":
            if st["a"] = ""
                return "Enter (part of) the window title."
        case "Run / Open":
            if st["a"] = ""
                return "Enter a program, file or web address."
    }
    return ""
}

ActSummary(st) {
    t := st["type"]
    switch t {
        case "Click":
            where := st["a"] = "" ? "at cursor" : st["a"] ", " st["b"]
            more := ActInt(st["c"], 1) > 1 ? "  x" st["c"] : ""
            return st["o1"] " @ " where more
        case "Move Mouse":
            return st["a"] ", " st["b"]
        case "Drag Mouse":
            return st["a"] "," st["b"] " > " st["c"] "," st["d"] "  (" st["o1"] ")"
        case "Scroll":
            return st["a"] " notches"
        case "Key Press":
            return st["a"]
        case "Hold Key":
            return st["a"] " for " st["b"] " ms"
        case "Type Text":
            return st["a"]
        case "Delay":
            return st["a"] " ms"
        case "Random Delay":
            return st["a"] " - " st["b"] " ms"
        case "Find Image", "Wait For Image":
            SplitPath(st["a"], &nm)
            extra := (t = "Find Image") ? st["o1"] : "wait"
            lim := ActInt(st["c"], 0)
            return nm "  (" extra (lim > 0 ? ", up to " lim " ms" : "") ")"
        case "Activate Window":
            return st["a"]
        case "Run / Open":
            return st["a"]
    }
    return ""
}

ActRefreshList(selectRow := 0) {
    global lvActs, actSteps, txtActStatus
    lvActs.Opt("-Redraw")
    lvActs.Delete()
    for i, st in actSteps
        lvActs.Add(, i, st["type"], ActSummary(st))
    lvActs.Opt("+Redraw")
    if selectRow >= 1 && selectRow <= actSteps.Length
        lvActs.Modify(selectRow, "Select Focus Vis")
    ActSaveLast()
}

ActAdd() {
    global actSteps, lvActs
    st := ActReadForm()
    err := ActValidate(st)
    if err != "" {
        MsgBox(err, "Macro AIO", 48)
        return
    }
    row := lvActs.GetNext(0)
    if row {
        actSteps.InsertAt(row + 1, st)
        ActRefreshList(row + 1)
    } else {
        actSteps.Push(st)
        ActRefreshList(actSteps.Length)
    }
}

ActReplace() {
    global actSteps, lvActs, txtActStatus
    row := lvActs.GetNext(0)
    if !row {
        txtActStatus.Text := "Select a row in the sequence first."
        return
    }
    st := ActReadForm()
    err := ActValidate(st)
    if err != "" {
        MsgBox(err, "Macro AIO", 48)
        return
    }
    actSteps[row] := st
    ActRefreshList(row)
}

ActLoadRowIntoForm() {
    global actSteps, lvActs, ddActType, actEdA, actEdB, actEdC, actEdD, ddActO1, ddActO2, ActSpecs
    row := lvActs.GetNext(0)
    if !row
        return
    st := actSteps[row]
    ddActType.Choose(st["type"])
    ActApplyFields(true)
    spec := ActSpecs[st["type"]]
    for k, ctl in Map("a", actEdA, "b", actEdB, "c", actEdC, "d", actEdD) {
        if spec.Has(k)
            ctl.Value := st[k]
    }
    for k, ctl in Map("o1", ddActO1, "o2", ddActO2) {
        if spec.Has(k)
            try ctl.Choose(st[k])
    }
}

ActMove(dir) {
    global actSteps, lvActs
    row := lvActs.GetNext(0)
    if !row
        return
    newRow := row + dir
    if newRow < 1 || newRow > actSteps.Length
        return
    st := actSteps.RemoveAt(row)
    actSteps.InsertAt(newRow, st)
    ActRefreshList(newRow)
}

ActRemove() {
    global actSteps, lvActs
    row := lvActs.GetNext(0)
    if !row
        return
    actSteps.RemoveAt(row)
    ActRefreshList(Min(row, actSteps.Length))
}

ActClear() {
    global actSteps
    if actSteps.Length = 0
        return
    if MsgBox("Remove all " actSteps.Length " actions from the sequence?", "Macro AIO", 4 | 48) != "Yes"
        return
    actSteps := []
    ActRefreshList()
}

; ---- Saving / loading ----
ActWriteFile(path) {
    global actSteps
    text := ""
    for st in actSteps
        text .= st["type"] "`t" st["a"] "`t" st["b"] "`t" st["c"] "`t" st["d"] "`t" st["o1"] "`t" st["o2"] "`n"
    try FileDelete(path)
    FileAppend(text, path, "UTF-8")
}

ActReadFile(path) {
    global ActSpecs
    steps := []
    text := FileRead(path, "UTF-8")
    loop parse text, "`n", "`r" {
        if A_LoopField = ""
            continue
        p := StrSplit(A_LoopField, "`t")
        if p.Length < 7 || !ActSpecs.Has(p[1])
            continue
        steps.Push(Map("type", p[1], "a", p[2], "b", p[3], "c", p[4], "d", p[5], "o1", p[6], "o2", p[7]))
    }
    return steps
}

ActSaveLast() {
    global actFile
    try ActWriteFile(actFile)
}

ActLoadLast() {
    global actFile, actSteps
    if !FileExist(actFile)
        return
    try {
        actSteps := ActReadFile(actFile)
        ActRefreshList()
    }
}

ActSaveAs() {
    global actSteps, txtActStatus
    if actSteps.Length = 0 {
        txtActStatus.Text := "Nothing to save - the sequence is empty."
        return
    }
    f := FileSelect("S16", A_ScriptDir "\my_sequence.txt", "Save action list", "Action list (*.txt)")
    if f = ""
        return
    try {
        ActWriteFile(f)
        txtActStatus.Text := "Saved " actSteps.Length " actions."
    } catch {
        txtActStatus.Text := "Could not save that file."
    }
}

ActLoadFrom() {
    global actSteps, txtActStatus, actRunning
    if actRunning {
        txtActStatus.Text := "Stop the sequence before loading another."
        return
    }
    f := FileSelect(1, A_ScriptDir, "Load action list", "Action list (*.txt)")
    if f = ""
        return
    try {
        steps := ActReadFile(f)
    } catch {
        txtActStatus.Text := "Could not read that file."
        return
    }
    if steps.Length = 0 {
        txtActStatus.Text := "No actions found in that file."
        return
    }
    actSteps := steps
    ActRefreshList(1)
    txtActStatus.Text := "Loaded " steps.Length " actions."
}

; ---- Run key ----
ActBindRunKey() {
    global hkActRun, actRunKey
    newKey := hkActRun.Value
    if newKey = actRunKey
        return
    if newKey = "" {
        try Hotkey(actRunKey, ActToggle, "Off")
        actRunKey := ""
        return
    }
    try {
        Hotkey(newKey, ActToggle, "On")
        if actRunKey != ""
            try Hotkey(actRunKey, ActToggle, "Off")
        actRunKey := newKey
    }
}

; ---- Running ----
ActToggle(*) {
    global actRunning
    if actRunning
        ActStop("Stopped.")
    else
        ActStart()
}

ActStart() {
    global actRunning, actSteps, clicking, recording, playing, btnActRun, txtActStatus
    if actRunning
        return
    if clicking || recording || playing {
        MsgBox("Stop the clicker / recorder / playback first.", "Macro AIO", 48)
        return
    }
    if actSteps.Length = 0 {
        MsgBox("Add at least one action first.", "Macro AIO", 48)
        return
    }
    actRunning := true
    btnActRun.Text := "Running..."
    SetTimer(ActRunLoop, -1)
}

ActStop(msg := "Stopped.") {
    global actRunning, btnActRun, txtActStatus
    wasRunning := actRunning
    actRunning := false
    btnActRun.Text := "Run Sequence"
    if wasRunning
        txtActStatus.Text := msg
}

; Sleeps in short slices so Stop / the kill switch react right away.
ActSleep(ms) {
    global actRunning
    end := A_TickCount + ms
    while actRunning && A_TickCount < end
        Sleep(Min(20, Max(1, end - A_TickCount)))
}

ActRunLoop() {
    global actRunning, actSteps, ddActRepeat, eActStart, eActGap, txtActStatus, chkFailsafe, btnActRun
    rep := ddActRepeat.Text
    if InStr(rep, "Loop")
        total := -1
    else if InStr(rep, "once")
        total := 1
    else
        total := ActInt(StrReplace(StrSplit(rep, " ")[2], "x"), 1)
    gap := Max(0, ActInt(eActGap.Value, 100))
    startAfter := Max(0, ActInt(eActStart.Value, 0))
    steps := actSteps.Clone()

    reason := "Finished."
    if startAfter > 0 {
        remaining := startAfter
        while actRunning && remaining > 0 {
            txtActStatus.Text := "Starting in " remaining "..."
            ActSleep(1000)
            remaining -= 1
        }
    }
    loops := 0
    while actRunning {
        for i, st in steps {
            if !actRunning
                break
            if chkFailsafe.Value {
                MouseGetPos(, &fy)
                if fy >= A_ScreenHeight - 2 {
                    reason := "Failsafe: cursor reached the bottom of the screen."
                    actRunning := false
                    break
                }
            }
            txtActStatus.Text := "Loop " (loops + 1) "  -  step " i " of " steps.Length ": " st["type"]
            res := ""
            try res := ActExecute(st)
            catch as err {
                reason := "Stopped on an error at step " i ": " err.Message
                actRunning := false
                break
            }
            if res = "stop" {
                reason := "Stopped at step " i " (image not found)."
                actRunning := false
                break
            }
            Sleep(1)
            if st["type"] != "Delay" && st["type"] != "Random Delay"
                ActSleep(gap)
        }
        if !actRunning
            break
        loops += 1
        if total != -1 && loops >= total
            break
    }
    wasStopped := !actRunning && reason = "Finished."
    actRunning := false
    btnActRun.Text := "Run Sequence"
    txtActStatus.Text := wasStopped ? "Stopped." : reason
}

ActSendKey(k) {
    if RegExMatch(k, "^[\^+!#]") || InStr(k, "{")
        Send(k)
    else
        Send("{" k "}")
}

; Runs one action. Returns "stop" when the whole sequence should end (e.g. image not found + stop).
ActExecute(st) {
    global actRunning
    CoordMode("Mouse", "Screen")
    CoordMode("Pixel", "Screen")
    SetTitleMatchMode(2)
    t := st["type"]
    switch t {
        case "Click":
            btn := st["o1"] = "" ? "Left" : st["o1"]
            n := Max(1, ActInt(st["c"], 1))
            if st["a"] != "" && st["b"] != ""
                MouseClick(btn, Integer(st["a"]), Integer(st["b"]), n, 0)
            else
                MouseClick(btn, , , n, 0)
        case "Move Mouse":
            MouseMove(Integer(st["a"]), Integer(st["b"]), 0)
        case "Drag Mouse":
            MouseClickDrag(st["o1"] = "" ? "Left" : st["o1"], Integer(st["a"]), Integer(st["b"]), Integer(st["c"]), Integer(st["d"]), 8)
        case "Scroll":
            n := Integer(st["a"])
            Send("{Wheel" (n > 0 ? "Up" : "Down") " " Abs(n) "}")
        case "Key Press":
            ActSendKey(st["a"])
        case "Hold Key":
            k := st["a"]
            Send("{" k " down}")
            ActSleep(ActInt(st["b"], 500))
            Send("{" k " up}")
        case "Type Text":
            SendText(st["a"])
        case "Delay":
            ActSleep(ActInt(st["a"], 0))
        case "Random Delay":
            lo := ActInt(st["a"], 0)
            hi := Max(lo, ActInt(st["b"], lo))
            ActSleep(Random(lo, hi))
        case "Find Image", "Wait For Image":
            return ActImageStep(st)
        case "Activate Window":
            try WinActivate(st["a"])
        case "Run / Open":
            try Run(st["a"])
    }
    return ""
}

; Image search on the whole (virtual) screen. Returns true and the image centre when found.
ActFindImage(path, tol, &cx, &cy) {
    cx := 0, cy := 0
    if !FileExist(path)
        return false
    x1 := SysGet(76), y1 := SysGet(77)
    x2 := x1 + SysGet(78), y2 := y1 + SysGet(79)
    ok := false
    fx := 0, fy := 0
    try ok := ImageSearch(&fx, &fy, x1, y1, x2, y2, "*" tol " " path)
    if !ok
        return false
    sz := ActImageSize(path)
    cx := fx + sz[1] // 2
    cy := fy + sz[2] // 2
    return true
}

ActImageSize(path) {
    static cache := Map()
    if cache.Has(path)
        return cache[path]
    w := 0, h := 0
    try {
        pBmp := Gdip_CreateBitmapFromFile(path)
        if pBmp {
            w := Gdip_GetImageWidth(pBmp)
            h := Gdip_GetImageHeight(pBmp)
            Gdip_DisposeImage(pBmp)
        }
    }
    if w < 1 || h < 1
        w := 2, h := 2
    cache[path] := [w, h]
    return cache[path]
}

ActImageStep(st) {
    global actRunning, actLastImageFound
    isWait := (st["type"] = "Wait For Image")
    path := st["a"]
    tol := ActInt(st["b"], 30)
    timeout := Max(0, ActInt(st["c"], isWait ? 10000 : 0))
    onFound := isWait ? "Just continue" : st["o1"]
    onMiss := isWait ? st["o1"] : st["o2"]
    start := A_TickCount
    found := false
    cx := 0, cy := 0
    loop {
        found := ActFindImage(path, tol, &cx, &cy)
        if found || !actRunning || (A_TickCount - start >= timeout)
            break
        ActSleep(100)
    }
    actLastImageFound := found
    if !actRunning
        return ""
    if !found
        return InStr(onMiss, "Stop") ? "stop" : ""
    if onFound = "Click it"
        MouseClick("Left", cx, cy, 1, 0)
    else if onFound = "Move mouse to it"
        MouseMove(cx, cy, 0)
    return ""
}

; ---- Test one action from the form ----
ActTest() {
    global txtActStatus, actRunning
    if actRunning
        return
    st := ActReadForm()
    err := ActValidate(st)
    if err != "" {
        MsgBox(err, "Macro AIO", 48)
        return
    }
    txtActStatus.Text := "Testing in 2 seconds..."
    SetTimer(() => ActTestRun(st), -2000)
}

ActTestRun(st) {
    global actRunning, txtActStatus, actLastImageFound
    if actRunning
        return
    actRunning := true
    err := ""
    try ActExecute(st)
    catch as e
        err := e.Message
    actRunning := false
    if err != ""
        txtActStatus.Text := "Test failed: " err
    else if st["type"] = "Find Image" || st["type"] = "Wait For Image"
        txtActStatus.Text := actLastImageFound ? "Test: image found." : "Test: image NOT found."
    else
        txtActStatus.Text := "Test done."
}

; ---------------- Global kill switch ----------------
KillSwitch(*) {
    global clicking, recording, playing, playbackPaused, actRunning
    if clicking
        StopClicking()
    if recording
        StopRecording()
    if playing || playbackPaused
        StopPlayback()
    if actRunning
        ActStop("Stopped (kill switch).")
    ; Release every modifier/mouse-button that might be stuck down from a bugged macro
    Send("{Blind}{LShift up}{RShift up}{LCtrl up}{RCtrl up}{LAlt up}{RAlt up}{LWin up}{RWin up}")
    Click("Left", , , "U")
    Click("Right", , , "U")
    Click("Middle", , , "U")
    ToolTip("⛔ KILL SWITCH — everything stopped, keys released")
    SetTimer(() => ToolTip(), -1500)
}

; ---------------- Recorder: input hooks ----------------
BuildRecordableKeyList() {
    keys := []
    loop 26
        keys.Push(Chr(96 + A_Index))
    loop 10
        keys.Push(String(A_Index - 1))
    extra := ["Space", "Enter", "Tab", "Escape", "Backspace", "Delete", "Insert", "Home", "End", "PgUp", "PgDn"
        , "Up", "Down", "Left", "Right", "LShift", "RShift", "LCtrl", "RCtrl", "LAlt", "RAlt", "LWin", "RWin"
        , "CapsLock", "AppsKey", "PrintScreen", "ScrollLock", "Pause", "NumLock"
        , "Numpad0", "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8", "Numpad9"
        , "NumpadDot", "NumpadAdd", "NumpadSub", "NumpadMult", "NumpadDiv", "NumpadEnter"
        , "F1", "F3", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"
        , "-", "=", "[", "]", "\", "``", ";", "'", ",", ".", "/"
        , "LButton", "RButton", "MButton", "WheelUp", "WheelDown"]
    for e in extra
        keys.Push(e)
    filtered := []
    for k in keys {
        if (k != "F2" && k != "F4")
            filtered.Push(k)
    }
    return filtered
}

RegisterRecordingHooks() {
    global recKeyList
    for k in recKeyList {
        ; LButton has a permanent shared hook below so CPS testing and
        ; recording can both observe every physical left-button press.
        if k = "LButton"
            continue
        try Hotkey("~" k, RecordInputEvent, "On")
        try Hotkey("~" k " Up", RecordInputEvent, "On")
    }
}

UnregisterRecordingHooks() {
    global recKeyList
    for k in recKeyList {
        if k = "LButton"
            continue
        try Hotkey("~" k, RecordInputEvent, "Off")
        try Hotkey("~" k " Up", RecordInputEvent, "Off")
    }
}

; Permanent pass-through hooks for left mouse down/up. These intentionally
; remain installed so the CPS test can count raw physical clicks without
; conflicting with the recorder's dynamically registered key hooks.
GlobalLButtonDown(*) {
    global recording
    CpsTestRawMouseDown()
    if recording
        RecordInputEvent()
}

GlobalLButtonUp(*) {
    global recording
    if recording
        RecordInputEvent()
}

RecordInputEvent(*) {
    global recording, recordStartTick, recordedEvents
    if !recording
        return
    raw := A_ThisHotkey
    isUp := InStr(raw, " Up") > 0
    name := StrReplace(StrReplace(raw, "~", ""), " Up", "")
    t := A_TickCount - recordStartTick
    if (name = "LButton" || name = "RButton" || name = "MButton") {
        MouseGetPos(&mx, &my)
        btn := name = "LButton" ? "Left" : (name = "RButton" ? "Right" : "Middle")
        recordedEvents.Push(Map("t", t, "type", isUp ? "mouseup" : "mousedown", "btn", btn, "x", mx, "y", my))
    } else if (name = "WheelUp" || name = "WheelDown") {
        recordedEvents.Push(Map("t", t, "type", "wheel", "dir", name = "WheelUp" ? "Up" : "Down"))
    } else {
        recordedEvents.Push(Map("t", t, "type", isUp ? "keyup" : "keydown", "key", name))
    }
}

PollMouseMove() {
    global recording, recordStartTick, recordedEvents, lastMoveX, lastMoveY, chkRecordMoves
    if !recording || !chkRecordMoves.Value
        return
    MouseGetPos(&mx, &my)
    if (mx != lastMoveX || my != lastMoveY) {
        lastMoveX := mx, lastMoveY := my
        t := A_TickCount - recordStartTick
        recordedEvents.Push(Map("t", t, "type", "move", "x", mx, "y", my))
    }
}

; ---------------- Recorder: start/stop ----------------
StartRecording() {
    global recording, clicking, playing, playbackPaused, recordStartTick, recordedEvents, lastMoveX, lastMoveY
    global macroStatusText, txtRecFile, chkRecordMoves
    if clicking || playing || playbackPaused {
        MsgBox("Stop the clicker/playback before recording.", "Macro AIO", 48)
        return
    }
    if recording
        return
    recordedEvents := []
    recording := true
    recordStartTick := A_TickCount
    MouseGetPos(&lastMoveX, &lastMoveY)
    if chkRecordMoves.Value
        recordedEvents.Push(Map("t", 0, "type", "move", "x", lastMoveX, "y", lastMoveY))
    try {
        SoundBeep(800, 90)    ; rising two-tone = recording started
        SoundBeep(1200, 110)
    }
    MouseGetPos(&lastMoveX, &lastMoveY)
    RegisterRecordingHooks()
    SetTimer(PollMouseMove, 15)
    macroStatusText.Text := "Recording — capturing input"
    txtRecFile.Text := "Recording in progress..."
}

StopRecording() {
    global recording, macroStatusText
    if !recording
        return
    recording := false
    SetTimer(PollMouseMove, 0)
    UnregisterRecordingHooks()
    try {
        SoundBeep(1200, 90)   ; falling two-tone = recording stopped
        SoundBeep(700, 130)
    }
    macroStatusText.Text := "Idle — recording ready"
    UpdateRecorderUI()
}

ToggleRecording(*) {
    global recording
    if recording
        StopRecording()
    else
        StartRecording()
}

; ---------------- Playback ----------------
StartPlayback() {
    global playing, recording, clicking, playbackPaused, recordedEvents, playbackIndex, playbackStartTick
    global playbackRepeatsTotal, playbackRepeatsDone, playbackPauseStartTick, ddPlayRepeat, macroStatusText, macroSpeedText, eSpeed
    if recording || clicking {
        MsgBox("Stop recording/clicking before playing back.", "Macro AIO", 48)
        return
    }
    if recordedEvents.Length = 0 {
        MsgBox("No recording to play. Record something first (F2).", "Macro AIO", 48)
        return
    }
    if playing
        return
    playing := true
    playbackPaused := false
    playbackPauseStartTick := 0
    playbackIndex := 1
    playbackStartTick := A_TickCount
    playbackRepeatsDone := 0
    repText := ddPlayRepeat.Text
    if InStr(repText, "Loop")
        playbackRepeatsTotal := -1
    else if InStr(repText, "Once")
        playbackRepeatsTotal := 1
    else
        playbackRepeatsTotal := Integer(StrReplace(StrSplit(repText, " ")[2], "x", ""))
    macroStatusText.Text := "Playing macro"
    macroSpeedText.Text := Integer(eSpeed.Text = "" ? 100 : eSpeed.Text) "%"
    RecMonOpen()
    SetTimer(PlaybackTick, -1)
}

StopPlayback() {
    global playing, playbackPaused, playbackPauseStartTick, macroStatusText, macroSpeedText
    if !playing && !playbackPaused
        return
    playing := false
    playbackPaused := false
    playbackPauseStartTick := 0
    SetTimer(PlaybackTick, 0)
    RecMonClose()
    macroStatusText.Text := "Idle — ready"
    macroSpeedText.Text := "100%"
}

TogglePlaybackPause(*) {
    global playing, playbackPaused, playbackPauseStartTick, playbackStartTick, macroStatusText
    if playing {
        playing := false
        playbackPaused := true
        playbackPauseStartTick := A_TickCount
        SetTimer(PlaybackTick, 0)
        macroStatusText.Text := "Playback paused"
        return
    }
    if playbackPaused {
        playbackStartTick += A_TickCount - playbackPauseStartTick
        playbackPauseStartTick := 0
        playbackPaused := false
        playing := true
        macroStatusText.Text := "Playing macro"
        SetTimer(PlaybackTick, -1)
    }
}

StopMacroActivity(*) {
    global recording, playing, playbackPaused
    if recording
        StopRecording()
    if playing || playbackPaused
        StopPlayback()
}

; ---- Recorder loop monitor ----
RecMonOpen() {
    global recMon, monitorEnabled, playbackRepeatsTotal
    RecMonClose()
    if !monitorEnabled || playbackRepeatsTotal != -1
        return
    recMon := RunMonitor("Recorder", ["Status", "Current action", "Loops completed"], RecMonUpdate)
}

RecMonClose() {
    global recMon
    if IsObject(recMon)
        recMon.Close()
    recMon := ""
}

RecMonUpdate(m) {
    global playing, playbackPaused, recordedEvents, playbackIndex, playbackRepeatsDone
    if !playing && !playbackPaused
        return
    idx := Min(playbackIndex, recordedEvents.Length)
    m.Set("Status", playbackPaused ? "Paused" : "Playing (looping)")
    if idx >= 1 {
        ev := recordedEvents[idx]
        switch ev["type"] {
            case "move":      act := "Moving mouse to " ev["x"] ", " ev["y"]
            case "mousedown": act := "Pressing " ev["btn"] " button at " ev["x"] ", " ev["y"]
            case "mouseup":   act := "Releasing " ev["btn"] " button at " ev["x"] ", " ev["y"]
            case "keydown":   act := "Pressing key " ev["key"]
            case "keyup":     act := "Releasing key " ev["key"]
            case "wheel":     act := "Scrolling " ev["dir"]
            default:          act := ev["type"]
        }
    } else {
        act := "-"
    }
    m.SetAction(playbackPaused ? "Paused" : act)
    m.Set("Loops completed", playbackRepeatsDone)
}

TogglePlayback(*) {
    global playing, playbackPaused
    if playbackPaused {
        TogglePlaybackPause()
        return
    }
    if playing
        StopPlayback()
    else
        StartPlayback()
}

; Fired only by clicking "Save Keybind" (a deliberate action), not on every
; live keystroke in the box - a Hotkey control fires its Change event on
; every in-progress key while recording a combo, and reacting to that
; automatically is what caused the earlier "save keybind" feature to be
; unreliable. Recording a combo in the box first, then explicitly clicking
; Save, sidesteps that. The key is also written to the data ini so it's
; remembered the next time the app is opened, not just for this run.
UpdatePlaybackHotkey(*) {
    global playbackToggleKey, ddPlaybackHotkey, txtPlaybackKeyStatus, dataFile

    newKey := ddPlaybackHotkey.Value
    if newKey = "" {
        try Hotkey(playbackToggleKey, TogglePlayback, "Off")
        playbackToggleKey := ""
        txtPlaybackKeyStatus.Text := "No keybind set — record one, then click Save Keybind."
        IniWrite("", dataFile, "Hotkeys", "PlaybackKey")
        return
    }
    if newKey = playbackToggleKey {
        txtPlaybackKeyStatus.Text := "Toggle key: " playbackToggleKey " (already saved)."
        return
    }

    try {
        ; Confirm the new key actually works BEFORE giving up the old one.
        Hotkey(newKey, TogglePlayback, "On")
        if playbackToggleKey != ""
            try Hotkey(playbackToggleKey, TogglePlayback, "Off")
        playbackToggleKey := newKey
        IniWrite(playbackToggleKey, dataFile, "Hotkeys", "PlaybackKey")
        txtPlaybackKeyStatus.Text := "Saved! Toggle key: " playbackToggleKey
    } catch {
        txtPlaybackKeyStatus.Text := "Couldn't bind that key/combo — try a different one."
    }
}

PlaybackTick() {
    global playing, playbackPaused, recordedEvents, playbackIndex, playbackStartTick
    global playbackRepeatsTotal, playbackRepeatsDone, eSpeed, chkFailsafe, macroStatusText

    if !playing || playbackPaused
        return

    if chkFailsafe.Value {
        MouseGetPos(&fmx, &fmy)
        if fmy >= A_ScreenHeight - 2 {
            StopPlayback()
            ToolTip("Failsafe triggered - playback stopped.")
            SetTimer(() => ToolTip(), -2000)
            return
        }
    }

    if playbackIndex > recordedEvents.Length {
        playbackRepeatsDone += 1
        if playbackRepeatsTotal = -1 || playbackRepeatsDone < playbackRepeatsTotal {
            playbackIndex := 1
            playbackStartTick := A_TickCount
            SetTimer(PlaybackTick, -1)
            return
        } else {
            playing := false
            macroStatusText.Text := "Idle — playback complete"
            return
        }
    }

    speedPct := Integer(eSpeed.Text = "" ? 100 : eSpeed.Text)
    if speedPct < 1
        speedPct := 100
    speedFactor := speedPct / 100

    ev := recordedEvents[playbackIndex]
    targetElapsed := ev["t"] / speedFactor
    actualElapsed := A_TickCount - playbackStartTick
    wait := targetElapsed - actualElapsed
    if wait > 2 {
        SetTimer(PlaybackTick, -Min(wait, 1000))
        return
    }

    ExecutePlaybackEvent(ev)
    playbackIndex += 1
    SetTimer(PlaybackTick, -1)
}

ExecutePlaybackEvent(ev) {
    switch ev["type"] {
        case "move":
            MouseMove(ev["x"], ev["y"], 0)
        case "mousedown":
            Click(ev["x"], ev["y"], ev["btn"], , , "D")
        case "mouseup":
            Click(ev["x"], ev["y"], ev["btn"], , , "U")
        case "keydown":
            try Send("{" ev["key"] " down}")
        case "keyup":
            try Send("{" ev["key"] " up}")
        case "wheel":
            try Send(ev["dir"] = "Up" ? "{WheelUp}" : "{WheelDown}")
    }
}

; ---------------- Recorder: save / load / clear ----------------
EventsToText(events) {
    lines := ""
    for ev in events {
        switch ev["type"] {
            case "move":
                lines .= "MOVE|" ev["t"] "|" ev["x"] "|" ev["y"] "`n"
            case "keydown":
                lines .= "KD|" ev["t"] "|" ev["key"] "`n"
            case "keyup":
                lines .= "KU|" ev["t"] "|" ev["key"] "`n"
            case "mousedown":
                lines .= "MD|" ev["t"] "|" ev["btn"] "|" ev["x"] "|" ev["y"] "`n"
            case "mouseup":
                lines .= "MU|" ev["t"] "|" ev["btn"] "|" ev["x"] "|" ev["y"] "`n"
            case "wheel":
                lines .= "WH|" ev["t"] "|" ev["dir"] "`n"
        }
    }
    return lines
}

TextToEvents(content) {
    newEvents := []
    loop parse, content, "`n", "`r" {
        if A_LoopField = ""
            continue
        parts := StrSplit(A_LoopField, "|")
        type := parts[1]
        t := Integer(parts[2])
        switch type {
            case "MOVE":
                newEvents.Push(Map("t", t, "type", "move", "x", Integer(parts[3]), "y", Integer(parts[4])))
            case "KD":
                newEvents.Push(Map("t", t, "type", "keydown", "key", parts[3]))
            case "KU":
                newEvents.Push(Map("t", t, "type", "keyup", "key", parts[3]))
            case "MD":
                newEvents.Push(Map("t", t, "type", "mousedown", "btn", parts[3], "x", Integer(parts[4]), "y", Integer(parts[5])))
            case "MU":
                newEvents.Push(Map("t", t, "type", "mouseup", "btn", parts[3], "x", Integer(parts[4]), "y", Integer(parts[5])))
            case "WH":
                newEvents.Push(Map("t", t, "type", "wheel", "dir", parts[3]))
        }
    }
    return newEvents
}

SaveRecordingToFile(path) {
    global recordedEvents
    if FileExist(path)
        FileDelete(path)
    FileAppend(EventsToText(recordedEvents), path, "UTF-8")
}

LoadRecordingFromFile(path) {
    global recordedEvents
    if !FileExist(path)
        return false
    recordedEvents := TextToEvents(FileRead(path, "UTF-8"))
    return true
}

DoSaveRecording() {
    global recordedEvents, txtRecFile, recordingFilePath
    if recordedEvents.Length = 0 {
        MsgBox("Nothing recorded yet.", "Macro AIO", 48)
        return
    }
    path := FileSelect("S16", A_ScriptDir "\recording.actrec", "Save Recording", "Recording (*.actrec)")
    if path = ""
        return
    if !InStr(path, ".")
        path .= ".actrec"
    SaveRecordingToFile(path)
    recordingFilePath := path
    UpdateMacroFileLabel(path)
    txtRecFile.Text := "Saved: " path
}

DoExportRecording() {
    DoSaveRecording()
}

SaveRecordingCurrent() {
    ; The main Macro-tab Save button creates a named profile. The profile
    ; contains both recorder settings and the full event stream.
    DoSaveProfile()
}

DoLoadRecording() {
    global recordedEvents, txtRecFile, recordingFilePath
    path := FileSelect(1, A_ScriptDir, "Import Recording", "Recording (*.actrec)")
    if path = ""
        return
    if LoadRecordingFromFile(path) {
        recordingFilePath := path
        UpdateMacroFileLabel(path)
        txtRecFile.Text := "Loaded: " path " (" recordedEvents.Length " events)"
    } else {
        MsgBox("Could not load that file.", "Macro AIO", 48)
    }
    UpdateRecorderUI()
}

ClearRecording() {
    global recordedEvents, txtRecFile, recordingFilePath, macroStatusText
    recordedEvents := []
    recordingFilePath := ""
    UpdateMacroFileLabel("")
    txtRecFile.Text := "No recording."
    macroStatusText.Text := "Idle — ready"
    UpdateRecorderUI()
}

UpdateMacroFileLabel(path) {
    global ddMacroRecording
    name := path = "" ? "New recording" : ""
    if path != ""
        SplitPath(path, &name)
    ddMacroRecording.Delete()
    ddMacroRecording.Add([name])
    ddMacroRecording.Choose(1)
}

UpdateRecorderUI() {
    global recording, recordStartTick, recordedEvents, txtRecCount, txtRecDuration, macroSpeedText, eSpeed
    txtRecCount.Text := "Events: " recordedEvents.Length
    speedText := Trim(eSpeed.Text)
    if speedText = "" || !RegExMatch(speedText, "^-?\d+(\.\d+)?$")
        speedText := "100"
    macroSpeedText.Text := speedText "%"
    if recording {
        elapsed := (A_TickCount - recordStartTick) // 1000
        txtRecDuration.Text := "Duration: " FormatHMS(elapsed)
    } else {
        durationSec := recordedEvents.Length ? (recordedEvents[recordedEvents.Length]["t"] // 1000) : 0
        txtRecDuration.Text := "Duration: " FormatHMS(durationSec)
    }
}

; ---------------- Profile Manager ----------------
ChooseByText(ctrl, options, text) {
    for i, opt in options {
        if opt = text {
            ctrl.Choose(i)
            return true
        }
    }
    return false
}

profilesDir := A_ScriptDir "\Profiles"
DirCreate(profilesDir)

ListProfileNames() {
    global profilesDir
    names := []
    loop files, profilesDir "\*.profile" {
        SplitPath(A_LoopFileName, , , , &nameNoExt)
        names.Push(nameNoExt)
    }
    return names
}

RefreshProfileList() {
    global ddProfiles
    names := ListProfileNames()
    ddProfiles.Delete()
    if names.Length = 0
        ddProfiles.Add(["(no profiles saved)"])
    else
        ddProfiles.Add(names)
    ddProfiles.Choose(1)
}

DoSaveProfile() {
    global profilesDir, txtProfileStatus, ddMacroRecording, txtRecFile, ddProfiles
    global ddMode, ddHotkey, ddButton, ddType, ddRepeat, eCount, eHours, eMins, eSecs, eMs
    global chkFailsafe, ddKeyPress, targetTitle, clickX, clickY
    global chkRecordMoves, ddPlayRepeat, eSpeed, recordedEvents
    global chkHighSpeed, eHsCps

    name := ""
    result := InputBox("Enter a name for this profile:", "Save Profile", "w300 h120")
    if result.Result != "OK" || Trim(result.Value) = ""
        return
    name := Trim(result.Value)
    ; Strip characters that aren't safe in a filename
    name := RegExReplace(name, '[\\/:*?"<>|]', "_")

    lines := ""
    lines .= "Mode=" ddMode.Text "`n"
    lines .= "Hotkey=" ddHotkey.Value "`n"
    lines .= "Button=" ddButton.Text "`n"
    lines .= "Type=" ddType.Text "`n"
    lines .= "Repeat=" ddRepeat.Text "`n"
    lines .= "Count=" eCount.Text "`n"
    lines .= "Hours=" eHours.Text "`n"
    lines .= "Min=" eMins.Text "`n"
    lines .= "Sec=" eSecs.Text "`n"
    lines .= "Ms=" eMs.Text "`n"
    lines .= "Failsafe=" chkFailsafe.Value "`n"
    lines .= "HighSpeed=" chkHighSpeed.Value "`n"
    lines .= "HsCps=" eHsCps.Text "`n"
    lines .= "KeyPress=" ddKeyPress.Text "`n"
    lines .= "TargetTitle=" targetTitle "`n"
    lines .= "ClickX=" clickX "`n"
    lines .= "ClickY=" clickY "`n"
    lines .= "RecordMoves=" chkRecordMoves.Value "`n"
    lines .= "PlayRepeat=" ddPlayRepeat.Text "`n"
    lines .= "Speed=" eSpeed.Text "`n"
    lines .= "===EVENTS===`n"
    lines .= EventsToText(recordedEvents)

    path := profilesDir "\" name ".profile"
    if FileExist(path)
        FileDelete(path)
    FileAppend(lines, path, "UTF-8")
    RefreshProfileList()
    ddProfiles.Text := name
    ddMacroRecording.Delete()
    ddMacroRecording.Add([name])
    ddMacroRecording.Choose(1)
    txtRecFile.Text := "Saved profile macro: " name " (" recordedEvents.Length " events)"
    txtProfileStatus.Text := "Saved profile: " name " — macro + settings stored together."
    ShowPage("macroprofiles")
}

DoLoadProfile() {
    global profilesDir, ddProfiles, txtProfileStatus
    global ddMode, ddHotkey, ddButton, ddType, ddRepeat, eCount, eHours, eMins, eSecs, eMs
    global chkFailsafe, ddKeyPress, targetTitle, targetTopHwnd, targetHwnd, clickX, clickY, txtTarget, txtCoords
    global chkRecordMoves, ddPlayRepeat, eSpeed, recordedEvents, recordingFilePath
    global ddMacroRecording, txtRecFile
    global chkHighSpeed, eHsCps

    name := ddProfiles.Text
    if name = "" || name = "(no profiles saved)"
        return
    path := profilesDir "\" name ".profile"
    if !FileExist(path) {
        MsgBox("That profile file is missing.", "Macro AIO", 48)
        return
    }

    content := FileRead(path, "UTF-8")
    parts := StrSplit(content, ["===EVENTS===`n"])
    settingsText := parts[1]
    eventsText := parts.Length > 1 ? parts[2] : ""

    settings := Map()
    loop parse, settingsText, "`n", "`r" {
        if A_LoopField = "" || !InStr(A_LoopField, "=")
            continue
        kv := StrSplit(A_LoopField, "=", , 2)
        settings[kv[1]] := kv.Length > 1 ? kv[2] : ""
    }

    if settings.Has("Mode")
        ChooseByText(ddMode, ["Normal (click at cursor)", "Window Focus (background click)", "Key Press (auto-press key)"], settings["Mode"])
    UpdateModeUI()
    if settings.Has("Hotkey") && settings["Hotkey"] != "" {
        ddHotkey.Value := settings["Hotkey"]
        UpdateHotkey()
    }
    if settings.Has("Button")
        ChooseByText(ddButton, ["Left", "Right", "Middle"], settings["Button"])
    if settings.Has("Type")
        ChooseByText(ddType, ["Single", "Double"], settings["Type"])
    if settings.Has("Repeat")
        ChooseByText(ddRepeat, ["Until Stopped", "Fixed Count"], settings["Repeat"])
    if settings.Has("Count")
        eCount.Text := settings["Count"]
    if settings.Has("Hours")
        eHours.Text := settings["Hours"]
    if settings.Has("Min")
        eMins.Text := settings["Min"]
    if settings.Has("Sec")
        eSecs.Text := settings["Sec"]
    if settings.Has("Ms")
        eMs.Text := settings["Ms"]
    if settings.Has("Failsafe")
        chkFailsafe.Value := Integer(settings["Failsafe"])
    if settings.Has("HighSpeed")
        chkHighSpeed.Value := IsInteger(settings["HighSpeed"]) ? Integer(settings["HighSpeed"]) : 0
    if settings.Has("HsCps")
        eHsCps.Text := settings["HsCps"]
    if settings.Has("KeyPress")
        ChooseByText(ddKeyPress, KeyPressOptions(), settings["KeyPress"])
    if settings.Has("RecordMoves")
        chkRecordMoves.Value := Integer(settings["RecordMoves"])
    if settings.Has("PlayRepeat")
        ChooseByText(ddPlayRepeat, ["Play Once", "Repeat 3x", "Repeat 5x", "Repeat 10x", "Loop Until Stopped"], settings["PlayRepeat"])
    if settings.Has("Speed")
        eSpeed.Text := settings["Speed"]
    if settings.Has("ClickX")
        clickX := Integer(settings["ClickX"])
    if settings.Has("ClickY")
        clickY := Integer(settings["ClickY"])
    txtCoords.Text := "Click position: x=" clickX ", y=" clickY

    ; Best-effort: try to re-find the target window by its saved title
    if settings.Has("TargetTitle") && settings["TargetTitle"] != "" {
        targetTitle := settings["TargetTitle"]
        if WinExist(targetTitle) {
            targetTopHwnd := WinExist(targetTitle)
            targetHwnd := targetTopHwnd
            txtTarget.Text := "Target: " targetTitle " (relinked)"
        } else {
            targetTopHwnd := 0
            txtTarget.Text := "Target: " targetTitle " (not currently open)"
        }
    }

    recordedEvents := TextToEvents(eventsText)
    recordingFilePath := ""
    UpdateMacroFileLabel("")
    ddMacroRecording.Delete()
    ddMacroRecording.Add([name])
    ddMacroRecording.Choose(1)
    txtRecFile.Text := "Loaded profile macro: " name " (" recordedEvents.Length " events)"
    UpdateRecorderUI()

    txtProfileStatus.Text := "Loaded profile: " name " — " recordedEvents.Length " recorded events + saved settings."
    ShowPage("macro")
}

DoDeleteProfile() {
    global profilesDir, ddProfiles, txtProfileStatus
    name := ddProfiles.Text
    if name = "" || name = "(no profiles saved)"
        return
    if MsgBox("Delete profile '" name "'? This can't be undone.", "Macro AIO", 4 | 48) = "No"
        return
    path := profilesDir "\" name ".profile"
    if FileExist(path)
        FileDelete(path)
    RefreshProfileList()
    txtProfileStatus.Text := "Deleted profile: " name
}

; ---------------- Custom Gdip buttons ----------------
; Some Gdip_All.ahk builds don't include Gdip_AddPathArc / Gdip_ClosePathFigure,
; which caused "variable has not been assigned a value" here (AHK v2 treats an
; unrecognized name in call position as an uninitialized variable, not a missing
; function). These two tiny wrappers call the real GDI+ DLL directly so the
; rounded-rect drawing no longer depends on what that included library has.
_GdipAddPathArc(pPath, x, y, w, h, startAngle, sweepAngle) {
    return DllCall("gdiplus\GdipAddPathArc", "ptr", pPath, "float", x, "float", y, "float", w, "float", h, "float", startAngle, "float", sweepAngle)
}

_GdipClosePathFigure(pPath) {
    return DllCall("gdiplus\GdipClosePathFigure", "ptr", pPath)
}

AddRoundedRectPath(pPath, x, y, w, h, r) {
    d := r * 2
    _GdipAddPathArc(pPath, x, y, d, d, 180, 90)
    _GdipAddPathArc(pPath, x + w - d, y, d, d, 270, 90)
    _GdipAddPathArc(pPath, x + w - d, y + h - d, d, d, 0, 90)
    _GdipAddPathArc(pPath, x, y + h - d, d, d, 90, 90)
    try _GdipClosePathFigure(pPath)
}

LightenColor(hex, amt) {
    r := Integer("0x" SubStr(hex, 1, 2)) + amt
    g := Integer("0x" SubStr(hex, 3, 2)) + amt
    b := Integer("0x" SubStr(hex, 5, 2)) + amt
    r := r > 255 ? 255 : r
    g := g > 255 ? 255 : g
    b := b > 255 ? 255 : b
    return Format("{:02X}{:02X}{:02X}", r, g, b)
}

RenderButtonImage(path, w, h, text, top, bottom, hover) {
    topC := hover ? LightenColor(top, 25) : top
    botC := hover ? LightenColor(bottom, 25) : bottom
    pBitmap := Gdip_CreateBitmap(w, h)
    G := Gdip_GraphicsFromImage(pBitmap)
    Gdip_SetSmoothingMode(G, 4)
    pBrush := Gdip_CreateLineBrush(0, 0, 0, h, "0xFF" topC, "0xFF" botC, 1)
    pPath := Gdip_CreatePath()
    AddRoundedRectPath(pPath, 1, 1, w - 2, h - 2, 8)
    Gdip_FillPath(G, pBrush, pPath)
    Gdip_TextToGraphics(G, text, "x0 y0 w" w " h" h " cFFFFFFFF s10 Bold Center vCenter", "Bahnschrift")
    Gdip_SaveBitmapToFile(pBitmap, path)
    Gdip_DeletePath(pPath)
    Gdip_DeleteBrush(pBrush)
    Gdip_DeleteGraphics(G)
    Gdip_DisposeImage(pBitmap)
}

; Creates a rounded-gradient button with a hover-glow state, falling back to a
; plain native button if Gdip rendering fails for any reason.
MakeStyledButton(guiObj, x, y, w, h, text, callback, top, bottom) {
    ; Use a dark themed text control instead of a native Windows Button.
    ; Native buttons were inheriting the Windows light theme and showing as
    ; white rectangles. Text controls let the Diavolo palette stay consistent.
    global gdipButtons
    normal := top
    hover := LightenColor(top, 18)
    btn := guiObj.AddText("x" x " y" y " w" w " h" h " Background" normal " cF7EAF0 Center 0x200 Border", text)
    btn.OnEvent("Click", callback)
    gdipButtons.Push(Map("ctrl", btn, "x", x, "y", y, "w", w, "h", h
        , "normal", normal, "hover", hover, "state", "normal"))
    return btn
}

CheckButtonHover() {
    global gdipButtons, MyGui
    if gdipButtons.Length = 0
        return
    try
        WinGetClientPos(&gx, &gy, , , "ahk_id " MyGui.Hwnd)
    catch
        return
    MouseGetPos(&mx, &my)
    relX := mx - gx
    relY := my - gy
    for b in gdipButtons {
        inside := (relX >= b["x"] && relX <= b["x"] + b["w"] && relY >= b["y"] && relY <= b["y"] + b["h"])
        newState := inside ? "hover" : "normal"
        if newState != b["state"] {
            b["state"] := newState
            try b["ctrl"].Opt("Background" ((newState = "hover") ? b["hover"] : b["normal"]))
        }
    }
}

; ---------------- Window chrome (dark title bar + rounded corners) ----------------
HexToColorRef(hex) {
    r := Integer("0x" SubStr(hex, 1, 2))
    g := Integer("0x" SubStr(hex, 3, 2))
    b := Integer("0x" SubStr(hex, 5, 2))
    return (b << 16) | (g << 8) | r
}

ApplyDarkTitleBar(hwnd) {
    global accent
    val := 1
    ; DWMWA_USE_IMMERSIVE_DARK_MODE — attribute id differs slightly across Windows 10/11 builds
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 20, "int*", val, "int", 4)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 19, "int*", val, "int", 4)
    ; DWMWA_WINDOW_CORNER_PREFERENCE — Windows 11 only, 2 = DWMWCP_ROUND
    pref := 2
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 33, "int*", pref, "int", 4)
    ; DWMWA_CAPTION_COLOR — Windows 11 only, tints the title bar with the theme accent
    clr := HexToColorRef(accent)
    try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", hwnd, "int", 35, "uint*", clr, "int", 4)
}

CleanupButtonImages() {
    loop files, A_ScriptDir "\.btn_*.png"
        try FileDelete(A_LoopFileFullPath)
}

; ---------------- Session/lifetime stats ----------------
FormatHMS(totalSec) {
    hh := totalSec // 3600
    mm := Mod(totalSec, 3600) // 60
    ss := Mod(totalSec, 60)
    return Format("{:02}:{:02}:{:02}", hh, mm, ss)
}

FormatNum(n) {
    s := String(n)
    cnt := 0
    loop parse, s
        cnt += 1
    out := "", i := 0
    loop parse, s {
        out .= A_LoopField
        i += 1
        if (Mod(cnt - i, 3) = 0 && i < cnt)
            out .= ","
    }
    return out
}

UpdateStatsDisplay() {
    global sessionClicks, appStartTick, lifetimeClicks, totalSessions
    global longestSession, peakCpsEver, sessionPeakCps
    global txtDuration, txtAvgCps, txtPeakCps, txtLifeClicks, txtTotalSessions, txtLongestSession, txtPeakEver

    sessionElapsedSec := (A_TickCount - appStartTick) // 1000
    txtDuration.Text := FormatHMS(sessionElapsedSec)

    avgCps := sessionElapsedSec > 0 ? Round(sessionClicks / sessionElapsedSec, 1) : 0.0
    txtAvgCps.Text := avgCps
    txtPeakCps.Text := Round(sessionPeakCps, 1)

    txtLifeClicks.Text := FormatNum(lifetimeClicks)
    txtTotalSessions.Text := totalSessions
    txtLongestSession.Text := FormatHMS(Max(longestSession, sessionElapsedSec))
    txtPeakEver.Text := Round(Max(peakCpsEver, sessionPeakCps), 1) " CPS"
}

ResetSession() {
    global sessionClicks, appStartTick, sessionPeakCps, cpsWindowStart, cpsWindowCount
    global txtSessionClicks, txtLiveCps
    sessionClicks := 0
    appStartTick := A_TickCount
    sessionPeakCps := 0.0
    cpsWindowStart := A_TickCount
    cpsWindowCount := 0
    txtSessionClicks.Text := "0"
    txtLiveCps.Text := "0.0"
    UpdateStatsDisplay()
}

ResetLifetime() {
    global lifetimeClicks, totalSessions, lifetimeRuntime, longestSession, peakCpsEver, dataFile
    result := MsgBox("This permanently resets your lifetime click count, session count, and records. Continue?", "Reset Lifetime Stats", "YesNo 48")
    if result = "Yes" {
        lifetimeClicks := 0
        totalSessions := 1
        lifetimeRuntime := 0
        longestSession := 0
        peakCpsEver := 0.0
        IniWrite(0, dataFile, "Stats", "LifetimeClicks")
        IniWrite(1, dataFile, "Stats", "TotalSessions")
        IniWrite(0, dataFile, "Stats", "LifetimeRuntimeSec")
        IniWrite(0, dataFile, "Stats", "LongestSessionSec")
        IniWrite(0, dataFile, "Stats", "PeakCpsEver")
        UpdateStatsDisplay()
    }
}

CopyStats() {
    global sessionClicks, lifetimeClicks, totalSessions, appStartTick
    global txtAvgCps, txtPeakCps
    sessionElapsedSec := (A_TickCount - appStartTick) // 1000
    txt := "Macro AIO Stats`n"
        . "Session clicks: " sessionClicks "`n"
        . "Session time: " FormatHMS(sessionElapsedSec) "`n"
        . "Avg CPS (session): " txtAvgCps.Text "`n"
        . "Peak CPS (session): " txtPeakCps.Text "`n"
        . "Lifetime clicks: " FormatNum(lifetimeClicks) "`n"
        . "Total sessions: " totalSessions
    A_Clipboard := txt
    ToolTip("Copied stats to clipboard.")
    SetTimer(() => ToolTip(), -1200)
}

SetTimer(UpdateStatsDisplay, 500)
SetTimer(SaveLifetimeData, 5000)

SaveLifetimeData() {
    global lifetimeClicks, totalSessions, lifetimeRuntime, longestSession, peakCpsEver, sessionPeakCps, appStartTick, dataFile
    sessionElapsedSec := (A_TickCount - appStartTick) // 1000
    IniWrite(lifetimeClicks, dataFile, "Stats", "LifetimeClicks")
    IniWrite(lifetimeRuntime + sessionElapsedSec, dataFile, "Stats", "LifetimeRuntimeSec")
    IniWrite(Max(longestSession, sessionElapsedSec), dataFile, "Stats", "LongestSessionSec")
    IniWrite(Max(peakCpsEver, sessionPeakCps), dataFile, "Stats", "PeakCpsEver")
}

; ---------------- Init ----------------
DllCall("winmm\timeBeginPeriod", "uint", 1)
MyGui.OnEvent("Close", (*) => (CleanupButtonImages(), SaveLifetimeData(), Gdip_Shutdown(gdipToken), DllCall("winmm\timeEndPeriod", "uint", 1), ExitApp()))
UpdateHotkey()
ActBindRunKey()
ActLoadLast()
UpdateStatsDisplay()
Hotkey("F2", ToggleRecording, "On")
if playbackToggleKey != ""
    try Hotkey(playbackToggleKey, TogglePlayback, "On")
Hotkey("Del", KillSwitch, "On")
Hotkey("~LButton", GlobalLButtonDown, "On")
Hotkey("~LButton Up", GlobalLButtonUp, "On")
SetTimer(UpdateRecorderUI, 200)
SetTimer(CheckButtonHover, 60)
UpdateRecorderUI()
RefreshProfileList()
ApplyDarkTitleBar(MyGui.Hwnd)
MyGui.Show("w" Round(760 * UI_SCALE) " h" Round(420 * UI_SCALE))
BgStyleInit()
BgRefresh()
if updCheckOnLaunch
    SetTimer(UpdCheckSilent, -4000)
