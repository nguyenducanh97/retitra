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
$OverlayVersion = 6
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
  Rectangle barRect, btnMinus, btnPlus, btnLock, btnClose, grip;

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
  }
  protected override CreateParams CreateParams {
    get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80000 | 0x80; return cp; } // layered, no taskbar button
  }
  void Layout2() {
    barRect = new Rectangle(0, 0, 214, 26);
    btnMinus = new Rectangle(94, 3, 26, 20); btnPlus = new Rectangle(122, 3, 26, 20);
    btnLock = new Rectangle(150, 3, 30, 20); btnClose = new Rectangle(182, 3, 28, 20);
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
    if (m.Msg == 0x84 && !locked) {
      int x = (short)((long)m.LParam & 0xFFFF), y = (short)(((long)m.LParam >> 16) & 0xFFFF);
      Point p = PointToClient(new Point(x, y));
      const int E = 10;
      bool l = p.X < E, r = p.X >= Width - E, t = p.Y < E, b = p.Y >= Height - E;
      if (barRect.Contains(p) && p.X >= btnMinus.Left) { base.WndProc(ref m); return; } // bar buttons
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
    if (btnMinus.Contains(e.Location)) { scale = Math.Max(0.5f, scale - 0.1f); Render(); }
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
    if (d.ContainsKey("lock")) SetLocked(Str(d, "lock") == "True");
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
    if (boxAlpha > 0 && parts.Count > 0) using (SolidBrush bb = new SolidBrush(Color.FromArgb(boxAlpha, boxColor))) g.FillRectangle(bb, 6, top - 10, Width - 12, Height - top + 6);
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
    if (!locked) {
      using (SolidBrush bar = new SolidBrush(Color.FromArgb(235, 30, 41, 59))) g.FillRectangle(bar, barRect);
      using (Font f = new Font("Segoe UI", 9f, FontStyle.Bold)) {
        g.DrawString("::  RetiTra", f, Brushes.Gainsboro, 6, 5);
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
    if (path.StartsWith("/ping")) { Reply(s, 200, origin, "{\"app\":\"retitra-subtitles\",\"v\":6,\"visible\":" + (Visible && !dismissed ? "true" : "false") + "}"); return; }
    if (method == "POST" && path.StartsWith("/show")) { Reply(s, 200, origin, "{\"ok\":true}"); BeginInvoke((MethodInvoker)delegate { dismissed = false; Show(); TopMost = true; Render(); }); return; }
    if (method == "POST" && path.StartsWith("/quit")) { Reply(s, 200, origin, "{\"ok\":true}"); BeginInvoke((MethodInvoker)delegate { Application.Exit(); }); return; }
    if (method == "POST" && path.StartsWith("/captions")) {
      Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = 400000 }.DeserializeObject(Encoding.UTF8.GetString(body, 0, got)) as Dictionary<string, object>;
      if (dismissed) { Reply(s, 200, origin, "{\"ok\":true,\"dismissed\":true}"); return; }
      if (d != null) BeginInvoke((MethodInvoker)delegate { Apply(d); });
      Reply(s, 200, origin, "{\"ok\":true}"); return;
    }
    if (method == "POST" && path.StartsWith("/close")) { Reply(s, 200, origin, "{\"ok\":true}"); BeginInvoke((MethodInvoker)delegate { Hide(); }); return; }
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
    RetiTraOverlay f = new RetiTraOverlay();
    IntPtr h = f.Handle; // create the window so requests can reach it while hidden
    if (show) f.Show();
    Application.Run();
  }
  public static bool PortFree() {
    try { TcpListener t = new TcpListener(IPAddress.Loopback, PORT); t.Start(); t.Stop(); return true; } catch { return false; }
  }
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
