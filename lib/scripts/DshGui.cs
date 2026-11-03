using System;
using System.Text;
using System.Drawing;
using System.Drawing.Imaging;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// Native wrapper for mouse / keyboard / window / cursor.
// Compiled to .build\DshGui.dll and loaded by GuiControl.ps1.
// Keep this file ASCII-only: Windows PowerShell 5.1 may read sources as ANSI.
public static class DshGui
{
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    public struct INPUT
    {
        [FieldOffset(0)] public uint type;
        [FieldOffset(8)] public MOUSEINPUT mi;
        [FieldOffset(8)] public KEYBDINPUT ki;
    }

    public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
    public const uint MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004,
        RIGHTDOWN = 0x0008, RIGHTUP = 0x0010, MIDDLEDOWN = 0x0020, MIDDLEUP = 0x0040,
        WHEEL = 0x0800, HWHEEL = 0x1000, ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;
    public const uint KEYUP = 0x0002, UNICODE = 0x0004;

    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool alt);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);

    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);

    public static int Init()
    {
        try { SetProcessDPIAware(); } catch { }
        return Marshal.SizeOf(typeof(INPUT));
    }

    public static void MoveAbs(int x, int y)
    {
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        if (vw <= 0 || vh <= 0) { vw = GetSystemMetrics(0); vh = GetSystemMetrics(1); vx = 0; vy = 0; }
        long nx = (long)(x - vx) * 65535 / Math.Max(1, vw - 1);
        long ny = (long)(y - vy) * 65535 / Math.Max(1, vh - 1);
        INPUT[] a = new INPUT[1];
        a[0].type = INPUT_MOUSE;
        a[0].mi.dx = (int)Math.Round((double)nx);
        a[0].mi.dy = (int)Math.Round((double)ny);
        a[0].mi.dwFlags = MOVE | ABSOLUTE | VIRTUALDESK;
        SendInput(1, a, 40);
    }

    public static void Mouse(uint flag, int data)
    {
        INPUT[] a = new INPUT[1];
        a[0].type = INPUT_MOUSE;
        a[0].mi.dwFlags = flag;
        a[0].mi.mouseData = (uint)data;
        SendInput(1, a, 40);
    }

    // Named ScrollWheel, not Wheel: a public const WHEEL already exists and PowerShell
    // resolves members case-insensitively, so Wheel() would be shadowed by the field.
    public static void ScrollWheel(int delta)
    {
        INPUT[] a = new INPUT[1];
        a[0].type = INPUT_MOUSE;
        a[0].mi.dwFlags = WHEEL;
        a[0].mi.mouseData = (uint)delta;
        SendInput(1, a, 40);
    }

    public static void Key(ushort vk, bool up)
    {
        INPUT[] a = new INPUT[1];
        a[0].type = INPUT_KEYBOARD;
        a[0].ki.wVk = vk;
        a[0].ki.dwFlags = up ? KEYUP : 0;
        SendInput(1, a, 40);
    }

    public static void Char(ushort ch)
    {
        INPUT[] a = new INPUT[2];
        a[0].type = INPUT_KEYBOARD; a[0].ki.wScan = ch; a[0].ki.dwFlags = UNICODE;
        a[1].type = INPUT_KEYBOARD; a[1].ki.wScan = ch; a[1].ki.dwFlags = UNICODE | KEYUP;
        SendInput(2, a, 40);
    }

    public static List<IntPtr> TopWindows()
    {
        List<IntPtr> list = new List<IntPtr>();
        EnumWindows(new EnumProc(delegate (IntPtr h, IntPtr p) { list.Add(h); return true; }), IntPtr.Zero);
        return list;
    }

    public static string Title(IntPtr h)
    {
        int n = GetWindowTextLength(h);
        StringBuilder sb = new StringBuilder(Math.Max(2, n + 2));
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string ClassName(IntPtr h)
    {
        StringBuilder sb = new StringBuilder(256);
        GetClassName(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static POINT Cursor()
    {
        POINT p;
        GetCursorPos(out p);
        return p;
    }

    // Screen position of the window's client area origin (excludes caption/border).
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
    public static POINT ClientOrigin(IntPtr h)
    {
        POINT p = new POINT();
        p.X = 0; p.Y = 0;
        ClientToScreen(h, ref p);
        return p;
    }

    // One-pixel color sample, packed as 0xRRGGBB.
    public static int Pixel(int x, int y)
    {
        using (Bitmap bmp = new Bitmap(1, 1, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(x, y, 0, 0, new Size(1, 1), CopyPixelOperation.SourceCopy);
            }
            Color c = bmp.GetPixel(0, 0);
            return (c.R << 16) | (c.G << 8) | c.B;
        }
    }

    // Virtual desktop bounds in physical pixels (call Init() first for DPI awareness).
    public static RECT VirtualScreen()
    {
        RECT r;
        r.Left = GetSystemMetrics(76);
        r.Top = GetSystemMetrics(77);
        r.Right = r.Left + GetSystemMetrics(78);
        r.Bottom = r.Top + GetSystemMetrics(79);
        if (r.Right <= r.Left || r.Bottom <= r.Top)
        {
            r.Left = 0; r.Top = 0;
            r.Right = GetSystemMetrics(0); r.Bottom = GetSystemMetrics(1);
        }
        return r;
    }

    public static void Shot(int left, int top, int w, int h, string path)
    {
        using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.CopyFromScreen(left, top, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
            }
            bmp.Save(path, ImageFormat.Png);
        }
    }

    // Downscaled capture: vision tokens scale with pixel area, so 0.5x costs a quarter.
    public static void ShotScaled(int left, int top, int w, int h, double scale, string path)
    {
        if (scale <= 0 || scale > 1) scale = 1;
        int tw = Math.Max(1, (int)(w * scale));
        int th = Math.Max(1, (int)(h * scale));
        using (Bitmap full = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(full))
            {
                g.CopyFromScreen(left, top, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
            }
            using (Bitmap small = new Bitmap(tw, th, PixelFormat.Format32bppArgb))
            {
                using (Graphics g2 = Graphics.FromImage(small))
                {
                    g2.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g2.DrawImage(full, 0, 0, tw, th);
                }
                small.Save(path, ImageFormat.Png);
            }
        }
    }

    // Capture with screen-coordinate rulers. The model reads tick labels instead of
    // multiplying preview pixels by a scale factor, which is where clicks go wrong.
    public static void ShotRuled(int left, int top, int w, int h, double scale, int step, string path, string note)
    {
        if (scale <= 0 || scale > 1) scale = 1;
        if (step < 50) step = 200;
        int tw = Math.Max(1, (int)(w * scale));
        int th = Math.Max(1, (int)(h * scale));
        int padL = 66, padT = 24, padB = 22;

        using (Bitmap full = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(full))
            {
                g.CopyFromScreen(left, top, 0, 0, new Size(w, h), CopyPixelOperation.SourceCopy);
            }
            using (Bitmap small = new Bitmap(tw, th, PixelFormat.Format32bppArgb))
            {
                using (Graphics g2 = Graphics.FromImage(small))
                {
                    g2.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g2.DrawImage(full, 0, 0, tw, th);
                }
                using (Bitmap canvas = new Bitmap(tw + padL, th + padT + padB, PixelFormat.Format32bppArgb))
                {
                    using (Graphics c = Graphics.FromImage(canvas))
                    {
                        c.Clear(Color.FromArgb(255, 18, 18, 18));
                        c.DrawImage(small, padL, padT);
                        using (Font f = new Font("Consolas", 9f))
                        using (Brush ink = new SolidBrush(Color.FromArgb(255, 235, 235, 235)))
                        using (Pen tick = new Pen(Color.FromArgb(255, 255, 170, 60)))
                        {
                            for (int x = 0; x < w; x += step)
                            {
                                int px = padL + (int)(x * scale);
                                c.DrawLine(tick, px, padT - 5, px, padT);
                                c.DrawString((left + x).ToString(), f, ink, px + 1, 2);
                            }
                            for (int y = 0; y < h; y += step)
                            {
                                int py = padT + (int)(y * scale);
                                c.DrawLine(tick, padL - 5, py, padL, py);
                                c.DrawString((top + y).ToString(), f, ink, 2, py - 7);
                            }
                            if (!string.IsNullOrEmpty(note)) c.DrawString(note, f, ink, padL + 2, padT + th + 1);
                        }
                    }
                    canvas.Save(path, ImageFormat.Png);
                }
            }
        }
    }
}
