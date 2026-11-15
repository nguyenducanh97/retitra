<# : RetiTra subtitles helper (Windows). Double-click once to set it up.
@echo off
set "RT_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "iex ([IO.File]::ReadAllText($env:RT_SELF))"
exit /b
#>
# RetiTra subtitles helper.
# Shows RetiTra's captions as see-through subtitles on top of everything (PowerPoint, videos): text only,
# no background. The website sends the captions to it over a private connection inside this PC
# (127.0.0.1, port 47321); nothing leaves the computer.
# Double-click: sets it up for your Windows account (no admin rights) so the website can start it with a
# retitra:// link. "Remove from this PC" undoes the setup.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Web.Extensions -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

public class RetiTraOverlay : Form {
  public const int PORT = 47321;
  static readonly Color KEY = Color.FromArgb(255, 1, 0, 1); // painted pixels of this colour are see-through
  List<Dictionary<string, object>> lines = new List<Dictionary<string, object>>();
  float font = 30f, scale = 1f;
  Color trColor = Color.FromArgb(253, 224, 71), orColor = Color.FromArgb(203, 213, 225), boxColor = Color.FromArgb(5, 7, 13);
  bool showOr = true, box = false, locked = false, outline = false;
  Rectangle barRect, btnMinus, btnPlus, btnLock, btnClose, grip;

  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);

  public RetiTraOverlay() {
    Text = "RetiTra subtitles";
    FormBorderStyle = FormBorderStyle.None;
    TopMost = true; ShowInTaskbar = false; StartPosition = FormStartPosition.Manual;
    BackColor = KEY; TransparencyKey = KEY;
    DoubleBuffered = true;
    MinimumSize = new Size(320, 90);
    Rectangle wa = Screen.PrimaryScreen.WorkingArea;
    Width = (int)(wa.Width * 0.72); Height = 230;
    Left = wa.Left + (wa.Width - Width) / 2; Top = wa.Bottom - Height - 20;
    Layout2();
    new Thread(Serve) { IsBackground = true }.Start();
  }
  protected override CreateParams CreateParams {
    get { CreateParams cp = base.CreateParams; cp.ExStyle |= 0x80; return cp; } // tool window: no taskbar button
  }
  void Layout2() {
    barRect = new Rectangle(0, 0, 214, 26);
    btnMinus = new Rectangle(94, 3, 26, 20); btnPlus = new Rectangle(122, 3, 26, 20);
    btnLock = new Rectangle(150, 3, 30, 20); btnClose = new Rectangle(182, 3, 28, 20);
    grip = new Rectangle(Width - 18, Height - 18, 18, 18);
  }
  protected override void OnResize(EventArgs e) { base.OnResize(e); Layout2(); Invalidate(); }

  // Drag by the bar, resize by the corner grip. See-through pixels never receive the mouse.
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x84 && !locked) {
      int x = (short)((long)m.LParam & 0xFFFF), y = (short)(((long)m.LParam >> 16) & 0xFFFF);
      Point p = PointToClient(new Point(x, y));
      if (grip.Contains(p)) { m.Result = (IntPtr)17; return; }
      if (barRect.Contains(p) && p.X < btnMinus.Left) { m.Result = (IntPtr)2; return; }
    }
    base.WndProc(ref m);
  }
  protected override void OnMouseUp(MouseEventArgs e) {
    if (btnMinus.Contains(e.Location)) { scale = Math.Max(0.5f, scale - 0.1f); Invalidate(); }
    else if (btnPlus.Contains(e.Location)) { scale = Math.Min(2.5f, scale + 0.1f); Invalidate(); }
    else if (btnLock.Contains(e.Location)) SetLocked(true);
    else if (btnClose.Contains(e.Location)) Close();
  }
  // Locked: every click goes through to the slides; the bar is hidden. Unlock from the RetiTra page.
  public void SetLocked(bool on) {
    locked = on;
    int ex = GetWindowLong(Handle, -20);
    SetWindowLong(Handle, -20, on ? (ex | 0x20) : (ex & ~0x20));
    Invalidate();
  }

  static string Str(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v != null ? v.ToString() : ""; }
  static Color Hex(string s, Color fallback) {
    try { if (s.Length == 7 && s[0] == '#') return Color.FromArgb(Convert.ToInt32(s.Substring(1, 2), 16), Convert.ToInt32(s.Substring(3, 2), 16), Convert.ToInt32(s.Substring(5, 2), 16)); } catch { }
    return fallback;
  }
  static Color Safe(Color c) { return c.ToArgb() == KEY.ToArgb() ? Color.Black : c; }
  public void Apply(Dictionary<string, object> d) {
    object v;
    if (d.TryGetValue("lines", out v) && v is object[]) {
      List<Dictionary<string, object>> l = new List<Dictionary<string, object>>();
      foreach (object o in (object[])v) { Dictionary<string, object> x = o as Dictionary<string, object>; if (x != null) l.Add(x); }
      lines = l;
    }
    float f; if (float.TryParse(Str(d, "font"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out f) && f >= 10 && f <= 120) font = f;
    trColor = Safe(Hex(Str(d, "tr"), trColor)); orColor = Safe(Hex(Str(d, "or"), orColor)); boxColor = Safe(Hex(Str(d, "bg"), boxColor));
    showOr = Str(d, "showOr") != "False"; box = Str(d, "box") == "True"; outline = Str(d, "outline") == "True";
    double op; if (double.TryParse(Str(d, "opacity"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out op) && op >= 20 && op <= 100) Opacity = op / 100.0;
    if (d.ContainsKey("lock")) SetLocked(Str(d, "lock") == "True");
    Invalidate();
  }

  static string FamilyFor(string s) {
    foreach (char c in s) {
      if ((c >= 0xAC00 && c <= 0xD7A3) || (c >= 0x1100 && c <= 0x11FF) || (c >= 0x3130 && c <= 0x318F)) return "Malgun Gothic";
      if (c >= 0x3040 && c <= 0x30FF) return "Yu Gothic UI";
      if (c >= 0x4E00 && c <= 0x9FFF) return "Microsoft YaHei UI";
      if (c >= 0x0E00 && c <= 0x0E7F) return "Leelawadee UI";
      if (c >= 0x0900 && c <= 0x0DFF) return "Nirmala UI";
      if (c >= 0x0600 && c <= 0x06FF) return "Segoe UI";
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
  static Color Dim(Color c, bool old) { Color d = old ? Color.FromArgb(c.R * 6 / 10, c.G * 6 / 10, c.B * 6 / 10) : c; return d.ToArgb() == KEY.ToArgb() ? Color.Black : d; }

  protected override void OnPaint(PaintEventArgs e) {
    Graphics g = e.Graphics;
    g.Clear(KEY);
    // Without an outline, edges are drawn crisp: smoothing would blend them with the see-through colour
    // and leave a dark fringe around the letters.
    g.SmoothingMode = outline || box ? SmoothingMode.AntiAlias : SmoothingMode.None;
    float size = font * scale, w = Width - 32, y = Height - 10;
    List<KeyValuePair<GraphicsPath, Color>> parts = new List<KeyValuePair<GraphicsPath, Color>>();
    float top = y;
    for (int i = lines.Count - 1; i >= 0; i--) {
      Dictionary<string, object> ln = lines[i];
      bool old = i < lines.Count - 1;
      List<KeyValuePair<GraphicsPath, Color>> block = new List<KeyValuePair<GraphicsPath, Color>>();
      float h = 0;
      string who = Str(ln, "who"), tr = Str(ln, "tr"), or = Str(ln, "or");
      if (who.Length > 0) { GraphicsPath p = TextPath(who, size * 0.5f, true, w); block.Add(new KeyValuePair<GraphicsPath, Color>(p, Dim(Hex(Str(ln, "color"), Color.FromArgb(147, 197, 253)), old))); h += size * 0.62f; }
      if (tr.Length > 0) { GraphicsPath p = TextPath(tr, Str(ln, "wait") == "True" ? size * 0.65f : size, true, w); RectangleF b = p.GetBounds(); Matrix mt = new Matrix(); mt.Translate(0, h); p.Transform(mt); block.Add(new KeyValuePair<GraphicsPath, Color>(p, Dim(trColor, old))); h += b.Bottom + size * 0.18f; }
      if (showOr && or.Length > 0) { GraphicsPath p = TextPath(or, size * 0.58f, false, w); RectangleF b = p.GetBounds(); Matrix mt = new Matrix(); mt.Translate(0, h); p.Transform(mt); block.Add(new KeyValuePair<GraphicsPath, Color>(p, Dim(orColor, old))); h += b.Bottom + size * 0.12f; }
      if (y - h < (locked ? 4 : 30) && i < lines.Count - 1) break; // older lines that don't fit are left out
      y -= h + size * 0.25f;
      foreach (KeyValuePair<GraphicsPath, Color> kv in block) { Matrix mt = new Matrix(); mt.Translate(16, y + size * 0.25f); kv.Key.Transform(mt); parts.Add(kv); }
      top = y + size * 0.25f;
    }
    if (box && parts.Count > 0) using (SolidBrush bb = new SolidBrush(boxColor)) g.FillRectangle(bb, 6, top - 8, Width - 12, Height - top + 4);
    float penWidth = Math.Max(2f, size / 7f);
    using (Pen pen = new Pen(Color.Black, penWidth)) {
      pen.LineJoin = LineJoin.Round;
      foreach (KeyValuePair<GraphicsPath, Color> kv in parts) { if (outline && !box) g.DrawPath(pen, kv.Key); using (SolidBrush br = new SolidBrush(kv.Value)) g.FillPath(br, kv.Key); kv.Key.Dispose(); }
    }
    if (lines.Count == 0) {
      using (GraphicsPath p = TextPath("RetiTra subtitles: waiting for captions", 18, true, w)) {
        Matrix mt = new Matrix(); mt.Translate(16, Height - 40); p.Transform(mt);
        g.FillPath(Brushes.White, p);
      }
    }
    if (!locked) {
      using (SolidBrush bar = new SolidBrush(Color.FromArgb(30, 41, 59))) g.FillRectangle(bar, barRect);
      using (Font f = new Font("Segoe UI", 9f, FontStyle.Bold)) {
        g.DrawString("::  RetiTra", f, Brushes.Gainsboro, 6, 5);
        g.DrawString("A-", f, Brushes.White, btnMinus.X + 5, 5); g.DrawString("A+", f, Brushes.White, btnPlus.X + 4, 5);
        g.DrawString("Lock", f, Brushes.White, btnLock.X, 5); g.DrawString("X", f, Brushes.White, btnClose.X + 9, 5);
      }
      using (SolidBrush gb = new SolidBrush(Color.FromArgb(71, 85, 105))) g.FillPolygon(gb, new Point[] { new Point(Width, Height - 16), new Point(Width, Height), new Point(Width - 16, Height) });
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
    if (path.StartsWith("/ping")) { Reply(s, 200, origin, "{\"app\":\"retitra-subtitles\",\"v\":1}"); return; }
    if (method == "POST" && path.StartsWith("/captions")) {
      Dictionary<string, object> d = new JavaScriptSerializer { MaxJsonLength = 400000 }.DeserializeObject(Encoding.UTF8.GetString(body, 0, got)) as Dictionary<string, object>;
      if (d != null) BeginInvoke((MethodInvoker)delegate { Apply(d); });
      Reply(s, 200, origin, "{\"ok\":true}"); return;
    }
    if (method == "POST" && path.StartsWith("/close")) { Reply(s, 200, origin, "{\"ok\":true}"); BeginInvoke((MethodInvoker)delegate { Close(); }); return; }
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
      sb.Append("Access-Control-Allow-Private-Network: true\r\nAccess-Control-Max-Age: 600\r\n");
    }
    sb.Append("Content-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: ").Append(b.Length).Append("\r\n\r\n");
    byte[] hb = Encoding.ASCII.GetBytes(sb.ToString());
    s.Write(hb, 0, hb.Length); s.Write(b, 0, b.Length);
  }

  public static bool PortFree() {
    try { TcpListener t = new TcpListener(IPAddress.Loopback, PORT); t.Start(); t.Stop(); return true; } catch { return false; }
  }
}
"@

$HOME_DIR = Join-Path $env:LOCALAPPDATA "RetiTra"
$INSTALLED = Join-Path $HOME_DIR "RetiTra-Helper.ps1"
$PROTO_KEY = "HKCU:\Software\Classes\retitra"

# Copies itself to %LOCALAPPDATA%\RetiTra and registers retitra:// links for this Windows user only.
# The link is handed to the script as a plain argument (-File), never run as code.
function Install-Helper {
  New-Item -ItemType Directory -Force -Path $HOME_DIR | Out-Null
  [IO.File]::WriteAllText($INSTALLED, [IO.File]::ReadAllText($env:RT_SELF))
  $cmd = "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$INSTALLED`" `"%1`""
  New-Item -Path "$PROTO_KEY\shell\open\command" -Force | Out-Null
  Set-ItemProperty -Path $PROTO_KEY -Name "(default)" -Value "URL:RetiTra subtitles helper"
  Set-ItemProperty -Path $PROTO_KEY -Name "URL Protocol" -Value ""
  Set-ItemProperty -Path "$PROTO_KEY\shell\open\command" -Name "(default)" -Value $cmd
}
function Remove-Helper {
  Remove-Item -Path $PROTO_KEY -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $HOME_DIR -Recurse -Force -ErrorAction SilentlyContinue
}
function Start-Overlay {
  if (-not [RetiTraOverlay]::PortFree()) { return }  # already running
  [void](New-Object RetiTraOverlay).ShowDialog()
}

# ---- started by the website: retitra://subtitles ----
$link = if ($args.Count) { [string]$args[0] } else { "" }
if ($link -match '^retitra:') { Start-Overlay; exit }

# ---- double-clicked: set up, then offer to start ----
$setupNote = "Set up. RetiTra can now show see-through subtitles on this PC."
try { Install-Helper } catch { $setupNote = "Setup failed: " + $_.Exception.Message }

$form = New-Object Windows.Forms.Form
$form.Text = "RetiTra - subtitles helper"
$form.Size = New-Object Drawing.Size(430, 210)
$form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
$form.TopMost = $true; $form.StartPosition = "CenterScreen"
$form.Font = New-Object Drawing.Font("Segoe UI", 9.5)
$note = New-Object Windows.Forms.Label
$note.Location = "15,12"; $note.Size = "390,60"; $note.ForeColor = [Drawing.Color]::DarkGreen
$note.Text = $setupNote + "`nGo back to RetiTra and press Done. You can close this window."
$form.Controls.Add($note)
$startBtn = New-Object Windows.Forms.Button
$startBtn.Text = "Show subtitles now"; $startBtn.Location = "15,85"; $startBtn.Size = "185,32"
$form.Controls.Add($startBtn)
$remove = New-Object Windows.Forms.Button
$remove.Text = "Remove from this PC"; $remove.Location = "215,85"; $remove.Size = "185,32"
$form.Controls.Add($remove)
$hint = New-Object Windows.Forms.Label
$hint.Location = "15,128"; $hint.Size = "390,36"; $hint.ForeColor = [Drawing.Color]::DimGray
$hint.Text = "Subtitles: drag the small bar to move, the corner to resize. Lock lets clicks pass through."
$form.Controls.Add($hint)
$startBtn.Add_Click({ $form.Hide(); Start-Overlay; $form.Close() })
$remove.Add_Click({
  Remove-Helper
  $note.ForeColor = [Drawing.Color]::DimGray
  $note.Text = "Removed from this PC. Run this file again to use see-through subtitles."
})
[void]$form.ShowDialog()
