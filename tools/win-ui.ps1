# win-ui.ps1
# ---------------------------------------------------------------------------
# Reusable Win32 UI-automation helpers for the Typora translate plugin E2E
# harness.  Dot-source this file from e2e.ps1 (or interactively) to get:
#
#   Initialize-WinUi                     - load native layer + System.Drawing
#   Get-ScreenInfo                       - virtual/physical desktop metrics
#   Get-WindowInfoList                   - enumerate top-level windows
#   Get-WindowInfo                       - describe a single window handle
#   Find-TyporaMainWindow                - pick Typora's real top-level window
#   Set-WindowForeground                 - robust foreground activation
#   Get-ClientScreenRect                 - client area rectangle on screen
#   Invoke-ClientClick                   - left/right click inside client area
#   Send-KeyChord                        - SendInput/keybd_event key chord
#   Save-WindowScreenshot                - PrintWindow, screen fallback, PNG
#   Get-ImageStats                       - blank/variance analysis of a PNG
#   Test-ContainsCjk                     - CJK character detection
#   Wait-Until                           - generic polling helper
#   Read-TextFileShared                  - read a file another process appends
#   Read-JsonFileShared                  - tolerant JSON read
#   Read-LogNewLines                     - incremental log tail (line offset)
#   ConvertTo-UtcDateTime                - tolerant timestamp normalisation
#   Get-ProcessTreeIds                   - root + descendants of a process
#   Stop-ProcessTree                     - kill only a verified process tree
#
# Design notes / pitfalls handled here:
#  * This machine has Windows PowerShell 5.1 (Desktop) as the only PowerShell
#    host and 125% display scaling.  The native layer makes the harness
#    process DPI-aware before any geometry work so that window rects, cursor
#    coordinates and screenshots all use physical pixels consistently.
#  * StringBuilder P/Invokes must declare CharSet.Unicode, otherwise
#    GetWindowTextW only yields the first character ("Typora" -> "T").
#  * Electron/Chromium windows ignore CDP here and can produce black frames
#    from plain BitBlt/PrintWindow; we use PrintWindow(PW_RENDERFULLCONTENT)
#    first, validate the pixels, and fall back to a foreground screen grab.
#  * SetForegroundWindow is often refused by the foreground-activation lock;
#    we unlock with a synthetic ALT tap, AttachThreadInput to the current
#    foreground thread, then verify GetForegroundWindow() == target.
#
# Scripts in this repo are intentionally ASCII-only so Windows PowerShell
# 5.1 (which reads .ps1 as ANSI when there is no BOM) parses them correctly.
# ---------------------------------------------------------------------------

