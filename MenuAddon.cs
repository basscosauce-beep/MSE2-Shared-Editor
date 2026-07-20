// MSE2 Menu Addon - Adds "Account Settings" to the MSE2 menu bar at runtime
// Compiled with: csc.exe MenuAddon.cs /r:System.Windows.Forms.dll
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

class MSEMenuAddon {
    const uint MF_STRING       = 0x00000000;
    const uint MF_SEPARATOR    = 0x00000800;
    const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    const uint EVENT_OBJECT_INVOKED  = 0x8013;
    const uint SETTINGS_ID     = 9876;

    delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr hwnd,
                               int idObject, int idChild, uint thread, uint time);

    [DllImport("user32.dll")] static extern IntPtr GetMenu(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool   AppendMenu(IntPtr hMenu, uint uFlags, uint uID, string text);
    [DllImport("user32.dll")] static extern bool   DrawMenuBar(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint evMin, uint evMax, IntPtr hMod,
                               WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool   UnhookWinEvent(IntPtr hook);

    static IntPtr mseHwnd   = IntPtr.Zero;
    static string scriptPath = "";
    static WinEventProc del; // prevent GC collection

    static void Main(string[] args) {
        if (args.Length > 0) scriptPath = args[0];

        // Wait up to 30s for MSE2 window to appear
        for (int i = 0; i < 60; i++) {
            foreach (var p in Process.GetProcessesByName("magicseteditor")) {
                p.Refresh();
                if (p.MainWindowHandle != IntPtr.Zero) { mseHwnd = p.MainWindowHandle; break; }
            }
            if (mseHwnd != IntPtr.Zero) break;
            Thread.Sleep(500);
        }
        if (mseHwnd == IntPtr.Zero) return;

        // Add separator + "⚙ Account Settings" to the menu bar
        IntPtr hMenuBar = GetMenu(mseHwnd);
        AppendMenu(hMenuBar, MF_SEPARATOR, 0, null);
        AppendMenu(hMenuBar, MF_STRING, SETTINGS_ID, "\u2699 Account");
        DrawMenuBar(mseHwnd);

        // Hook for menu item invocations (no DLL needed with OUTOFCONTEXT flag)
        del = OnWinEvent;
        IntPtr hookHandle = SetWinEventHook(EVENT_OBJECT_INVOKED, EVENT_OBJECT_INVOKED,
                                            IntPtr.Zero, del, 0, 0, WINEVENT_OUTOFCONTEXT);

        // Exit when MSE2 closes
        var mseProc = Array.Find(Process.GetProcessesByName("magicseteditor"), p => p.MainWindowHandle == mseHwnd);
        if (mseProc != null) {
            mseProc.EnableRaisingEvents = true;
            mseProc.Exited += (s, e) => Application.Exit();
        }

        Application.Run(); // message pump - required for WinEvent callbacks
        UnhookWinEvent(hookHandle);
    }

    static void OnWinEvent(IntPtr hook, uint eventType, IntPtr hwnd,
                           int idObject, int idChild, uint thread, uint time) {
        // Menu item clicks: idChild == the menu item's command ID
        if ((uint)idChild == SETTINGS_ID) {
            Process.Start("wscript.exe", "\"" + scriptPath + "\"");
        }
    }
}
