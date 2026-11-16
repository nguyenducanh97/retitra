<# : RetiTra subtitles helper (Windows). Double-click once to set it up.
@echo off
set "RT_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "iex ([IO.File]::ReadAllText($env:RT_SELF))"
exit /b
#>
# RetiTra subtitles helper.
# Shows RetiTra's captions as see-through subtitles on top of everything (PowerPoint, videos).
# The website sends the captions to it over a private connection inside this PC (127.0.0.1, port
# 47321); nothing leaves the computer, and only the RetiTra website is accepted.
# Double-click: sets it up for your Windows account (no admin rights) so the website can start it with a
# retitra:// link. "Remove from this PC" undoes the setup.
$OverlayVersion = 11
$OverlaySource = @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// A borderless, always-on-top window drawn with per-pixel transparency: the background is fully
// see-through, the optional box behind the text can be any transparency, and letters have smooth edges.
public class RetiTraOverlay : Form {
  public const int PORT = 47321;
  List<Dictionary<string, object>> lines = new List<Dictionary<string, object>>();
  float font = 30f, scale = 1f;
  Color trColor = Color.FromArgb(253, 224, 71), orColor = Color.FromArgb(203, 213, 225), boxColor = Color.Black;
  int boxAlpha = 0;
  bool showOr = true, outline = false, locked = false, connected = false, dismissed = false;
  string split = "off"; int splitSize = 30;
  System.Windows.Forms.Timer dockTimer;
  Rectangle barRect, btnPause, btnMinus, btnPlus, btnLock, btnClose, grip;
  // Pause (a confidential moment): pressed here or with Ctrl+Alt+P from any program. Each press is counted;
  // the RetiTra page sees the count change (within a second) and pauses or resumes the meeting.
  bool paused = false, running = false; volatile int toggles = 0;
  [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
  [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
  void TogglePause() { toggles++; paused = !paused; Render(); }
  protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); RegisterHotKey(Handle, 1, 0x4000 | 0x2 | 0x1, 0x50); } // Ctrl+Alt+P, no repeat
  protected override void OnHandleDestroyed(EventArgs e) { UnregisterHotKey(Handle, 1); base.OnHandleDestroyed(e); }