# ===========================================================================
# Native layer (compiled once per session; kept C#5-compatible for PS 5.1)
# ===========================================================================
if (-not ('TyUiNative' -as [type])) {
    $script:TyUiNativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class TyUiNative
{
    // ---- constants -----------------------------------------------------
    public const int SW_RESTORE = 9;
    public const int SW_SHOW = 5;
    public const int SWP_NOSIZE = 0x0001;
    public const int SWP_NOMOVE = 0x0002;
    public const int SWP_SHOWWINDOW = 0x0040;
    public const uint PW_RENDERFULLCONTENT = 0x0002;
    public const uint KEYEVENTF_KEYUP = 0x0002;
    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    public const uint INPUT_KEYBOARD = 1;
    public const int SM_XVIRTUALSCREEN = 76;
    public const int SM_YVIRTUALSCREEN = 77;
    public const int SM_CXVIRTUALSCREEN = 78;
    public const int SM_CYVIRTUALSCREEN = 79;
    public const int SM_CXSCREEN = 0;
    public const int SM_CYSCREEN = 1;

    // ---- structs -------------------------------------------------------
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    // INPUT union layout for 64-bit Windows (sizeof = 40 bytes).
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public MOUSEINPUT mi;
        [FieldOffset(8)] public KEYBDINPUT ki;
        [FieldOffset(8)] public HARDWAREINPUT hi;
    }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    // ---- P/Invoke ------------------------------------------------------
    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("user32.dll")]
    private static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    private static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    // ---- init ----------------------------------------------------------
    // Make the harness DPI aware as early as possible: physical pixels for
    // window rects, SetCursorPos and screen capture.  Both calls are safe to
    // attempt; if a manifest already set awareness the call simply fails.
    static TyUiNative()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch (Exception) { }
        try { SetProcessDPIAware(); } catch (Exception) { }
    }

    // ---- window enumeration -------------------------------------------
    private static string Sanitize(string s)
    {
        if (s == null) { return ""; }
        return s.Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
    }

    private static string Describe(IntPtr h, int pid)
    {
        StringBuilder title = new StringBuilder(1024);
        GetWindowTextW(h, title, 1024);
        StringBuilder cls = new StringBuilder(256);
        GetClassNameW(h, cls, 256);
        RECT r = new RECT();
        GetWindowRect(h, out r);
        bool vis = IsWindowVisible(h);
        bool ico = IsIconic(h);
        return h.ToInt64().ToString() + "\t" + pid.ToString() + "\t" +
               (vis ? "1" : "0") + "\t" + (ico ? "1" : "0") + "\t" +
               Sanitize(cls.ToString()) + "\t" + Sanitize(title.ToString()) + "\t" +
               r.Left.ToString() + "\t" + r.Top.ToString() + "\t" +
               r.Right.ToString() + "\t" + r.Bottom.ToString();
    }

    // Returns one tab-separated line per top-level window:
    // hwnd pid visible iconic class title left top right bottom
    public static string EnumWindowsInfo(int pidFilter)
    {
        StringBuilder sb = new StringBuilder();
        EnumWindowsProc cb = delegate(IntPtr h, IntPtr l)
        {
            uint pid = 0;
            GetWindowThreadProcessId(h, out pid);
            if (pidFilter != 0 && (int)pid != pidFilter) { return true; }
            sb.Append(Describe(h, (int)pid)).Append('\n');
            return true;
        };
        EnumWindows(cb, IntPtr.Zero);
        return sb.ToString();
    }

    public static string GetWindowInfoIntPtr(IntPtr h)
    {
        if (!IsWindow(h)) { return ""; }
        uint pid = 0;
        GetWindowThreadProcessId(h, out pid);
        return Describe(h, (int)pid);
    }

    public static string GetWindowInfo(long hwnd)
    {
        return GetWindowInfoIntPtr(new IntPtr(hwnd));
    }

    public static bool WindowExists(long hwnd)
    {
        return IsWindow(new IntPtr(hwnd));
    }

    public static long GetForegroundWindowHandle()
    {
        return GetForegroundWindow().ToInt64();
    }

    public static string GetForegroundWindowInfo()
    {
        return GetWindowInfoIntPtr(GetForegroundWindow());
    }

    // ---- geometry ------------------------------------------------------
    // Returns "x y width height" (physical pixels) of the window client area
    // in screen coordinates, or "" on failure.
    public static string GetClientScreenRect(long hwnd)
    {
        IntPtr h = new IntPtr(hwnd);
        RECT c;
        if (!GetClientRect(h, out c)) { return ""; }
        POINT p = new POINT();
        p.X = 0;
        p.Y = 0;
        if (!ClientToScreen(h, ref p)) { return ""; }
        int w = c.Right - c.Left;
        int hh = c.Bottom - c.Top;
        return p.X.ToString() + " " + p.Y.ToString() + " " + w.ToString() + " " + hh.ToString();
    }

    public static string GetScreenInfo()
    {
        return GetSystemMetrics(SM_XVIRTUALSCREEN).ToString() + " " +
               GetSystemMetrics(SM_YVIRTUALSCREEN).ToString() + " " +
               GetSystemMetrics(SM_CXVIRTUALSCREEN).ToString() + " " +
               GetSystemMetrics(SM_CYVIRTUALSCREEN).ToString() + " " +
               GetSystemMetrics(SM_CXSCREEN).ToString() + " " +
               GetSystemMetrics(SM_CYSCREEN).ToString();
    }

    public static int GetWindowDpi(long hwnd)
    {
        return (int)GetDpiForWindow(new IntPtr(hwnd));
    }

    // ---- foreground activation ----------------------------------------
    // Returns true when the target really is the foreground window.
    public static bool BringToForeground(long hwnd)
    {
        IntPtr h = new IntPtr(hwnd);
        if (!IsWindow(h)) { return false; }
        if (IsIconic(h)) { ShowWindow(h, SW_RESTORE); }
        ShowWindow(h, SW_SHOW);
        if (GetForegroundWindow() == h) { return true; }

        // A synthetic ALT tap clears the foreground-activation lock in most
        // non-interactive-parent scenarios (documented Windows behaviour).
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);

        uint fgPid = 0;
        uint targetPid = 0;
        IntPtr fg = GetForegroundWindow();
        uint fgThread = 0;
        if (fg != IntPtr.Zero) { fgThread = GetWindowThreadProcessId(fg, out fgPid); }
        uint targetThread = GetWindowThreadProcessId(h, out targetPid);
        uint myThread = GetCurrentThreadId();
        bool attachedFg = false;
        bool attachedTarget = false;
        try
        {
            if (fgThread != 0 && fgThread != myThread) { attachedFg = AttachThreadInput(myThread, fgThread, true); }
            if (targetThread != 0 && targetThread != myThread) { attachedTarget = AttachThreadInput(myThread, targetThread, true); }
            BringWindowToTop(h);
            SetWindowPos(h, IntPtr.Zero, 0, 0, 0, 0, SWP_NOSIZE | SWP_NOMOVE | SWP_SHOWWINDOW);
            SetForegroundWindow(h);
            SetActiveWindow(h);
        }
        finally
        {
            if (attachedTarget) { AttachThreadInput(myThread, targetThread, false); }
            if (attachedFg) { AttachThreadInput(myThread, fgThread, false); }
        }

        for (int i = 0; i < 40; i++)
        {
            if (GetForegroundWindow() == h) { return true; }
            if ((i % 10) == 9) { SetForegroundWindow(h); }
            Thread.Sleep(50);
        }
        return (GetForegroundWindow() == h);
    }

    // ---- mouse ---------------------------------------------------------
    public static bool ClickAt(int x, int y, bool right, int clicks)
    {
        if (!SetCursorPos(x, y)) { return false; }
        Thread.Sleep(80);
        POINT p = new POINT();
        if (!GetCursorPos(out p)) { return false; }
        if (Math.Abs(p.X - x) > 2 || Math.Abs(p.Y - y) > 2) { return false; }
        for (int i = 0; i < clicks; i++)
        {
            if (right)
            {
                mouse_event(MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, UIntPtr.Zero);
                Thread.Sleep(40);
                mouse_event(MOUSEEVENTF_RIGHTUP, 0, 0, 0, UIntPtr.Zero);
            }
            else
            {
                mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, UIntPtr.Zero);
                Thread.Sleep(40);
                mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, UIntPtr.Zero);
            }
            Thread.Sleep(60);
        }
        return true;
    }

    public static bool MoveCursor(int x, int y)
    {
        if (!SetCursorPos(x, y)) { return false; }
        Thread.Sleep(50);
        POINT p = new POINT();
        if (!GetCursorPos(out p)) { return false; }
        return (Math.Abs(p.X - x) <= 2 && Math.Abs(p.Y - y) <= 2);
    }

    // ---- keyboard ------------------------------------------------------
    private static bool TryParseVk(string token, out byte vk)
    {
        vk = 0;
        if (token == null) { return false; }
        string t = token.Trim().ToUpperInvariant();
        if (t.Length == 0) { return false; }
        switch (t)
        {
            case "CTRL": case "CONTROL": vk = 0x11; return true;
            case "SHIFT": vk = 0x10; return true;
            case "ALT": vk = 0x12; return true;
            case "WIN": case "LWIN": vk = 0x5B; return true;
            case "ESC": case "ESCAPE": vk = 0x1B; return true;
            case "ENTER": case "RETURN": vk = 0x0D; return true;
            case "TAB": vk = 0x09; return true;
            case "SPACE": vk = 0x20; return true;
            case "BACKSPACE": vk = 0x08; return true;
            case "DELETE": case "DEL": vk = 0x2E; return true;
            case "HOME": vk = 0x24; return true;
            case "END": vk = 0x23; return true;
            case "PAGEUP": vk = 0x21; return true;
            case "PAGEDOWN": vk = 0x22; return true;
            case "UP": vk = 0x26; return true;
            case "DOWN": vk = 0x28; return true;
            case "LEFT": vk = 0x25; return true;
            case "RIGHT": vk = 0x27; return true;
        }
        if (t.Length == 1 && t[0] >= 'A' && t[0] <= 'Z') { vk = (byte)t[0]; return true; }
        if (t.Length == 1 && t[0] >= '0' && t[0] <= '9') { vk = (byte)t[0]; return true; }
        if (t.Length >= 2 && t[0] == 'F')
        {
            int n;
            if (int.TryParse(t.Substring(1), out n) && n >= 1 && n <= 24) { vk = (byte)(0x6F + n); return true; }
        }
        return false;
    }

    private static bool SendInputKeyboard(byte[] vkDown, byte[] vkUp)
    {
        if (IntPtr.Size != 8) { return false; } // union layout below is x64-only
        int total = vkDown.Length + vkUp.Length;
        if (total == 0) { return false; }
        INPUT[] inputs = new INPUT[total];
        int idx = 0;
        for (int i = 0; i < vkDown.Length; i++)
        {
            inputs[idx].type = INPUT_KEYBOARD;
            inputs[idx].ki.wVk = vkDown[i];
            inputs[idx].ki.wScan = 0;
            inputs[idx].ki.dwFlags = 0;
            inputs[idx].ki.time = 0;
            inputs[idx].ki.dwExtraInfo = IntPtr.Zero;
            idx++;
        }
        for (int i = 0; i < vkUp.Length; i++)
        {
            inputs[idx].type = INPUT_KEYBOARD;
            inputs[idx].ki.wVk = vkUp[i];
            inputs[idx].ki.wScan = 0;
            inputs[idx].ki.dwFlags = KEYEVENTF_KEYUP;
            inputs[idx].ki.time = 0;
            inputs[idx].ki.dwExtraInfo = IntPtr.Zero;
            idx++;
        }
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
        return sent == (uint)inputs.Length;
    }

    // combo is e.g. "CTRL+SHIFT+T" or "ESC" (case-insensitive).
    public static bool SendKeyCombo(string combo)
    {
        if (combo == null) { return false; }
        string[] parts = combo.Split('+');
        List<byte> vks = new List<byte>();
        for (int i = 0; i < parts.Length; i++)
        {
            byte vk;
            if (!TryParseVk(parts[i], out vk)) { return false; }
            vks.Add(vk);
        }
        if (vks.Count == 0) { return false; }
        byte[] down = vks.ToArray();
        // release in reverse order
        byte[] up = new byte[down.Length];
        for (int i = 0; i < down.Length; i++) { up[i] = down[down.Length - 1 - i]; }

        bool ok = SendInputKeyboard(down, up);
        if (!ok)
        {
            // Legacy fallback (32-bit hosts or unusual desktops).
            for (int i = 0; i < down.Length; i++)
            {
                keybd_event(down[i], 0, 0, UIntPtr.Zero);
                Thread.Sleep(25);
            }
            Thread.Sleep(40);
            for (int i = 0; i < up.Length; i++)
            {
                keybd_event(up[i], 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
                Thread.Sleep(25);
            }
        }
        Thread.Sleep(80);
        return true;
    }

    // ---- screenshot support -------------------------------------------
    public static bool PrintWindowCapture(long hwnd, IntPtr hdc, uint flags)
    {
        return PrintWindow(new IntPtr(hwnd), hdc, flags);
    }
}
'@
    Add-Type -TypeDefinition $script:TyUiNativeSource -Language CSharp
}

