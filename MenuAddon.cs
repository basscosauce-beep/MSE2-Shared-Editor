// MSE2 Menu Addon - Adds "Account Settings" and "Goals" to MSE2 menu bar at runtime
// Handles MSE2's window handle changing when sets are opened/closed
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

class MSEMenuAddon {
    const uint MF_STRING    = 0x00000000;
    const uint MF_SEPARATOR = 0x00000800;
    const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    const uint EVENT_OBJECT_INVOKED  = 0x8013;
    const uint SETTINGS_ID  = 9876;
    const uint GOALS_ID     = 9877;
    const uint SYNC_ID      = 9878;

    delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd,
                               int idObject, int idChild, uint thread, uint time);

    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int    GetMenuItemCount(IntPtr hMenu);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool   AppendMenu(IntPtr hMenu, uint uFlags, uint uID, string text);
    [DllImport("user32.dll")] static extern bool   DrawMenuBar(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint   GetMenuItemID(IntPtr hMenu, int nPos);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint evMin, uint evMax, IntPtr hMod,
                               WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool   UnhookWinEvent(IntPtr hook);

    static string settingsScriptPath = "";
    static string goalsScriptPath = "";
    static string syncScriptPath = "";
    static IntPtr hookHandle = IntPtr.Zero;
    static WinEventProc del; // prevent GC

    static void Main(string[] args) {
        if (args.Length > 0) settingsScriptPath = args[0];
        if (args.Length > 1) goalsScriptPath = args[1];
        if (args.Length > 2) syncScriptPath = args[2];

        // Install WinEvent hook immediately (catches clicks across all window handles)
        del = OnWinEvent;
        hookHandle = SetWinEventHook(EVENT_OBJECT_INVOKED, EVENT_OBJECT_INVOKED,
                                     IntPtr.Zero, del, 0, 0, WINEVENT_OUTOFCONTEXT);

        // Monitor MSE2 in background thread - re-inject menu whenever handle changes
        IntPtr lastInjectedHwnd = IntPtr.Zero;
        var monitor = new Thread(() => {
            while (true) {
                Thread.Sleep(1000);
                var procs = Process.GetProcessesByName("magicseteditor");
                if (procs.Length == 0) { Application.Exit(); return; }
                var hwnd = procs[0].MainWindowHandle;
                if (hwnd != IntPtr.Zero && hwnd != lastInjectedHwnd) {
                    InjectMenu(hwnd);
                    lastInjectedHwnd = hwnd;
                }
            }
        });
        monitor.IsBackground = true;
        monitor.Start();

        Application.Run();
        if (hookHandle != IntPtr.Zero) UnhookWinEvent(hookHandle);
    }

    static void InjectMenu(IntPtr hwnd) {
        var hMenu = GetMenu(hwnd);
        if (hMenu == IntPtr.Zero) return;

        // Check if already injected (don't double-add)
        int count = GetMenuItemCount(hMenu);
        for (int i = 0; i < count; i++) {
            if (GetMenuItemID(hMenu, i) == SETTINGS_ID) return;
        }

        AppendMenu(hMenu, MF_SEPARATOR, 0, null);
        AppendMenu(hMenu, MF_STRING, 9999, "v1.0.5");
        AppendMenu(hMenu, MF_STRING, SYNC_ID, "\uD83D\uDD04 Sync Now");
        AppendMenu(hMenu, MF_STRING, GOALS_ID, "\uD83D\uDCCA Goals");
        AppendMenu(hMenu, MF_STRING, SETTINGS_ID, "\u2699 Account");
        DrawMenuBar(hwnd);
    }

    static void OnWinEvent(IntPtr hook, uint eventType, IntPtr hwnd,
                           int idObject, int idChild, uint thread, uint time) {
        if ((uint)idChild == SETTINGS_ID && settingsScriptPath != "") {
            var t = new Thread(() => {
                Thread.Sleep(300);
                Process.Start("wscript.exe", "\"" + settingsScriptPath + "\"");
            });
            t.IsBackground = true;
            t.Start();
        } else if ((uint)idChild == GOALS_ID && goalsScriptPath != "") {
            var t = new Thread(() => {
                Thread.Sleep(300);
                Process.Start("wscript.exe", "\"" + goalsScriptPath + "\"");
            });
            t.IsBackground = true;
            t.Start();
        } else if ((uint)idChild == SYNC_ID && syncScriptPath != "") {
            var t = new Thread(() => {
                Thread.Sleep(300);
                Process.Start("wscript.exe", "\"" + syncScriptPath + "\"");
            });
            t.IsBackground = true;
            t.Start();
        }
    }
}