  [StructLayout(LayoutKind.Sequential)] struct PT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] struct SZ { public int CX, CY; }
  [StructLayout(LayoutKind.Sequential, Pack = 1)] struct BLEND { public byte Op, Flags, Alpha, Format; }
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, IntPtr pDst, ref SZ size, IntPtr src, ref PT pSrc, int key, ref BLEND blend, int flags);
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
  [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
  [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
  delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RC r);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [StructLayout(LayoutKind.Sequential)] struct RC { public int L, T, R, B; }
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);

  // ---- taskbar: hidden only while a split-screen slideshow runs, back in every other case ----
  static bool taskbarHidden = false;
  static List<IntPtr> Taskbars() {
    List<IntPtr> l = new List<IntPtr>();
    IntPtr t = FindWindowEx(IntPtr.Zero, IntPtr.Zero, "Shell_TrayWnd", null);
    if (t != IntPtr.Zero) l.Add(t);
    IntPtr sec = IntPtr.Zero;
    while ((sec = FindWindowEx(IntPtr.Zero, sec, "Shell_SecondaryTrayWnd", null)) != IntPtr.Zero) l.Add(sec); // other monitors
    return l;
  }
  static void SetTaskbar(bool hide) {
    foreach (IntPtr t in Taskbars()) {
      bool vis = IsWindowVisible(t);
      if (hide && vis) ShowWindow(t, 0);      // SW_HIDE
      else if (!hide && !vis) ShowWindow(t, 5); // SW_SHOW
    }
    taskbarHidden = hide;
  }
  // Safety net, also used at start-up: whatever happened before, the taskbar is visible.
  public static void RestoreTaskbar() { SetTaskbar(false); }

  // ---- split screen: the PowerPoint slideshow gets one part of its screen, the captions the other ----
  static IntPtr FindSlideShow() {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate (IntPtr h, IntPtr p) {
      if (!IsWindowVisible(h)) return true;
      StringBuilder c = new StringBuilder(64); GetClassName(h, c, 64);
      if (c.ToString() == "screenClass") { found = h; return false; } // PowerPoint's slideshow window
      return true;
    }, IntPtr.Zero);
    return found;
  }
  // ---- split with any program: the window in use is fitted next to the captions ----
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool GetWindowPlacement(IntPtr h, ref WP p);
  [DllImport("user32.dll")] static extern bool SetWindowPlacement(IntPtr h, ref WP p);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
  [StructLayout(LayoutKind.Sequential)] struct WP { public int length, flags, showCmd; public int minX, minY, maxX, maxY; public RC normal; }
  Dictionary<IntPtr, WP> moved = new Dictionary<IntPtr, WP>(); // windows we resized, with their original placement
  static readonly string[] Skip = { "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "#32768", "#32770",
    "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow", "TopLevelWindowForOverflowXamlIsland", "NotifyIconOverflowWindow",
    "MultitaskingViewFrame", "ForegroundStaging", "TaskListThumbnailWnd", "tooltips_class32", "SysShadow" };
  // A normal program window we may arrange: not ours, not a dialog/menu/taskbar/desktop, not always-on-top, not hidden.
  bool Arrangeable(IntPtr h) {
    if (h == IntPtr.Zero || h == Handle || !IsWindowVisible(h) || IsIconic(h)) return false;
    uint pid; GetWindowThreadProcessId(h, out pid);
    if (pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id) return false;
    if (GetWindow(h, 4) != IntPtr.Zero) return false;               // owned window (dialog, popup)
    int ex = GetWindowLong(h, -20), st = GetWindowLong(h, -16);
    if ((ex & 0x80) != 0 || (ex & 0x8) != 0) return false;          // tool window, always-on-top (e.g. picture-in-picture)
    if ((st & 0x00C00000) != 0x00C00000 && (st & unchecked((int)0x80000000)) == 0) return false; // neither a captioned nor a popup app window
    int cloaked; if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return false; // hidden UWP shells
    StringBuilder c = new StringBuilder(64); GetClassName(h, c, 64);
    return Array.IndexOf(Skip, c.ToString()) < 0;
  }
  void Fit(IntPtr h, Rectangle r) {
    if (!moved.ContainsKey(h)) { WP wp = new WP(); wp.length = Marshal.SizeOf(typeof(WP)); if (GetWindowPlacement(h, ref wp)) moved[h] = wp; }
    if (IsZoomed(h)) ShowWindow(h, 9); // un-maximise first, or Windows ignores the new size
    RC cur; GetWindowRect(h, out cur);
    if (cur.L != r.Left || cur.T != r.Top || cur.R != r.Right || cur.B != r.Bottom)
      SetWindowPos(h, IntPtr.Zero, r.Left, r.Top, r.Width, r.Height, 0x0004 | 0x0010); // keep z-order, don't activate
  }
  // Split off or captions hidden: every window we moved goes back where it was.
  public void RestoreMoved() {
    foreach (KeyValuePair<IntPtr, WP> kv in moved) { if (IsWindow(kv.Key)) { WP wp = kv.Value; SetWindowPlacement(kv.Key, ref wp); } }
    moved.Clear();
  }
  // ---- fullscreen videos: a browser or player in fullscreen refuses to be made smaller, so a live, scaled
  // copy of it (the same kind of copy Windows shows in Alt-Tab) is shown next to the captions instead. The real
  // window keeps playing underneath at full quality; clicks and keys still go to it. ----
  [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
  RetiTraStage stage; IntPtr stageSrc = IntPtr.Zero;
  bool Ours(IntPtr h) { return h == Handle || (stage != null && stage.IsHandleCreated && h == stage.Handle); }
  bool FullscreenOn(IntPtr h, Screen scr) {
    if (h == IntPtr.Zero || Ours(h) || !IsWindowVisible(h) || IsIconic(h)) return false;
    uint pid; GetWindowThreadProcessId(h, out pid);
    if (pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id) return false;
    int ex = GetWindowLong(h, -20), st = GetWindowLong(h, -16);
    if ((ex & 0x80) != 0 || (ex & 0x8) != 0) return false;          // tool window, always-on-top
    if ((st & 0x00C00000) == 0x00C00000) return false;              // has a title bar: a maximised window, not fullscreen
    int cloaked; if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return false;
    StringBuilder c = new StringBuilder(64); GetClassName(h, c, 64);
    if (Array.IndexOf(Skip, c.ToString()) >= 0) return false;       // desktop, taskbar, menus
    RC r; GetWindowRect(h, out r); Rectangle b = scr.Bounds;
    return r.L <= b.Left && r.T <= b.Top && r.R >= b.Right && r.B >= b.Bottom;
  }
  void ShowStage(IntPtr src, Rectangle bounds, Rectangle app) {
    if (stage == null) stage = new RetiTraStage();
    if (stage.Bounds != bounds) stage.Bounds = bounds;
    if (!stage.Visible) stage.Show();
    if (src != stageSrc) { stage.Attach(src); stageSrc = src; }
    RC r; GetWindowRect(src, out r);
    int sw = Math.Max(1, r.R - r.L), sh = Math.Max(1, r.B - r.T);
    double k = Math.Min((double)app.Width / sw, (double)app.Height / sh); // whole picture, same shape
    int w = (int)(sw * k), h = (int)(sh * k);
    stage.Place(new Rectangle(app.Left - bounds.Left + (app.Width - w) / 2, app.Top - bounds.Top + (app.Height - h) / 2, w, h));
    SetWindowPos(Handle, (IntPtr)(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); // captions stay above the copy
  }
  void HideStage() {
    if (stage != null && stage.Visible) { stage.Detach(); stage.Hide(); }
    stageSrc = IntPtr.Zero;
  }
  void ArrangeSplit() {
    bool active = split != "off" && !dismissed && Visible;
    IntPtr show = active ? FindSlideShow() : IntPtr.Zero;
    if (show != IntPtr.Zero) SetTaskbar(true);           // re-checked every 0.7 s (Windows may bring it back)
    else if (taskbarHidden) SetTaskbar(false);           // slideshow over, split off or subtitles hidden
    if (!active) { HideStage(); if (moved.Count > 0) RestoreMoved(); return; }
    // A slideshow gets its whole screen (taskbar hidden); otherwise the captions stay on their screen.
    Screen scr = show != IntPtr.Zero ? Screen.FromHandle(show) : Screen.FromHandle(Handle);
    IntPtr fg = show == IntPtr.Zero ? GetForegroundWindow() : IntPtr.Zero;
    // (A small popup of the fullscreen window, e.g. a browser notice, belongs to it: its owner is the video.)
    IntPtr owner = fg != IntPtr.Zero ? GetAncestor(fg, 3) : IntPtr.Zero;
    IntPtr full = FullscreenOn(fg, scr) ? fg : FullscreenOn(owner, scr) ? owner : IntPtr.Zero;
    // The copy stays while its window is still fullscreen and still in use (or the captions were clicked).
    if (full == IntPtr.Zero && stageSrc != IntPtr.Zero && (fg == stageSrc || owner == stageSrc || Ours(fg)) && FullscreenOn(stageSrc, scr)) full = stageSrc;
    Rectangle a = show != IntPtr.Zero || full != IntPtr.Zero ? scr.Bounds : scr.WorkingArea;
    int s = (int)Math.Round((split == "bottom" ? a.Height : a.Width) * splitSize / 100.0);
    Rectangle cap, app;
    if (split == "left") { cap = new Rectangle(a.Left, a.Top, s, a.Height); app = new Rectangle(a.Left + s, a.Top, a.Width - s, a.Height); }
    else if (split == "bottom") { cap = new Rectangle(a.Left, a.Bottom - s, a.Width, s); app = new Rectangle(a.Left, a.Top, a.Width, a.Height - s); }
    else { cap = new Rectangle(a.Right - s, a.Top, s, a.Height); app = new Rectangle(a.Left, a.Top, a.Width - s, a.Height); }
    if (show != IntPtr.Zero) {
      HideStage();
      RC r; GetWindowRect(show, out r);
      if (r.L != app.Left || r.T != app.Top || r.R != app.Right || r.B != app.Bottom)
        SetWindowPos(show, IntPtr.Zero, app.Left, app.Top, app.Width, app.Height, 0x0004 | 0x0010); // no z-order change, no activation
    } else if (full != IntPtr.Zero) {
      ShowStage(full, scr.Bounds, app); // a fullscreen video: shown scaled beside the captions
    } else {
      HideStage();
      if (Arrangeable(fg) && Screen.FromHandle(fg).DeviceName == scr.DeviceName) Fit(fg, app); // the program in use, on this screen
    }
    if (Bounds != cap) Bounds = cap;
  }

  public RetiTraOverlay() {
    Text = "RetiTra subtitles";
    FormBorderStyle = FormBorderStyle.None;
    TopMost = true; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual;
    MinimumSize = new Size(240, 70);
    Rectangle wa = Screen.PrimaryScreen.WorkingArea;
    Width = (int)(wa.Width * 0.72); Height = 230;
    Left = wa.Left + (wa.Width - Width) / 2; Top = wa.Bottom - Height - 20;
    Layout2();
    new Thread(Serve) { IsBackground = true }.Start();
    dockTimer = new System.Windows.Forms.Timer(); dockTimer.Interval = 700; dockTimer.Tick += delegate { ArrangeSplit(); }; dockTimer.Start();
  }
  protected override CreateParams CreateParams {
    get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80000 | 0x80; return cp; } // layered, no taskbar button
  }
  void Layout2() {
    barRect = new Rectangle(0, 0, 276, 26);
    btnPause = new Rectangle(94, 3, 60, 20);
    btnMinus = new Rectangle(156, 3, 26, 20); btnPlus = new Rectangle(184, 3, 26, 20);
    btnLock = new Rectangle(212, 3, 30, 20); btnClose = new Rectangle(244, 3, 28, 20);
    grip = new Rectangle(Width - 18, Height - 18, 18, 18);
  }
  protected override void OnShown(EventArgs e) { base.OnShown(e); Render(); }
  protected override void OnVisibleChanged(EventArgs e) { base.OnVisibleChanged(e); if (Visible) Render(); }
  protected override void OnFormClosing(FormClosingEventArgs e) { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; dismissed = true; Hide(); } else base.OnFormClosing(e); }
  protected override void OnResize(EventArgs e) { base.OnResize(e); Layout2(); Render(); }
  protected override void OnPaint(PaintEventArgs e) { }
  protected override void OnPaintBackground(PaintEventArgs e) { }

  // Unlocked: resize from any edge or corner, drag from anywhere else. Locked: clicks pass through.
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x312) { TogglePause(); return; } // WM_HOTKEY: Ctrl+Alt+P
    if (m.Msg == 0x84 && !locked) {
      int x = (short)((long)m.LParam & 0xFFFF), y = (short)(((long)m.LParam >> 16) & 0xFFFF);
      Point p = PointToClient(new Point(x, y));
      const int E = 10;
      bool l = p.X < E, r = p.X >= Width - E, t = p.Y < E, b = p.Y >= Height - E;
      if (barRect.Contains(p) && p.X >= btnPause.Left) { base.WndProc(ref m); return; } // bar buttons
      if (t && l) { m.Result = (IntPtr)13; return; }
      if (t && r) { m.Result = (IntPtr)14; return; }
      if (b && l) { m.Result = (IntPtr)16; return; }
      if (b && r) { m.Result = (IntPtr)17; return; }
      if (l) { m.Result = (IntPtr)10; return; }
      if (r) { m.Result = (IntPtr)11; return; }
      if (t) { m.Result = (IntPtr)12; return; }
      if (b) { m.Result = (IntPtr)15; return; }
      m.Result = (IntPtr)2; return;
    }
    base.WndProc(ref m);
  }
  protected override void OnMouseUp(MouseEventArgs e) {
    if (btnPause.Contains(e.Location)) TogglePause();
    else if (btnMinus.Contains(e.Location)) { scale = Math.Max(0.5f, scale - 0.1f); Render(); }
    else if (btnPlus.Contains(e.Location)) { scale = Math.Min(2.5f, scale + 0.1f); Render(); }
    else if (btnLock.Contains(e.Location)) SetLocked(true);
    else if (btnClose.Contains(e.Location)) { dismissed = true; Hide(); }
  }
  // Locked: every click goes through to the slides and the bar is hidden. Unlock from the RetiTra page.
  public void SetLocked(bool on) {
    if (on == locked) return;
    locked = on;
    int ex = GetWindowLong(Handle, -20);
    SetWindowLong(Handle, -20, on ? (ex | 0x20) : (ex & ~0x20));
    Render();
  }

  static string Str(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v != null ? v.ToString() : ""; }
  static float Num(Dictionary<string, object> d, string k, float fallback) {
    float f; return float.TryParse(Str(d, k), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out f) ? f : fallback;
  }
  static Color Hex(string s, Color fallback) {
    try { if (s.Length == 7 && s[0] == '#') return Color.FromArgb(Convert.ToInt32(s.Substring(1, 2), 16), Convert.ToInt32(s.Substring(3, 2), 16), Convert.ToInt32(s.Substring(5, 2), 16)); } catch { }
    return fallback;
  }
  public void Apply(Dictionary<string, object> d) {
    connected = true;
    if (!Visible) { Show(); TopMost = true; }
    object v;
    if (d.TryGetValue("lines", out v) && v is object[]) {
      List<Dictionary<string, object>> l = new List<Dictionary<string, object>>();
      foreach (object o in (object[])v) { Dictionary<string, object> x = o as Dictionary<string, object>; if (x != null) l.Add(x); }
      lines = l;
    }
    float f = Num(d, "font", font); if (f >= 10 && f <= 120) font = f;
    trColor = Hex(Str(d, "tr"), trColor); orColor = Hex(Str(d, "or"), orColor); boxColor = Hex(Str(d, "bg"), boxColor);
    showOr = Str(d, "showOr") != "False"; outline = Str(d, "outline") == "True";
    boxAlpha = (int)Math.Round(Math.Max(0, Math.Min(100, Num(d, "bgAlpha", 0))) * 2.55);
    string sp = Str(d, "split"); if (sp.Length == 0) sp = "off";
    float ss = Num(d, "splitSize", 30); splitSize = (int)Math.Max(10, Math.Min(70, ss));
    if (sp != split) {
      split = sp;
      ArrangeSplit();
    }
    if (d.ContainsKey("lock")) SetLocked(Str(d, "lock") == "True");
    if (d.ContainsKey("paused")) paused = Str(d, "paused") == "True"; // the page's state wins
    if (d.ContainsKey("running")) running = Str(d, "running") == "True";
    Render();
  }

  static string FamilyFor(string s) {
    foreach (char c in s) {
      if ((c >= 0xAC00 && c <= 0xD7A3) || (c >= 0x1100 && c <= 0x11FF) || (c >= 0x3130 && c <= 0x318F)) return "Malgun Gothic";
      if (c >= 0x3040 && c <= 0x30FF) return "Yu Gothic UI";
      if (c >= 0x4E00 && c <= 0x9FFF) return "Microsoft YaHei UI";
      if (c >= 0x0E00 && c <= 0x0E7F) return "Leelawadee UI";
      if (c >= 0x0900 && c <= 0x0DFF) return "Nirmala UI";
    }
    return "Segoe UI";
  }
  static GraphicsPath TextPath(string text, float size, bool bold, float width) {
    GraphicsPath p = new GraphicsPath();
    FontFamily fam;
    try { fam = new FontFamily(FamilyFor(text)); } catch { fam = FontFamily.GenericSansSerif; }
    FontStyle st = bold && fam.IsStyleAvailable(FontStyle.Bold) ? FontStyle.Bold : FontStyle.Regular;
    p.AddString(text, fam, (int)st, size, new RectangleF(0, 0, width, 4000), StringFormat.GenericTypographic);
    return p;
  }
  static Color Fade(Color c, bool old) { return old ? Color.FromArgb(185, c) : c; }

  void Draw(Graphics g) {
    if (!locked) {
      // Nearly invisible fill so the whole area can be grabbed, plus a faint dashed frame showing the size.
      using (SolidBrush catcher = new SolidBrush(Color.FromArgb(1, 0, 0, 0))) g.FillRectangle(catcher, 0, 0, Width, Height);
      using (Pen frame = new Pen(Color.FromArgb(140, 148, 163, 184), 1.5f)) { frame.DashStyle = DashStyle.Dash; g.DrawRectangle(frame, 1, 1, Width - 3, Height - 3); }
    }
    float size = font * scale, w = Width - 32;
    int n = lines.Count;
    // Build each line's text first, then choose what fits: the line being read ("cur") always stays;
    // the next lines below it come next, then older lines above it. Only older lines are dimmed.
    int cur = n - 1;
    for (int i = 0; i < n; i++) if (Str(lines[i], "cur") == "True") cur = i;
    List<List<KeyValuePair<GraphicsPath, Color>>> blocks = new List<List<KeyValuePair<GraphicsPath, Color>>>();
    float[] hs = new float[n];
    for (int i = 0; i < n; i++) {
      Dictionary<string, object> ln = lines[i];
      bool old = ln.ContainsKey("old") ? Str(ln, "old") == "True" : i < n - 1;
      List<KeyValuePair<GraphicsPath, Color>> block = new List<KeyValuePair<GraphicsPath, Color>>();
      float h = 0;
      string who = Str(ln, "who"), tr = Str(ln, "tr"), or = Str(ln, "or");
      if (who.Length > 0) { GraphicsPath p = TextPath(who, size * 0.5f, true, w); block.Add(new KeyValuePair<GraphicsPath, Color>(p, Fade(Hex(Str(ln, "color"), Color.FromArgb(147, 197, 253)), old))); h += size * 0.62f; }
      if (tr.Length > 0) { GraphicsPath p = TextPath(tr, Str(ln, "wait") == "True" ? size * 0.65f : size, true, w); RectangleF b = p.GetBounds(); Matrix mt = new Matrix(); mt.Translate(0, h); p.Transform(mt); block.Add(new KeyValuePair<GraphicsPath, Color>(p, Fade(trColor, old))); h += b.Bottom + size * 0.18f; }
      if (showOr && or.Length > 0) { GraphicsPath p = TextPath(or, size * 0.58f, false, w); RectangleF b = p.GetBounds(); Matrix mt = new Matrix(); mt.Translate(0, h); p.Transform(mt); block.Add(new KeyValuePair<GraphicsPath, Color>(p, Fade(orColor, old))); h += b.Bottom + size * 0.12f; }
      blocks.Add(block);
      hs[i] = h + size * 0.25f;
    }
    float avail = Height - 10 - (locked ? 4 : 30);
    bool[] keep = new bool[n];
    float used = 0;
    if (n > 0) { keep[cur] = true; used = hs[cur]; }
    for (int i = cur + 1; i < n; i++) { if (used + hs[i] <= avail) { keep[i] = true; used += hs[i]; } else break; }
    for (int i = cur - 1; i >= 0; i--) { if (used + hs[i] <= avail) { keep[i] = true; used += hs[i]; } else break; }
    List<KeyValuePair<GraphicsPath, Color>> parts = new List<KeyValuePair<GraphicsPath, Color>>();
    float y = Height - 10, top = Height;
    for (int i = n - 1; i >= 0; i--) {
      if (!keep[i]) { foreach (KeyValuePair<GraphicsPath, Color> kv in blocks[i]) kv.Key.Dispose(); continue; }
      y -= hs[i];
      foreach (KeyValuePair<GraphicsPath, Color> kv in blocks[i]) { Matrix mt = new Matrix(); mt.Translate(16, y + size * 0.25f); kv.Key.Transform(mt); parts.Add(kv); }
      top = y + size * 0.25f;
    }
    if (boxAlpha > 0) using (SolidBrush bb = new SolidBrush(Color.FromArgb(boxAlpha, boxColor))) g.FillRectangle(bb, 0, 0, Width, Height); // the whole window, also when empty
    using (Pen pen = new Pen(Color.FromArgb(220, 0, 0, 0), Math.Max(2f, size / 7f))) {
      pen.LineJoin = LineJoin.Round;
      foreach (KeyValuePair<GraphicsPath, Color> kv in parts) {
        if (outline) g.DrawPath(pen, kv.Key);
        using (SolidBrush br = new SolidBrush(kv.Value)) g.FillPath(br, kv.Key);
        kv.Key.Dispose();
      }
    }
    if (lines.Count == 0) {
      string msg = connected ? "RetiTra subtitles: connected. Captions appear here during the meeting." : "RetiTra subtitles: waiting for the RetiTra page...";
      using (GraphicsPath p = TextPath(msg, 18, true, w)) {
        Matrix mt = new Matrix(); mt.Translate(16, Height - 40); p.Transform(mt);
        using (SolidBrush back = new SolidBrush(Color.FromArgb(170, 0, 0, 0))) { RectangleF b = p.GetBounds(); g.FillRectangle(back, b.X - 8, b.Y - 6, b.Width + 16, b.Height + 12); }
        g.FillPath(connected ? Brushes.PaleGreen : Brushes.White, p);
      }
    }
    if (paused) {
      // A clear badge while nothing is listened to (shown even when locked).
      using (Font f = new Font("Segoe UI", 12f, FontStyle.Bold)) {
        string msg = "Paused: nothing is listened to. Ctrl+Alt+P to resume";
        SizeF sz = g.MeasureString(msg, f);
        RectangleF r = new RectangleF((Width - sz.Width) / 2 - 12, locked ? 6 : 32, sz.Width + 24, sz.Height + 8);
        using (SolidBrush bb = new SolidBrush(Color.FromArgb(235, 180, 83, 9))) g.FillRectangle(bb, r);
        g.DrawString(msg, f, Brushes.White, r.X + 12, r.Y + 4);
      }
    }
    if (!locked) {
      using (SolidBrush bar = new SolidBrush(Color.FromArgb(235, 30, 41, 59))) g.FillRectangle(bar, barRect);
      using (SolidBrush pb = new SolidBrush(paused ? Color.FromArgb(255, 180, 83, 9) : Color.FromArgb(255, 51, 65, 85))) g.FillRectangle(pb, btnPause);
      using (Font f = new Font("Segoe UI", 9f, FontStyle.Bold)) {
        g.DrawString("::  RetiTra", f, Brushes.Gainsboro, 6, 5);
        g.DrawString(paused ? "Resume" : "Pause", f, Brushes.White, btnPause.X + (paused ? 6 : 10), 5);
        g.DrawString("A-", f, Brushes.White, btnMinus.X + 5, 5); g.DrawString("A+", f, Brushes.White, btnPlus.X + 4, 5);
        g.DrawString("Lock", f, Brushes.White, btnLock.X, 5); g.DrawString("X", f, Brushes.White, btnClose.X + 9, 5);
      }
      using (SolidBrush gb = new SolidBrush(Color.FromArgb(220, 71, 85, 105))) g.FillPolygon(gb, new Point[] { new Point(Width, Height - 16), new Point(Width, Height), new Point(Width - 16, Height) });
    }
  }
  void Render() {
    if (!IsHandleCreated || Width <= 0 || Height <= 0) return;
    using (Bitmap bmp = new Bitmap(Width, Height, PixelFormat.Format32bppArgb)) {
      using (Graphics g = Graphics.FromImage(bmp)) {
        g.Clear(Color.Transparent);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        Draw(g);
      }
      IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), hb = bmp.GetHbitmap(Color.FromArgb(0)), old = SelectObject(mem, hb);
      SZ sz = new SZ(); sz.CX = Width; sz.CY = Height;
      PT src = new PT();
      BLEND bl = new BLEND(); bl.Op = 0; bl.Flags = 0; bl.Alpha = 255; bl.Format = 1;
      UpdateLayeredWindow(Handle, screen, IntPtr.Zero, ref sz, mem, ref src, 0, ref bl, 2);
      SelectObject(mem, old); DeleteObject(hb); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen);
    }
  }

  // ---- tiny local web server: only this PC, only the RetiTra website ----
  static bool OriginOk(string o) {
    return o == "https://nguyenducanh97.github.io" || o.StartsWith("http://localhost:") || o.StartsWith("http://127.0.0.1:");
  }
  void Serve() {
    TcpListener l = new TcpListener(IPAddress.Loopback, PORT);
    l.Start();
    while (true) {
      TcpClient c = l.AcceptTcpClient();
      ThreadPool.QueueUserWorkItem(delegate { try { Answer(c); } catch { } finally { c.Close(); } });
    }
  }
  void Answer(TcpClient c) {
    NetworkStream s = c.GetStream();
    s.ReadTimeout = 4000;
    List<byte> head = new List<byte>();
    while (head.Count < 16384) {
      int b = s.ReadByte(); if (b < 0) return; head.Add((byte)b);
      int n = head.Count; if (n >= 4 && head[n - 4] == 13 && head[n - 3] == 10 && head[n - 2] == 13 && head[n - 1] == 10) break;
    }
    string[] hl = Encoding.ASCII.GetString(head.ToArray()).Split(new string[] { "\r\n" }, StringSplitOptions.None);
    string[] first = hl[0].Split(' ');
    if (first.Length < 2) return;
    string method = first[0], path = first[1];
    Dictionary<string, string> h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    for (int i = 1; i < hl.Length; i++) { int k = hl[i].IndexOf(':'); if (k > 0) h[hl[i].Substring(0, k).Trim()] = hl[i].Substring(k + 1).Trim(); }
    string origin; h.TryGetValue("Origin", out origin); origin = origin ?? "";
    int len = 0; string cl; if (h.TryGetValue("Content-Length", out cl)) int.TryParse(cl, out len);
    if (len > 200000) return;
    byte[] body = new byte[len]; int got = 0;
    while (got < len) { int r = s.Read(body, got, len - got); if (r <= 0) break; got += r; }
    if (!OriginOk(origin)) { Reply(s, 403, "", "{}"); return; }
    if (method == "OPTIONS") { Reply(s, 204, origin, ""); return; }
    if (path.StartsWith("/ping")) { Reply(s, 200, origin, "{\"app\":\"retitra-subtitles\",\"v\":11,\"toggle\":" + toggles + ",\"visible\":" + (Visible && !dismissed ? "true" : "false") + "}"); return; }
    if (method == "POST" && path.StartsWith("/show")) { Reply(s, 200, origin, "{\"ok\":true}"); BeginInvoke((MethodInvoker)delegate { dismissed = false; Show(); TopMost = true; Render(); }); return; }
    if (method == "POST" && path.StartsWith("/quit")) { Reply(s, 200, origin, "{\"ok\":true}"); BeginInvoke((MethodInvoker)delegate { Application.Exit(); }); return; }
    if (method == "POST" && path.StartsWith("/captions")) {
      Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = 400000 }.DeserializeObject(Encoding.UTF8.GetString(body, 0, got)) as Dictionary<string, object>;
      if (dismissed) { Reply(s, 200, origin, "{\"ok\":true,\"dismissed\":true}"); return; }
      if (d != null) BeginInvoke((MethodInvoker)delegate { Apply(d); });
      Reply(s, 200, origin, "{\"ok\":true,\"toggle\":" + toggles + "}"); return;
    }
    if (method == "POST" && path.StartsWith("/close")) { Reply(s, 200, origin, "{\"ok\":true}"); BeginInvoke((MethodInvoker)delegate { Hide(); ArrangeSplit(); }); return; }
    Reply(s, 404, origin, "{}");
  }
  static void Reply(NetworkStream s, int code, string origin, string json) {
    byte[] b = Encoding.UTF8.GetBytes(json);
    string status = code == 200 ? "OK" : code == 204 ? "No Content" : code == 403 ? "Forbidden" : "Not Found";
    StringBuilder sb = new StringBuilder();
    sb.Append("HTTP/1.1 ").Append(code).Append(' ').Append(status).Append("\r\n");
    if (origin.Length > 0) {
      sb.Append("Access-Control-Allow-Origin: ").Append(origin).Append("\r\nVary: Origin\r\n");
      sb.Append("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\n");
      sb.Append("Access-Control-Allow-Private-Network: true\r\nAccess-Control-Allow-Local-Network: true\r\nAccess-Control-Max-Age: 600\r\n");
    }
    sb.Append("Content-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: ").Append(b.Length).Append("\r\n\r\n");
    byte[] hb = Encoding.ASCII.GetBytes(sb.ToString());
    s.Write(hb, 0, hb.Length); s.Write(b, 0, b.Length);
  }

  // Runs the subtitles in the background; the window appears only while RetiTra wants subtitles.
  public static void RunHost(bool show) {
    RestoreTaskbar(); // in case an earlier copy was closed while the taskbar was hidden
    AppDomain.CurrentDomain.ProcessExit += delegate { RestoreTaskbar(); };
    Application.ApplicationExit += delegate { RestoreTaskbar(); };
    RetiTraOverlay f = new RetiTraOverlay();
    Application.ApplicationExit += delegate { f.RestoreMoved(); }; // quitting puts moved windows back
    IntPtr h = f.Handle; // create the window so requests can reach it while hidden
    if (show) f.Show();
    Application.Run();
  }
  public static bool PortFree() {
    try { TcpListener t = new TcpListener(IPAddress.Loopback, PORT); t.Start(); t.Stop(); return true; } catch { return false; }
  }
}