# ===========================================================================
# PowerShell helpers
# ===========================================================================
$script:WinUiState = @{
    Initialized = $false
    DrawingLoaded = $false
    ScreenInfo  = $null
}

function Initialize-WinUi {
    <# Loads the native layer plus System.Drawing and records screen metrics. #>
    [CmdletBinding()]
    param()

    if (-not ('TyUiNative' -as [type])) {
        throw "TyUiNative native layer is not loaded - win-ui.ps1 was not dot-sourced correctly."
    }
    if (-not $script:WinUiState.DrawingLoaded) {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $script:WinUiState.DrawingLoaded = $true
    }
    $script:WinUiState.ScreenInfo = [TyUiNative]::GetScreenInfo()
    $script:WinUiState.Initialized = $true
    return $true
}

function Get-ScreenInfo {
    <# Returns virtual-screen and primary-screen metrics in physical pixels. #>
    [CmdletBinding()]
    param()
    $raw = [TyUiNative]::GetScreenInfo()
    $p = $raw -split ' '
    if ($p.Count -lt 6) { throw "Unexpected screen info: $raw" }
    return [pscustomobject]@{
        VirtualLeft   = [int]$p[0]
        VirtualTop    = [int]$p[1]
        VirtualWidth  = [int]$p[2]
        VirtualHeight = [int]$p[3]
        PrimaryWidth  = [int]$p[4]
        PrimaryHeight = [int]$p[5]
    }
}

