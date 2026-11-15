<# : RetiTra caption transparency helper (Windows). Double-click to run.
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "iex ([IO.File]::ReadAllText('%~f0'))"
exit /b
#>
# Makes the RetiTra floating-captions window see-through, so slides or video show behind the text.
# It only changes how Windows draws that one window; close this helper or press "Back to normal" to undo.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class RT {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
  public static string Title(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
  public static IntPtr Find(string part) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, p) => { if (IsWindowVisible(h) && Title(h).IndexOf(part, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
}
"@

$GWL_EXSTYLE = -20; $WS_EX_LAYERED = 0x80000; $WS_EX_TRANSPARENT = 0x20
$LWA_ALPHA = 0x2
$script:target = [IntPtr]::Zero
$script:origStyle = 0

$form = New-Object Windows.Forms.Form
$form.Text = "RetiTra - caption transparency"
$form.Size = New-Object Drawing.Size(430, 330)
$form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
$form.TopMost = $true; $form.StartPosition = "CenterScreen"
$form.Font = New-Object Drawing.Font("Segoe UI", 9.5)

$status = New-Object Windows.Forms.Label
$status.Location = "15,12"; $status.Size = "390,40"
$status.Text = "1. Open Float captions in RetiTra.`n2. Press Find caption window."
$form.Controls.Add($status)

$find = New-Object Windows.Forms.Button
$find.Text = "Find caption window"; $find.Location = "15,58"; $find.Size = "185,30"
$form.Controls.Add($find)
$pick = New-Object Windows.Forms.Button
$pick.Text = "Pick by clicking it"; $pick.Location = "215,58"; $pick.Size = "185,30"
$form.Controls.Add($pick)

$lbl = New-Object Windows.Forms.Label
$lbl.Location = "15,102"; $lbl.Size = "390,20"; $lbl.Text = "Opacity of the whole window: 70%"
$form.Controls.Add($lbl)
$slider = New-Object Windows.Forms.TrackBar
$slider.Location = "10,122"; $slider.Size = "395,45"; $slider.Minimum = 20; $slider.Maximum = 100
$slider.TickFrequency = 10; $slider.Value = 70
$form.Controls.Add($slider)

$tip = New-Object Windows.Forms.Label
$tip.Location = "15,170"; $tip.Size = "395,36"; $tip.ForeColor = [Drawing.Color]::DimGray
$tip.Text = "Tip: 60-75% with a dark background and yellow or white text (Colours in RetiTra) reads best."
$form.Controls.Add($tip)
$clickBox = New-Object Windows.Forms.CheckBox
$clickBox.Location = "15,208"; $clickBox.Size = "395,22"
$clickBox.Text = "Let mouse clicks pass through to the slides"
$form.Controls.Add($clickBox)

$reset = New-Object Windows.Forms.Button
$reset.Text = "Back to normal"; $reset.Location = "15,236"; $reset.Size = "185,30"
$form.Controls.Add($reset)

function Apply {
  if ($script:target -eq [IntPtr]::Zero -or -not [RT]::IsWindow($script:target)) { $status.Text = "No caption window selected yet."; return }
  $style = $script:origStyle -bor $WS_EX_LAYERED
  if ($clickBox.Checked) { $style = $style -bor $WS_EX_TRANSPARENT }
  [void][RT]::SetWindowLong($script:target, $GWL_EXSTYLE, $style)
  $alpha = [byte][Math]::Round(255 * $slider.Value / 100)
  [void][RT]::SetLayeredWindowAttributes($script:target, [uint32]0, $alpha, [uint32]$LWA_ALPHA)
  $lbl.Text = "Opacity of the whole window: $($slider.Value)%"
}
function Restore {
  if ($script:target -ne [IntPtr]::Zero -and [RT]::IsWindow($script:target)) {
    [void][RT]::SetWindowLong($script:target, $GWL_EXSTYLE, $script:origStyle)
  }
}
function Use($h) {
  if ($h -eq [IntPtr]::Zero) { return $false }
  Restore
  $script:target = $h
  $script:origStyle = [RT]::GetWindowLong($h, $GWL_EXSTYLE) -band (-bnot ($WS_EX_LAYERED -bor $WS_EX_TRANSPARENT))
  $status.Text = "Connected to: " + [RT]::Title($h)
  Apply
  return $true
}

function FindCaptions {
  $h = [RT]::Find("RetiTra captions")
  if ($h -eq [IntPtr]::Zero) { $h = [RT]::Find("nguyenducanh97.github.io") }
  return (Use $h)
}
$find.Add_Click({
  if (-not (FindCaptions)) { $status.Text = "Caption window not found. Open Float captions first, or use Pick by clicking it." }
})
$form.Add_Shown({ [void](FindCaptions) })  # connect straight away when the captions are already open
$pick.Add_Click({
  $status.Text = "Click on the caption window now (3 seconds)..."
  $form.Refresh()
  $script:pickTimer.Start()
})
$script:pickTimer = New-Object Windows.Forms.Timer
$script:pickTimer.Interval = 3000
$script:pickTimer.Add_Tick({
  $script:pickTimer.Stop()
  $h = [RT]::GetForegroundWindow()
  if ($h -eq $form.Handle -or -not (Use $h)) { $status.Text = "No window picked. Try again and click the caption window." }
})
$slider.Add_ValueChanged({ Apply })
$clickBox.Add_CheckedChanged({ Apply })
$reset.Add_Click({ $clickBox.Checked = $false; $slider.Value = 100; Restore; $status.Text = "Back to normal." })
$form.Add_FormClosing({ Restore })
[void]$form.ShowDialog()
