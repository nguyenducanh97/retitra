<# : RetiTra see-through helper (Windows). Double-click once to set it up.
@echo off
set "RT_SELF=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "iex ([IO.File]::ReadAllText($env:RT_SELF))"
exit /b
#>
# RetiTra see-through helper.
# Double-click: sets itself up for your Windows account (no admin rights) and opens a small control window.
# After setup, the RetiTra website's "See-through" control runs it in the background through a
# retitra:// link, and it makes the floating-captions window semi-transparent.
# Nothing else on the PC is changed. "Remove from this PC" undoes the setup.
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

$GWL_EXSTYLE = -20; $WS_EX_LAYERED = 0x80000; $WS_EX_TRANSPARENT = 0x20; $LWA_ALPHA = 0x2
$HOME_DIR = Join-Path $env:LOCALAPPDATA "RetiTra"
$INSTALLED = Join-Path $HOME_DIR "RetiTra-Helper.ps1"
$PROTO_KEY = "HKCU:\Software\Classes\retitra"

function Find-Captions {
  $h = [RT]::Find("RetiTra captions")
  if ($h -eq [IntPtr]::Zero) { $h = [RT]::Find("nguyenducanh97.github.io") }
  return $h
}
# opacity 20-100 (100 = normal); click = let mouse clicks pass through
function Set-SeeThrough([IntPtr]$h, [int]$opacity, [bool]$click) {
  if ($h -eq [IntPtr]::Zero -or -not [RT]::IsWindow($h)) { return $false }
  $base = [RT]::GetWindowLong($h, $GWL_EXSTYLE) -band (-bnot ($WS_EX_LAYERED -bor $WS_EX_TRANSPARENT))
  if ($opacity -ge 100 -and -not $click) { [void][RT]::SetWindowLong($h, $GWL_EXSTYLE, $base); return $true }
  $style = $base -bor $WS_EX_LAYERED
  if ($click) { $style = $style -bor $WS_EX_TRANSPARENT }
  [void][RT]::SetWindowLong($h, $GWL_EXSTYLE, $style)
  $alpha = [byte][Math]::Round(255 * [Math]::Max(20, [Math]::Min(100, $opacity)) / 100)
  return [RT]::SetLayeredWindowAttributes($h, [uint32]0, $alpha, [uint32]$LWA_ALPHA)
}
# Copies itself to %LOCALAPPDATA%\RetiTra and registers retitra:// links for this Windows user only.
# The link is handed to the script as a plain argument (-File), never run as code.
function Install-Helper {
  New-Item -ItemType Directory -Force -Path $HOME_DIR | Out-Null
  [IO.File]::WriteAllText($INSTALLED, [IO.File]::ReadAllText($env:RT_SELF))
  $cmd = "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$INSTALLED`" `"%1`""
  New-Item -Path "$PROTO_KEY\shell\open\command" -Force | Out-Null
  Set-ItemProperty -Path $PROTO_KEY -Name "(default)" -Value "URL:RetiTra see-through helper"
  Set-ItemProperty -Path $PROTO_KEY -Name "URL Protocol" -Value ""
  Set-ItemProperty -Path "$PROTO_KEY\shell\open\command" -Name "(default)" -Value $cmd
}
function Remove-Helper {
  Remove-Item -Path $PROTO_KEY -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $HOME_DIR -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- run by the website: retitra://see-through?opacity=70&click=0 ----
$link = if ($args.Count) { [string]$args[0] } else { "" }
if ($link -match '^retitra:') {
  $m = [regex]::Match($link, 'opacity=(\d{1,3})')
  $opacity = if ($m.Success) { [int]$m.Groups[1].Value } else { 70 }
  $click = $link -match 'click=1'
  # The caption window may have only just opened: look for it for a few seconds.
  for ($i = 0; $i -lt 20; $i++) {
    $h = Find-Captions
    if ($h -ne [IntPtr]::Zero) { [void](Set-SeeThrough $h $opacity $click); break }
    Start-Sleep -Milliseconds 250
  }
  exit
}

# ---- double-clicked: set up, then show the control window ----
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$setupNote = "Set up. See-through in RetiTra now works on this PC."
try { Install-Helper } catch { $setupNote = "Setup failed: " + $_.Exception.Message }

$form = New-Object Windows.Forms.Form
$form.Text = "RetiTra - see-through captions"
$form.Size = New-Object Drawing.Size(440, 350)
$form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false
$form.TopMost = $true; $form.StartPosition = "CenterScreen"
$form.Font = New-Object Drawing.Font("Segoe UI", 9.5)

$note = New-Object Windows.Forms.Label
$note.Location = "15,10"; $note.Size = "400,40"; $note.ForeColor = [Drawing.Color]::DarkGreen
$note.Text = $setupNote + "`nYou can close this window; it is only needed once."
$form.Controls.Add($note)

$status = New-Object Windows.Forms.Label
$status.Location = "15,54"; $status.Size = "400,20"; $status.Text = "Optional: adjust a caption window that is open now."
$form.Controls.Add($status)
$find = New-Object Windows.Forms.Button
$find.Text = "Find caption window"; $find.Location = "15,78"; $find.Size = "190,30"
$form.Controls.Add($find)
$pick = New-Object Windows.Forms.Button
$pick.Text = "Pick by clicking it"; $pick.Location = "220,78"; $pick.Size = "190,30"
$form.Controls.Add($pick)

$lbl = New-Object Windows.Forms.Label
$lbl.Location = "15,118"; $lbl.Size = "400,20"; $lbl.Text = "Opacity: 70%"
$form.Controls.Add($lbl)
$slider = New-Object Windows.Forms.TrackBar
$slider.Location = "10,138"; $slider.Size = "405,45"; $slider.Minimum = 20; $slider.Maximum = 100
$slider.TickFrequency = 10; $slider.Value = 70
$form.Controls.Add($slider)
$clickBox = New-Object Windows.Forms.CheckBox
$clickBox.Location = "15,186"; $clickBox.Size = "400,22"; $clickBox.Text = "Let mouse clicks pass through to the slides"
$form.Controls.Add($clickBox)

$reset = New-Object Windows.Forms.Button
$reset.Text = "Back to normal"; $reset.Location = "15,222"; $reset.Size = "190,30"
$form.Controls.Add($reset)
$remove = New-Object Windows.Forms.Button
$remove.Text = "Remove from this PC"; $remove.Location = "220,222"; $remove.Size = "190,30"
$form.Controls.Add($remove)
$tip = New-Object Windows.Forms.Label
$tip.Location = "15,262"; $tip.Size = "400,40"; $tip.ForeColor = [Drawing.Color]::DimGray
$tip.Text = "Tip: 60-75% with a dark background and yellow or white text (Colours in RetiTra) reads best."
$form.Controls.Add($tip)

$script:target = [IntPtr]::Zero
function Apply {
  if (-not (Set-SeeThrough $script:target $slider.Value $clickBox.Checked)) { $status.Text = "No caption window connected yet." }
  $lbl.Text = "Opacity: $($slider.Value)%"
}
function Connect($h) {
  if ($h -eq [IntPtr]::Zero -or $h -eq $form.Handle) { return $false }
  $script:target = $h
  $status.Text = "Connected to: " + [RT]::Title($h)
  Apply
  return $true
}
$find.Add_Click({ if (-not (Connect (Find-Captions))) { $status.Text = "Not found. Open Float captions first, or use Pick by clicking it." } })
$script:pickTimer = New-Object Windows.Forms.Timer
$script:pickTimer.Interval = 3000
$script:pickTimer.Add_Tick({ $script:pickTimer.Stop(); if (-not (Connect ([RT]::GetForegroundWindow()))) { $status.Text = "No window picked. Try again." } })
$pick.Add_Click({ $status.Text = "Click on the caption window now (3 seconds)..."; $script:pickTimer.Start() })
$slider.Add_ValueChanged({ Apply })
$clickBox.Add_CheckedChanged({ Apply })
$reset.Add_Click({ $clickBox.Checked = $false; $slider.Value = 100; [void](Set-SeeThrough $script:target 100 $false); $status.Text = "Back to normal." })
$remove.Add_Click({
  [void](Set-SeeThrough $script:target 100 $false)
  Remove-Helper
  $note.ForeColor = [Drawing.Color]::DimGray
  $note.Text = "Removed from this PC. See-through in RetiTra stops working until you run this file again."
})
$form.Add_Shown({ [void](Connect (Find-Captions)) })
[void]$form.ShowDialog()