function Convert-WindowLine {
    <# Parses one native window description line into a typed object. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $f = $Line -split "`t"
    if ($f.Count -lt 10) { return $null }
    return [pscustomobject]@{
        Hwnd        = [IntPtr][long]$f[0]
        ProcessId   = [int]$f[1]
        Visible     = ($f[2] -eq '1')
        Iconic      = ($f[3] -eq '1')
        ClassName   = $f[4]
        Title       = $f[5]
        Left        = [int]$f[6]
        Top         = [int]$f[7]
        Right       = [int]$f[8]
        Bottom      = [int]$f[9]
        Width       = ([int]$f[8] - [int]$f[6])
        Height      = ([int]$f[9] - [int]$f[7])
    }
}

function Get-WindowInfoList {
    <#
      Enumerate top-level windows.  -ProcessId filters to those process ids.
      Returns an array of window objects (possibly empty).
    #>
    [CmdletBinding()]
    param([int[]]$ProcessId = @())

    $raw = [TyUiNative]::EnumWindowsInfo(0)
    $result = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    foreach ($line in ($raw -split "`n")) {
        # The native layer appends a trailing newline; skip empty fragments.
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $info = Convert-WindowLine -Line $line
        if ($null -eq $info) { continue }
        if ($ProcessId.Count -gt 0 -and ($ProcessId -notcontains $info.ProcessId)) { continue }
        [void]$result.Add($info)
    }
    return @($result.ToArray())
}

function Get-WindowInfo {
    <# Describe a single window handle; returns $null when the hwnd is gone. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
    $line = [TyUiNative]::GetWindowInfo($Hwnd.ToInt64())
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    return Convert-WindowLine -Line $line
}

function Find-TyporaMainWindow {
    <#
      Pick Typora's real main top-level window from the window list.
      A Typora main window is a visible top-level window of a Typora.exe
      process, typical class Chrome_WidgetWin_1, wide/tall enough to be the
      editor (helper/IME windows are tiny).
      When -TitlePattern is supplied, windows whose title matches it win.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int[]]$ProcessId,
        [string]$TitlePattern = '',
        [int]$MinWidth = 300,
        [int]$MinHeight = 200
    )

    $candidates = @(Get-WindowInfoList -ProcessId $ProcessId | Where-Object {
            $_.Visible -and -not $_.Iconic -and
            $_.Width -ge $MinWidth -and $_.Height -ge $MinHeight -and
            $_.ClassName -like 'Chrome_WidgetWin*'
        })
    if ($candidates.Count -eq 0) {
        # Fall back to any sizeable visible window owned by these processes.
        $candidates = @(Get-WindowInfoList -ProcessId $ProcessId | Where-Object {
                $_.Visible -and -not $_.Iconic -and $_.Width -ge $MinWidth -and $_.Height -ge $MinHeight
            })
    }
    if ($candidates.Count -eq 0) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($TitlePattern)) {
        $matching = @($candidates | Where-Object { $_.Title -match $TitlePattern })
        if ($matching.Count -gt 0) { return $matching[0] }
    }
    # Prefer the largest window when several exist.
    $sorted = @($candidates | Sort-Object -Property @{ Expression = { $_.Width * $_.Height } } -Descending)
    return $sorted[0]
}

function Set-WindowForeground {
    <# Activate a window and verify it owns the foreground. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
    return [TyUiNative]::BringToForeground($Hwnd.ToInt64())
}

function Get-ForegroundWindowInfo {
    [CmdletBinding()]
    param()
    $line = [TyUiNative]::GetForegroundWindowInfo()
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    return Convert-WindowLine -Line $line
}