// Split screen with a fullscreen video: a black, click-through window over the screen that shows a live,
// scaled copy of the video window in the free part. It never takes the keyboard (keys go to the video), and
// it counts as opaque, so the browser still sees its window as visible and keeps playing.
public class RetiTraStage : Form {
  [DllImport("dwmapi.dll")] static extern int DwmRegisterThumbnail(IntPtr dest, IntPtr src, out IntPtr thumb);
  [DllImport("dwmapi.dll")] static extern int DwmUnregisterThumbnail(IntPtr thumb);
  [DllImport("dwmapi.dll")] static extern int DwmUpdateThumbnailProperties(IntPtr thumb, ref TP p);
  [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, int key, byte alpha, int flags);
  [StructLayout(LayoutKind.Sequential)] struct R4 { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] struct TP { public int flags; public R4 dst; public R4 src; public byte opacity; public int visible; public int clientOnly; }
  IntPtr thumb = IntPtr.Zero; Rectangle placed = Rectangle.Empty;
  public RetiTraStage() {
    Text = "RetiTra split screen"; FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false;
    TopMost = true; BackColor = Color.Black; StartPosition = FormStartPosition.Manual;
  }
  protected override CreateParams CreateParams {
    get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80 | 0x08000000 | 0x20 | 0x80000; return cp; } // tool, no-activate, click-through, layered
  }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); SetLayeredWindowAttributes(Handle, 0, 255, 2); }
  public void Attach(IntPtr src) { Detach(); DwmRegisterThumbnail(Handle, src, out thumb); placed = Rectangle.Empty; }
  public void Place(Rectangle d) {
    if (thumb == IntPtr.Zero || d == placed) return;
    placed = d;
    TP p = new TP(); p.flags = 0x1 | 0x4 | 0x8 | 0x10; // destination, opacity, visible, whole window
    p.dst.L = d.Left; p.dst.T = d.Top; p.dst.R = d.Right; p.dst.B = d.Bottom; p.opacity = 255; p.visible = 1;
    DwmUpdateThumbnailProperties(thumb, ref p);
  }
  public void Detach() { if (thumb != IntPtr.Zero) { DwmUnregisterThumbnail(thumb); thumb = IntPtr.Zero; } placed = Rectangle.Empty; }
}
"@