function Get-ClientScreenRect {
    <# Client-area rectangle of a window in physical screen coordinates. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][IntPtr]$Hwnd)
    $raw = [TyUiNative]::GetClientScreenRect($Hwnd.ToInt64())
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $p = $raw -split ' '
    if ($p.Count -lt 4) { return $null }
    return [pscustomobject]@{
        X      = [int]$p[0]
        Y      = [int]$p[1]
        Width  = [int]$p[2]
        Height = [int]$p[3]
    }
}

function Invoke-ClientClick {
    <#
      Click inside a window's client area using fractional coordinates
      (0.0-1.0).  Example: -RelativeX 0.5 -RelativeY 0.5 clicks the centre.
      -Button Left|Right.  Returns $true when the click was injected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [ValidateRange(0.0, 1.0)][double]$RelativeX = 0.5,
        [ValidateRange(0.0, 1.0)][double]$RelativeY = 0.5,
        [ValidateSet('Left', 'Right')][string]$Button = 'Left',
        [int]$Count = 1
    )
    $rect = Get-ClientScreenRect -Hwnd $Hwnd
    if ($null -eq $rect -or $rect.Width -le 0 -or $rect.Height -le 0) { return $false }
    $x = [int]($rect.X + [Math]::Round(($rect.Width - 1) * $RelativeX))
    $y = [int]($rect.Y + [Math]::Round(($rect.Height - 1) * $RelativeY))
    $isRight = ($Button -eq 'Right')
    return [TyUiNative]::ClickAt($x, $y, $isRight, $Count)
}

function Send-KeyChord {
    <# Send a key chord such as 'CTRL+SHIFT+T', 'CTRL+A' or 'ESC'. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Chord)
    return [TyUiNative]::SendKeyCombo($Chord)
}

function Test-ContainsCjk {
    <# True when the string contains CJK Unified Ideographs. #>
    [CmdletBinding()]
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [bool]([regex]::IsMatch($Text, '[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]'))
}

function Wait-Until {
    <#
      Poll -Condition until it returns truthy or -TimeoutSec elapses.
      Returns $true/$false.  Exceptions inside the condition are swallowed
      (the last error is available via -Verbose output).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$TimeoutSec = 30,
        [int]$IntervalMs = 250,
        [string]$Description = 'condition'
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = $null
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        try {
            $value = & $Condition
            if ($value) {
                Write-Verbose ("Wait-Until '{0}' satisfied after {1:N1}s" -f $Description, $sw.Elapsed.TotalSeconds)
                return $true
            }
        }
        catch {
            $lastError = $_
        }
        Start-Sleep -Milliseconds $IntervalMs
    }
    if ($lastError) {
        Write-Verbose ("Wait-Until '{0}' timed out; last error: {1}" -f $Description, $lastError.Exception.Message)
    }
    else {
        Write-Verbose ("Wait-Until '{0}' timed out after {1}s" -f $Description, $TimeoutSec)
    }
    return $false
}

# ---------------------------------------------------------------------------
# File helpers (plugin writes status.json / plugin.log from another process)
# ---------------------------------------------------------------------------
function Read-TextFileShared {
    <#
      Read a whole text file even while another process keeps it open for
      appending (uses FileShare.ReadWrite).  Returns $null when unreadable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Retries = 4
    )
    for ($attempt = 0; $attempt -lt $Retries; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return $null }
        $stream = $null
        $reader = $null
        try {
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            return $reader.ReadToEnd()
        }
        catch {
            if ($attempt -eq ($Retries - 1)) { return $null }
            Start-Sleep -Milliseconds 150
        }
        finally {
            if ($reader) { $reader.Dispose() }
            elseif ($stream) { $stream.Dispose() }
        }
    }
    return $null
}

function Read-JsonFileShared {
    <#
      Tolerant JSON read: returns $null while the file is missing, empty or
      half-written.  Sets $script:LastJsonError for diagnostics.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:LastJsonError = $null
    $text = Read-TextFileShared -Path $Path
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        $script:LastJsonError = $_.Exception.Message
        return $null
    }
}

function Read-LogNewLines {
    <#
      Incremental log tail.  Returns an object with:
        FromIndex  - number of lines already consumed (input -FromIndex)
        ToIndex    - number of lines after this read
        Lines      - string[] of new lines only
        Text       - the same new lines joined with newlines
        Path       - the file path
      Reading a missing/short file is safe (returns zero new lines).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$FromIndex = 0
    )
    $text = Read-TextFileShared -Path $Path
    if ($null -eq $text) {
        return [pscustomobject]@{ FromIndex = $FromIndex; ToIndex = $FromIndex; Lines = @(); Text = ''; Path = $Path; Exists = (Test-Path -LiteralPath $Path) }
    }
    if ($text.Length -eq 0) {
        return [pscustomobject]@{ FromIndex = $FromIndex; ToIndex = $FromIndex; Lines = @(); Text = ''; Path = $Path; Exists = $true }
    }
    $all = @($text -split "`r?`n")
    # A trailing newline yields an empty final element; do not count it.
    if ($all.Count -gt 0 -and $all[$all.Count - 1] -eq '') { $all = @($all[0..($all.Count - 2)]) }
    $total = $all.Count
    $start = [Math]::Min([Math]::Max($FromIndex, 0), $total)
    if ($start -ge $total) {
        return [pscustomobject]@{ FromIndex = $total; ToIndex = $total; Lines = @(); Text = ''; Path = $Path; Exists = $true }
    }
    $new = @($all[$start..($total - 1)])
    return [pscustomobject]@{
        FromIndex = $start
        ToIndex   = $total
        Lines     = $new
        Text      = ($new -join "`n")
        Path      = $Path
        Exists    = $true
    }
}

function ConvertTo-UtcDateTime {
    <#
      Normalise plugin timestamps (ISO-8601 string, epoch ms/second number,
      or DateTime) to a UTC DateTime.  Returns $null when unparseable.
    #>
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $number = 0.0
    if ([double]::TryParse($text, [ref]$number)) {
        # Heuristic: 1e12-ish -> milliseconds, 1e9-ish -> seconds.
        if ($number -gt 100000000000) { return [DateTime]::UnixEpoch.AddMilliseconds($number) }
        if ($number -gt 1000000000) { return [DateTime]::UnixEpoch.AddSeconds($number) }
        return $null
    }
    try {
        $dto = [DateTimeOffset]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture)
        return $dto.UtcDateTime
    }
    catch {
        try {
            return [DateTime]::Parse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        }
        catch { return $null }
    }
}

# ---------------------------------------------------------------------------
# Process helpers (safety: only ever kill verified, harness-launched trees)
# ---------------------------------------------------------------------------
function Get-ProcessTreeIds {
    <# Returns the root process id plus every descendant process id. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$RootId)
    $result = New-Object System.Collections.Generic.List[int]
    $all = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) {
        $result.Add($RootId)
        return @($result.ToArray())
    }
    $children = @{}
    foreach ($p in $all) {
        $parent = [int]$p.ParentProcessId
        if (-not $children.ContainsKey($parent)) { $children[$parent] = New-Object System.Collections.Generic.List[int] }
        $children[$parent].Add([int]$p.ProcessId)
    }
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    $seen = New-Object System.Collections.Generic.HashSet[int]
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if (-not $seen.Add($cur)) { continue }
        $result.Add($cur)
        if ($children.ContainsKey($cur)) {
            foreach ($child in $children[$cur]) {
                if (-not $seen.Contains($child)) { $queue.Enqueue($child) }
            }
        }
    }
    return @($result.ToArray())
}

function Stop-ProcessTree {
    <#
      Kill a process tree, but only after verifying it is the exact process we
      recorded (same executable path, and start time within -StartTimeToleranceSec).
      This is the guard that prevents the harness from ever closing a user's
      Typora instance by accident.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$ExpectedPath = '',
        [datetime]$ExpectedStartUtc,
        [int]$StartTimeToleranceSec = 20,
        [switch]$DryRun
    )

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $proc) { return [pscustomobject]@{ Killed = $false; Reason = 'process-not-running'; ProcessId = $ProcessId } }

    if ($ExpectedPath) {
        $actualPath = $null
        try { $actualPath = $proc.Path } catch { $actualPath = $null }
        if ($actualPath -and ($actualPath -ne $ExpectedPath)) {
            throw ("Refusing to stop PID {0}: executable path '{1}' does not match expected '{2}'." -f $ProcessId, $actualPath, $ExpectedPath)
        }
    }
    if ($ExpectedStartUtc -ne [datetime]::MinValue) {
        $delta = [Math]::Abs(($proc.StartTime.ToUniversalTime() - $ExpectedStartUtc).TotalSeconds)
        if ($delta -gt $StartTimeToleranceSec) {
            throw ("Refusing to stop PID {0}: start time differs by {1:N0}s (PID reuse guard)." -f $ProcessId, $delta)
        }
    }

    $ids = @(Get-ProcessTreeIds -RootId $ProcessId)
    if ($DryRun) {
        return [pscustomobject]@{ Killed = $false; DryRun = $true; ProcessId = $ProcessId; TreeIds = $ids; Reason = 'dry-run' }
    }

    # Force-kill via .NET Kill() instead of shelling out to taskkill: a native
    # command writing to stderr while $ErrorActionPreference is 'Stop' raises a
    # terminating NativeCommandError in Windows PowerShell 5.1 (taskkill reports
    # "process not found" for children that were already terminated as part of
    # the tree), which previously produced false cleanup failures.
    # Three passes catch helper processes spawned while the tree is torn down.
    $allIds = New-Object System.Collections.Generic.HashSet[int]
    for ($pass = 0; $pass -lt 3; $pass++) {
        $passIds = @(Get-ProcessTreeIds -RootId $ProcessId)
        if ($passIds.Count -eq 0) { break }
        $alive = @($passIds | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
        if ($alive.Count -eq 0) { break }
        foreach ($id in $alive) {
            [void]$allIds.Add([int]$id)
            $p = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($null -ne $p) { try { $p.Kill() } catch { } }
        }
        Start-Sleep -Milliseconds 200
    }
    $gone = Wait-Until -TimeoutSec 15 -IntervalMs 200 -Description "PID $ProcessId exit" -Condition { -not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) }

    if (-not $gone) {
        # Fallback for stubborn processes: taskkill /T with output fully
        # redirected through .NET (never through the PowerShell error stream).
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            $psi.FileName = $taskkill
            $psi.Arguments = ('/PID ' + $ProcessId + ' /T /F')
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $fallback = [System.Diagnostics.Process]::Start($psi)
            if (-not $fallback.WaitForExit(5000)) { try { $fallback.Kill() } catch { } }
        }
        catch { }
        $gone = Wait-Until -TimeoutSec 10 -IntervalMs 200 -Description "PID $ProcessId exit (taskkill fallback)" -Condition { -not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) }
    }

    return [pscustomobject]@{
        Killed    = $gone
        ProcessId = $ProcessId
        TreeIds   = @($allIds | Sort-Object)
        Reason    = if ($gone) { 'stopped' } else { 'still-running' }
    }
}