$HOME_DIR = Join-Path $env:LOCALAPPDATA "RetiTra"
$INSTALLED = Join-Path $HOME_DIR "RetiTra-Helper.ps1"
$DLL = Join-Path $HOME_DIR "RetiTraOverlay-$OverlayVersion.dll"
$PROTO_KEY = "HKCU:\Software\Classes\retitra"
$RUN_KEY = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$PS_EXE = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$REFS = @("System.Windows.Forms", "System.Drawing", "System.Web.Extensions")

# The overlay is compiled once and kept next to the helper, so later starts take about a second.
function Load-Overlay {
  if ("RetiTraOverlay" -as [type]) { return }
  if (Test-Path $DLL) { try { Add-Type -Path $DLL -ErrorAction Stop; return } catch { } }
  try {
    New-Item -ItemType Directory -Force -Path $HOME_DIR | Out-Null
    Add-Type -ReferencedAssemblies $REFS -TypeDefinition $OverlaySource -OutputAssembly $DLL -OutputType Library -ErrorAction Stop
    Add-Type -Path $DLL -ErrorAction Stop
  } catch {
    Add-Type -ReferencedAssemblies $REFS -TypeDefinition $OverlaySource
  }
}
# Copies itself to %LOCALAPPDATA%\RetiTra and registers retitra:// links for this Windows user only.
# The link is handed to the script as a plain argument (-File), never run as code.
function Send-Local($path) {
  try { Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:47321$path" -Method Post -Body "{}" -Headers @{ Origin = "http://127.0.0.1:47321" } -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}
function Start-Background {
  Start-Process $PS_EXE -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-STA", "-WindowStyle", "Hidden", "-File", "`"$INSTALLED`"", "retitra://standby" -WindowStyle Hidden
}
function Install-Helper {
  # stop an older copy that may be running (older versions only understand "close")
  if (-not (Send-Local "/quit")) { [void](Send-Local "/close") } else { Start-Sleep -Milliseconds 600 }
  New-Item -ItemType Directory -Force -Path $HOME_DIR | Out-Null
  [IO.File]::WriteAllText($INSTALLED, [IO.File]::ReadAllText($env:RT_SELF))
  $cmd = "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$INSTALLED`" `"%1`""
  New-Item -Path "$PROTO_KEY\shell\open\command" -Force | Out-Null
  Set-ItemProperty -Path $PROTO_KEY -Name "(default)" -Value "URL:RetiTra subtitles helper"
  Set-ItemProperty -Path $PROTO_KEY -Name "URL Protocol" -Value ""
  Set-ItemProperty -Path "$PROTO_KEY\shell\open\command" -Name "(default)" -Value $cmd
  # wait quietly in the background from Windows sign-in, so the website never has to start it
  Set-ItemProperty -Path $RUN_KEY -Name "RetiTra subtitles" -Value "`"$PS_EXE`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$INSTALLED`" retitra://standby"
  Load-Overlay
  Start-Background
}
function Remove-Helper {
  Remove-ItemProperty -Path $RUN_KEY -Name "RetiTra subtitles" -ErrorAction SilentlyContinue
  if (-not (Send-Local "/quit")) { [void](Send-Local "/close") }
  Start-Sleep -Milliseconds 800
  Remove-Item -Path $PROTO_KEY -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $HOME_DIR -Recurse -Force -ErrorAction SilentlyContinue
}
function Start-Overlay([bool]$show) {
  Load-Overlay
  if (-not [RetiTraOverlay]::PortFree()) { if ($show) { [void](Send-Local "/show") }; return }  # already running
  [RetiTraOverlay]::RunHost($show)
}

# ---- started by the website: retitra://subtitles ----
$link = if ($args.Count) { [string]$args[0] } else { "" }
if ($link -match '^retitra:') { Start-Overlay (-not ($link -match 'standby')); exit }

# ---- double-clicked: set up, then offer to start ----
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$setupNote = "Set up. RetiTra can now show see-through subtitles on this PC."
$ok = $true
try { Install-Helper } catch { $ok = $false; $setupNote = "Setup failed: " + $_.Exception.Message }

$form = New-Object Windows.Forms.Form
$form.Text = "RetiTra - subtitles helper"
$form.Size = New-Object Drawing.Size(430, 210)
$form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
$form.TopMost = $true
$form.StartPosition = "Manual"
$wa = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea  # open where the mouse is
$form.Location = New-Object Drawing.Point(($wa.Left + ($wa.Width - 430) / 2), ($wa.Top + ($wa.Height - 210) / 2))
$form.Font = New-Object Drawing.Font("Segoe UI", 9.5)
$note = New-Object Windows.Forms.Label
$note.Location = "15,12"; $note.Size = "390,60"; $note.ForeColor = $(if ($ok) { [Drawing.Color]::DarkGreen } else { [Drawing.Color]::Firebrick })
$note.Text = $setupNote + "`nIt now waits quietly in the background (also after restarting Windows). Go back to RetiTra and press Ready / Done."
$form.Controls.Add($note)
$startBtn = New-Object Windows.Forms.Button
$startBtn.Text = "Show subtitles now"; $startBtn.Location = "15,85"; $startBtn.Size = "185,32"
$form.Controls.Add($startBtn)
$remove = New-Object Windows.Forms.Button
$remove.Text = "Remove from this PC"; $remove.Location = "215,85"; $remove.Size = "185,32"
$form.Controls.Add($remove)
$hint = New-Object Windows.Forms.Label
$hint.Location = "15,128"; $hint.Size = "390,36"; $hint.ForeColor = [Drawing.Color]::DimGray
$hint.Text = "Subtitles: drag to move, drag any edge or corner to resize. Lock lets clicks pass through."
$form.Controls.Add($hint)
$startBtn.Add_Click({ [void](Send-Local "/show"); $form.Close() })
$remove.Add_Click({
  Remove-Helper
  $note.ForeColor = [Drawing.Color]::DimGray
  $note.Text = "Removed from this PC. Run this file again to use see-through subtitles."
})
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