# ---------------------------------------------------------------------------
# Screenshot support (System.Drawing; PrintWindow then screen fallback)
# ---------------------------------------------------------------------------
function Get-BitmapPixelStats {
    <#
      Analyse a bitmap for "is this frame blank?" using a down-scaled sample.
      Returns object with Width Height UniqueColors MinLum MaxLum MeanLum Blank.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Drawing.Bitmap]$Bitmap)

    $width = $Bitmap.Width
    $height = $Bitmap.Height
    $sampleW = 96
    $sampleH = 96
    $thumb = New-Object System.Drawing.Bitmap($sampleW, $sampleH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($thumb)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($Bitmap, 0, 0, $sampleW, $sampleH)
    }
    finally {
        if ($graphics) { $graphics.Dispose() }
    }

    $colors = New-Object 'System.Collections.Generic.HashSet[int]'
    $count = 0
    $minLum = 255.0
    $maxLum = 0.0
    $sum = 0.0
    try {
        for ($y = 0; $y -lt $sampleH; $y += 2) {
            for ($x = 0; $x -lt $sampleW; $x += 2) {
                $c = $thumb.GetPixel($x, $y)
                $key = (([int]$c.R) -shl 16) -bor (([int]$c.G) -shl 8) -bor ([int]$c.B)
                [void]$colors.Add($key)
                $lum = 0.299 * $c.R + 0.587 * $c.G + 0.114 * $c.B
                if ($lum -lt $minLum) { $minLum = $lum }
                if ($lum -gt $maxLum) { $maxLum = $lum }
                $sum += $lum
                $count++
            }
        }
    }
    finally {
        $thumb.Dispose()
    }
    if ($count -eq 0) { $count = 1 }
    $mean = $sum / $count
    $blank = ($colors.Count -le 2) -or (($maxLum - $minLum) -lt 4.0)
    return [pscustomobject]@{
        Width        = $width
        Height       = $height
        UniqueColors = $colors.Count
        MinLum       = [Math]::Round($minLum, 1)
        MaxLum       = [Math]::Round($maxLum, 1)
        MeanLum      = [Math]::Round($mean, 1)
        Blank        = [bool]$blank
    }
}

function Get-ImageStats {
    <# Analyse an existing PNG file (used to double-check saved evidence). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $bmp = $null
    try {
        $bmp = New-Object System.Drawing.Bitmap($Path)
        return (Get-BitmapPixelStats -Bitmap $bmp)
    }
    finally {
        if ($bmp) { $bmp.Dispose() }
    }
}

function Get-ImageDifference {
    <#
      Estimate how much two PNGs differ (used as UI-appearance evidence, e.g.
      before/after a floating panel opens).  Both images are down-scaled to a
      common 96x96 grid; the result is the fraction of sampled pixels whose
      channel delta exceeds -ChannelThreshold.
      Returns an object { Ratio DiffPixels TotalPixels MeanDelta } or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PathA,
        [Parameter(Mandatory = $true)][string]$PathB,
        [int]$ChannelThreshold = 24
    )
    if (-not (Test-Path -LiteralPath $PathA) -or -not (Test-Path -LiteralPath $PathB)) { return $null }
    $sampleW = 96
    $sampleH = 96
    $bmpA = $null
    $bmpB = $null
    $thumbA = $null
    $thumbB = $null
    try {
        $bmpA = New-Object System.Drawing.Bitmap($PathA)
        $bmpB = New-Object System.Drawing.Bitmap($PathB)
        $thumbA = New-Object System.Drawing.Bitmap($sampleW, $sampleH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $thumbB = New-Object System.Drawing.Bitmap($sampleW, $sampleH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gA = [System.Drawing.Graphics]::FromImage($thumbA)
        $gB = [System.Drawing.Graphics]::FromImage($thumbB)
        try {
            $gA.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
            $gB.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
            $gA.DrawImage($bmpA, 0, 0, $sampleW, $sampleH)
            $gB.DrawImage($bmpB, 0, 0, $sampleW, $sampleH)
        }
        finally {
            $gA.Dispose()
            $gB.Dispose()
        }
        $diff = 0
        $total = 0
        $sumDelta = 0.0
        for ($y = 0; $y -lt $sampleH; $y += 2) {
            for ($x = 0; $x -lt $sampleW; $x += 2) {
                $ca = $thumbA.GetPixel($x, $y)
                $cb = $thumbB.GetPixel($x, $y)
                $dr = [Math]::Abs([int]$ca.R - [int]$cb.R)
                $dg = [Math]::Abs([int]$ca.G - [int]$cb.G)
                $db = [Math]::Abs([int]$ca.B - [int]$cb.B)
                $delta = [Math]::Max($dr, [Math]::Max($dg, $db))
                if ($delta -ge $ChannelThreshold) { $diff++ }
                $sumDelta += $delta
                $total++
            }
        }
        if ($total -eq 0) { $total = 1 }
        return [pscustomobject]@{
            Ratio       = [Math]::Round($diff / $total, 4)
            DiffPixels  = $diff
            TotalPixels = $total
            MeanDelta   = [Math]::Round($sumDelta / $total, 1)
        }
    }
    catch {
        return $null
    }
    finally {
        if ($thumbA) { $thumbA.Dispose() }
        if ($thumbB) { $thumbB.Dispose() }
        if ($bmpA) { $bmpA.Dispose() }
        if ($bmpB) { $bmpB.Dispose() }
    }
}

function Save-WindowScreenshot {
    <#
      Capture a window to PNG.
      Mode Auto (default): try PrintWindow(PW_RENDERFULLCONTENT); if the frame
      is blank/black, fall back to CopyFromScreen over the window rectangle
      (window is brought to the foreground first).
      Mode PrintWindow / Screen force one path.
      Returns an object with Path Width Height UniqueColors Blank Mode
      (Blank is $true when both attempts produced a blank frame - the caller
      must treat that as failure).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][IntPtr]$Hwnd,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Auto', 'PrintWindow', 'Screen')][string]$Mode = 'Auto',
        [switch]$ForceForeground,
        [uint32]$PrintWindowFlags = 0x00000002
    )
    if (-not ('TyUiNative' -as [type])) { throw 'win-ui.ps1 not initialized' }
    if (-not $script:WinUiState.DrawingLoaded) { Add-Type -AssemblyName System.Drawing -ErrorAction Stop; $script:WinUiState.DrawingLoaded = $true }

    $info = Get-WindowInfo -Hwnd $Hwnd
    if ($null -eq $info) { throw ("Window 0x{0:X} no longer exists." -f $Hwnd.ToInt64()) }
    $width = $info.Width
    $height = $info.Height
    if ($width -le 0 -or $height -le 0) { throw ("Window 0x{0:X} has invalid size {1}x{2}." -f $Hwnd.ToInt64(), $width, $height) }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Force -Path $dir
    }

    $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = $null
    $modeUsed = $null
    $stats = $null
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)

        $printWindowTried = $false
        $printWindowOk = $false
        if ($Mode -ne 'Screen') {
            $printWindowTried = $true
            $hdc = [IntPtr]::Zero
            try {
                $hdc = $graphics.GetHdc()
                $printWindowOk = [TyUiNative]::PrintWindowCapture($Hwnd.ToInt64(), $hdc, $PrintWindowFlags)
            }
            finally {
                if ($hdc -ne [IntPtr]::Zero) { $graphics.ReleaseHdc($hdc) }
            }
            if ($printWindowOk) {
                $stats = Get-BitmapPixelStats -Bitmap $bitmap
                if (-not $stats.Blank) { $modeUsed = 'PrintWindow' }
            }
        }

        if ($null -eq $modeUsed -and $Mode -ne 'PrintWindow') {
            # Screen grab fallback: foreground the window so it is not occluded.
            if ($ForceForeground -or $printWindowTried) {
                $null = Set-WindowForeground -Hwnd $Hwnd
                Start-Sleep -Milliseconds 250
            }
            $graphics.Clear([System.Drawing.Color]::FromArgb(255, 0, 0, 0))
            $screen = Get-ScreenInfo
            $srcLeft = [Math]::Max($info.Left, $screen.VirtualLeft)
            $srcTop = [Math]::Max($info.Top, $screen.VirtualTop)
            $srcRight = [Math]::Min($info.Right, $screen.VirtualLeft + $screen.VirtualWidth)
            $srcBottom = [Math]::Min($info.Bottom, $screen.VirtualTop + $screen.VirtualHeight)
            $copyW = $srcRight - $srcLeft
            $copyH = $srcBottom - $srcTop
            if ($copyW -le 0 -or $copyH -le 0) {
                $stats = Get-BitmapPixelStats -Bitmap $bitmap
                $modeUsed = 'None'
            }
            else {
                $destX = $srcLeft - $info.Left
                $destY = $srcTop - $info.Top
                $graphics.CopyFromScreen($srcLeft, $srcTop, $destX, $destY, (New-Object System.Drawing.Size($copyW, $copyH)))
                $stats = Get-BitmapPixelStats -Bitmap $bitmap
                $modeUsed = 'Screen'
            }
        }
        elseif ($null -eq $modeUsed) {
            if ($null -eq $stats) { $stats = Get-BitmapPixelStats -Bitmap $bitmap }
            $modeUsed = 'None'
        }

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        if ($graphics) { $graphics.Dispose() }
        $bitmap.Dispose()
    }

    $blank = $true
    if ($stats) { $blank = $stats.Blank }
    return [pscustomobject]@{
        Path         = $Path
        Width        = $width
        Height       = $height
        UniqueColors = if ($stats) { $stats.UniqueColors } else { 0 }
        MinLum       = if ($stats) { $stats.MinLum } else { 0 }
        MaxLum       = if ($stats) { $stats.MaxLum } else { 0 }
        MeanLum      = if ($stats) { $stats.MeanLum } else { 0 }
        Blank        = [bool]$blank
        Mode         = $modeUsed
        PrintWindow  = [bool]$printWindowOk
    }
}