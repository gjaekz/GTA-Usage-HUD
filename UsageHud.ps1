param([switch]$Preview, [string]$PreviewPath, [switch]$CheckUsage)
$ErrorActionPreference='Stop'
function Resolve-CodexExecutable {
  if($env:CODEX_EXECUTABLE){
    if(Test-Path -LiteralPath $env:CODEX_EXECUTABLE -PathType Leaf){return (Resolve-Path -LiteralPath $env:CODEX_EXECUTABLE).Path}
    throw "CODEX_EXECUTABLE does not point to a file: $env:CODEX_EXECUTABLE"
  }
  $command=Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)){return $command.Source}
  $binRoot=Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/bin'
  $candidate=Get-ChildItem -LiteralPath $binRoot -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if($candidate){return $candidate.FullName}
  throw 'Could not find codex.exe. Install and sign in to Codex, or set CODEX_EXECUTABLE to the full path of codex.exe.'
}
$codex=Resolve-CodexExecutable
$usagePath=Join-Path $PSScriptRoot 'usage.json'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class HudNative {
 [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int i);
 [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h,int i,int v);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback,IntPtr extra);
 [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h,int id,uint modifiers,uint virtualKey);
 [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h,int id);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextLength(IntPtr h);
 [DllImport("user32.dll", EntryPoint="GetWindowLongW")] static extern int GetWindowLong32(IntPtr h,int index);
 [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr64(IntPtr h,int index);
 [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h,uint command);
 [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h,int attribute,out int value,int size);
 delegate bool EnumWindowsProc(IntPtr h,IntPtr extra);
 static int ExStyle(IntPtr h) { return IntPtr.Size==8 ? GetWindowLongPtr64(h,-20).ToInt32() : GetWindowLong32(h,-20); }
 public static bool IsRestoredMainWindow(bool visible,bool iconic,bool titled,bool toolWindow,bool owned,bool cloaked,string name) {
  return visible && !iconic && titled && !toolWindow && !owned && !cloaked &&
   (String.Equals(name,"Codex",StringComparison.OrdinalIgnoreCase) || String.Equals(name,"ChatGPT",StringComparison.OrdinalIgnoreCase));
 }
 public static bool HasRestoredAppWindow() {
  bool found=false;
  EnumWindows(delegate(IntPtr h,IntPtr extra) {
   if(!IsWindowVisible(h) || IsIconic(h) || GetWindowTextLength(h)==0) return true;
   bool tool=(ExStyle(h)&0x80)!=0, owned=GetWindow(h,4)!=IntPtr.Zero;
   int cloakedValue=0; bool cloaked=DwmGetWindowAttribute(h,14,out cloakedValue,sizeof(int))==0 && cloakedValue!=0;
   uint pid; GetWindowThreadProcessId(h,out pid);
   try { string name=System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
    if(IsRestoredMainWindow(true,false,true,tool,owned,cloaked,name)) { found=true; return false; }
   } catch {}
   return true;
  },IntPtr.Zero);
  return found;
 }
}
'@
function Get-LiveUsage {
  $psi=[Diagnostics.ProcessStartInfo]::new($codex,'app-server --stdio'); $psi.UseShellExecute=$false; $psi.RedirectStandardInput=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true; $psi.CreateNoWindow=$true
  $p=[Diagnostics.Process]::new();$p.StartInfo=$psi
  $p.Start()|Out-Null;$errTask=$p.StandardError.ReadToEndAsync()
  $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"clientInfo":{"name":"usage-hud","title":"Usage HUD","version":"1.0"},"capabilities":{}}}');$p.StandardInput.Flush()
  $deadline=[datetime]::UtcNow.AddSeconds(8);$initialized=$false
  while([datetime]::UtcNow -lt $deadline -and !$initialized){$task=$p.StandardOutput.ReadLineAsync();$wait=[math]::Max(1,[int]($deadline-[datetime]::UtcNow).TotalMilliseconds);if(!$task.Wait($wait)){break};try{$item=$task.Result|ConvertFrom-Json;$initialized=($item.id -eq 1)}catch{}}
  if(!$initialized){if(!$p.HasExited){$p.Kill()};throw 'Codex app-server initialization timed out.'}
  $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"initialized","params":{}}');$p.StandardInput.Flush()
  $p.StandardInput.WriteLine('{"jsonrpc":"2.0","method":"account/rateLimits/read","id":2,"params":{}}');$p.StandardInput.Flush()
  $deadline=[datetime]::UtcNow.AddSeconds(8);$resp=$null
  while([datetime]::UtcNow -lt $deadline -and !$resp){$task=$p.StandardOutput.ReadLineAsync();$wait=[math]::Max(1,[int]($deadline-[datetime]::UtcNow).TotalMilliseconds);if(!$task.Wait($wait)){break};try{$item=$task.Result|ConvertFrom-Json;if($item.id -eq 2){$resp=$item}}catch{}}
  $p.StandardInput.Close(); if(!$p.HasExited){$p.Kill()}
  if(!$resp){throw 'No rate limit response from Codex app-server.'}
  if($resp.error){throw 'Codex app-server returned an error.'}
  $d=$resp.result.rateLimits; if(!$d){$d=$resp.result}
  if($resp.error){throw 'Codex app-server returned an error.'}
  $primary=$d.primary; $secondary=$d.secondary
  if(!$primary -or !$secondary){throw 'Rate limits unavailable or response shape changed.'}
  [pscustomobject]@{ fiveRemaining=[math]::Max(0,100-[double]$primary.usedPercent); weekRemaining=[math]::Max(0,100-[double]$secondary.usedPercent); fiveReset=[double]$primary.resetsAt; weekReset=[double]$secondary.resetsAt; fetched=[datetime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $usagePath -Encoding utf8
}
if($CheckUsage){Get-LiveUsage; Get-Content $usagePath; exit}
$settingsPath=Join-Path $PSScriptRoot 'hud-settings.json'
$settings=[pscustomobject]@{left=16.0;top=16.0;width=378.0;topmost=$true;editing=$true}
if(Test-Path $settingsPath){try{$saved=Get-Content $settingsPath -Raw|ConvertFrom-Json;foreach($key in 'left','top','width','topmost','editing'){if($null -ne $saved.$key){$settings.$key=$saved.$key}}}catch{}}
$settings.width=[math]::Min(1000,[math]::Max(230,[double]$settings.width))
$created=$false
$script:instanceMutex=[Threading.Mutex]::new($true,'Local\CodexUsageHud',[ref]$created)
if(!$created){exit}
$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="378" Height="168" WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize">
 <Viewbox x:Name="HudView" Stretch="Uniform"><Grid x:Name="HudRoot" Width="378" Height="168" Background="Transparent"><StackPanel VerticalAlignment="Top" Margin="0,5,0,0">
  <Grid Height="40" Margin="0,0,0,12"><Ellipse Width="40" Height="40" Fill="#FF25252C" HorizontalAlignment="Left"/><Path Data="M20,36 C17,33 4,24 4,14 C4,4 16,2 20,11 C24,2 36,4 36,14 C36,24 23,33 20,36 Z" Fill="#FFEFAFC8" Width="22" Height="20" Stretch="Fill" HorizontalAlignment="Left" Margin="9,10,0,0"/><Border Width="326" Height="20" Background="#202329" BorderBrush="#3C3D44" BorderThickness="1" HorizontalAlignment="Left" Margin="48,10,0,0"><Grid><Border x:Name="PinkFill" Background="#FFEFAFC8" CornerRadius="1" HorizontalAlignment="Left"/><Border x:Name="Divider" Width="1" Background="#66FFFFFF" HorizontalAlignment="Left"/></Grid></Border></Grid>
  <Grid Height="40" Margin="0,0,0,12"><Ellipse Width="40" Height="40" Fill="#FF25252C" HorizontalAlignment="Left"/><Path Data="M22,3 L9,22 L17,22 L13,37 L29,16 L21,16 Z" Fill="#FF6BE1D1" Width="20" Height="24" Stretch="Fill" HorizontalAlignment="Left" Margin="10,8,0,0"/><Border Width="237" Height="20" Background="#202329" BorderBrush="#3C3D44" BorderThickness="1" HorizontalAlignment="Left" Margin="48,10,0,0"><Grid><Border x:Name="MintFill" Background="#FF6BE1D1" CornerRadius="1" HorizontalAlignment="Left"/></Grid></Border></Grid>
  <Grid Height="40"><Ellipse Width="40" Height="40" Fill="#FF25252C" HorizontalAlignment="Left"/><Path Data="M2,12 C7,3 21,3 26,12 C21,21 7,21 2,12 Z" Stroke="#FFA084F5" StrokeThickness="2" Fill="Transparent" Width="26" Height="18" Stretch="Fill" HorizontalAlignment="Left" Margin="7,11,0,0"/><Ellipse Width="6" Height="6" Fill="#FFA084F5" HorizontalAlignment="Left" Margin="17,17,0,0"/><Border Width="204" Height="20" Background="#202329" BorderBrush="#3C3D44" BorderThickness="1" HorizontalAlignment="Left" Margin="48,10,0,0"><Grid><Border x:Name="PurpleFill" Background="#FFA084F5" CornerRadius="1" HorizontalAlignment="Left"/></Grid></Border></Grid>
 </StackPanel><Border x:Name="ResizeHandle" Width="16" Height="16" HorizontalAlignment="Right" VerticalAlignment="Bottom" Background="#CC272831" CornerRadius="3" Cursor="SizeNWSE" Margin="0,0,1,1"><Path Data="M3,12 L12,3 M7,13 L13,7" Stroke="#FFB7B7C2" StrokeThickness="1.4"/></Border></Grid></Viewbox></Window>
'@
$reader=[Xml.XmlNodeReader]::new([xml]$xaml); $win=[Windows.Markup.XamlReader]::Load($reader)
$wp=New-Object Windows.Interop.WindowInteropHelper($win); $null=$wp
$script:PinkFill=$win.FindName('PinkFill');$script:MintFill=$win.FindName('MintFill');$script:PurpleFill=$win.FindName('PurpleFill');$script:Divider=$win.FindName('Divider');$script:resizeGrip=$win.FindName('ResizeHandle')
function Save-Settings {if($script:restoringSettings){return};$settings.left=[double]$win.Left;$settings.top=[double]$win.Top;$settings.width=[double]$win.Width;$settings|ConvertTo-Json|Set-Content -LiteralPath $settingsPath -Encoding utf8}
function Set-EditMode([bool]$enabled){$settings.editing=$enabled;$style=[HudNative]::GetWindowLong($wp.Handle,-20);if($enabled){$style=$style -band (-bnot 0x20);$script:resizeGrip.Visibility='Visible'}else{$style=$style -bor 0x20;$script:resizeGrip.Visibility='Collapsed'};[HudNative]::SetWindowLong($wp.Handle,-20,$style)|Out-Null;$editItem.Text=if($enabled){if($script:hotkeyRegistered){'Lock layout (Ctrl+Alt+H to unlock)'}else{'Lock layout'}}else{if($script:hotkeyRegistered){'Unlock layout (Ctrl+Alt+H)'}else{'Edit layout'}};Save-Settings}
function Refresh-Hud {
 if(!(Test-Path $usagePath)){if($script:tray){$script:tray.Text='Codex usage HUD - stale'};return}; try{$u=Get-Content $usagePath -Raw | ConvertFrom-Json}catch{return}
 $age=([datetime]::UtcNow-[datetime]$u.fetched).TotalSeconds
 $sec=[math]::Max(0,[double]$u.fiveReset-[datetimeOffset]::UtcNow.ToUnixTimeSeconds()); $ts=[timespan]::FromSeconds($sec)
 $script:PinkFill.Width=326*[math]::Min(1.0,[math]::Max(0.0,$u.fiveRemaining/100)); $script:Divider.Margin=[Windows.Thickness]::new(326*.31,0,0,0)
 $script:MintFill.Width=237*[math]::Min(1.0,[math]::Max(0.0,$u.weekRemaining/100)); $script:PurpleFill.Width=204*[math]::Min(1.0,[math]::Max(0.0,$sec/18000))
 if($age -gt 300){$script:PinkFill.Width=0;$script:MintFill.Width=0;$script:PurpleFill.Width=0}
 if($script:tray){$script:tray.Text=if($age -gt 300){'Codex usage HUD - stale'}else{"Codex 5h $([math]::Round($u.fiveRemaining))%; weekly $([math]::Round($u.weekRemaining))%; reset $($ts.ToString('h\:mm'))"}}
}
if(Test-Path $usagePath){Refresh-Hud}
if($Preview){$win.Show();$win.UpdateLayout();$bmp=[Windows.Media.Imaging.RenderTargetBitmap]::new(378,168,96,96,[Windows.Media.PixelFormats]::Pbgra32);$bmp.Render($win);$fs=[IO.File]::Open($PreviewPath,[IO.FileMode]::Create);$enc=[Windows.Media.Imaging.PngBitmapEncoder]::new();$enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp));$enc.Save($fs);$fs.Close();$win.Close();exit}
$script:tray=New-Object Windows.Forms.NotifyIcon; $script:tray.Icon=[Drawing.SystemIcons]::Information; $script:tray.Text='Codex usage HUD'; $menu=New-Object Windows.Forms.ContextMenuStrip
$script:editItem=$menu.Items.Add('Lock layout', $null,{$settings.editing=!$settings.editing;Set-EditMode $settings.editing})
$script:topItem=$menu.Items.Add('Always on top', $null,{$settings.topmost=!$settings.topmost;$win.Topmost=[bool]$settings.topmost;$script:topItem.Checked=[bool]$settings.topmost;Save-Settings});$script:topItem.Checked=[bool]$settings.topmost
$sizes=$menu.Items.Add('Size');$sizeMenu=New-Object Windows.Forms.ToolStripDropDownMenu;$sizes.DropDown=$sizeMenu;foreach($spec in @(@('Small',270),@('Medium',378),@('Large',500))){$label=$spec[0];$value=$spec[1];$null=$sizeMenu.Items.Add($label,$null,{ $win.Width=$value;$win.Height=$value*168/378;Save-Settings }.GetNewClosure())};$null=$sizeMenu.Items.Add('Reset position',$null,{$win.Left=16;$win.Top=16;$win.Width=378;$win.Height=168;$win.Topmost=$true;$settings.topmost=$true;$script:topItem.Checked=$true;Save-Settings})
$null=$menu.Items.Add('Refresh usage', $null,{$script:nextPoll=[datetime]::MinValue;Start-Poll}); $null=$menu.Items.Add('Usage: Codex Work account (5h / weekly)', $null,{}); $null=$menu.Items.Add('Exit', $null,{$timer.Stop();if($script:pollJob){Stop-Job $script:pollJob -ErrorAction SilentlyContinue;Remove-Job $script:pollJob -Force -ErrorAction SilentlyContinue};$script:tray.Visible=$false;$win.Close();$app.Shutdown()}); $script:tray.ContextMenuStrip=$menu; $script:tray.Visible=$true
$script:hotkeyId=0x4A31;$script:hotkeyRegistered=$false;$script:restoringSettings=$true;$script:hotkeyHook=$null
$win.Add_SourceInitialized({$h=$wp.Handle;$style=[HudNative]::GetWindowLong($h,-20);[HudNative]::SetWindowLong($h,-20,$style -bor 0x80 -bor 0x08000000)|Out-Null;$script:hotkeyRegistered=[HudNative]::RegisterHotKey($h,$script:hotkeyId,0x0001 -bor 0x0002,0x48);if(!$script:hotkeyRegistered){$warning=$menu.Items.Add('Ctrl+Alt+H unavailable; use tray to unlock');$warning.Enabled=$false};Set-EditMode ([bool]$settings.editing);$win.Topmost=[bool]$settings.topmost;$source=[Windows.Interop.HwndSource]::FromHwnd($h);$script:hotkeyHook=[Windows.Interop.HwndSourceHook]{param($hwnd,$message,$wParam,$lParam,[ref]$handled);if($message -eq 0x0312 -and $wParam.ToInt32() -eq $script:hotkeyId){Set-EditMode $true;$handled.Value=$true;return [IntPtr]::new(1)};return [IntPtr]::Zero};$source.AddHook($script:hotkeyHook)})
$win.Add_PreviewMouseRightButtonUp({param($sender,$eventArgs);$eventArgs.Handled=$true;$menu.Show([Windows.Forms.Cursor]::Position)})
$win.Add_Loaded({$win.Width=$settings.width;$win.Height=$settings.width*168/378;$win.Left=$settings.left;$win.Top=$settings.top;$area=[Windows.SystemParameters]::WorkArea;if($win.Left -gt $area.Right -or $win.Left+$win.Width -lt $area.Left -or $win.Top -gt $area.Bottom -or $win.Top+$win.Height -lt $area.Top){$win.Left=$area.Left+16;$win.Top=$area.Top+16};$script:restoringSettings=$false;$win.Add_LocationChanged({Save-Settings});$win.Add_SizeChanged({if($win.Width -gt 0){$height=$win.Width*168/378;if([math]::Abs($win.Height-$height) -gt 1){$win.Height=$height};Save-Settings}})})
$script:dragOrigin=$null;$win.Add_MouseLeftButtonDown({if($settings.editing -and $win.IsMouseCaptured -eq $false){try{$win.DragMove()}catch{}}});$resize=$win.FindName('ResizeHandle');$resize.Add_MouseLeftButtonDown({if($settings.editing){$script:dragOrigin=[Windows.Point]::new([Windows.Forms.Cursor]::Position.X,[Windows.Forms.Cursor]::Position.Y);$resize.CaptureMouse();$_.Handled=$true}});$resize.Add_MouseMove({if($settings.editing -and $resize.IsMouseCaptured -and $script:dragOrigin){$pt=[Windows.Forms.Cursor]::Position;$w=[math]::Min(1000,[math]::Max(230,$win.Width+($pt.X-$script:dragOrigin.X)));$win.Width=$w;$win.Height=$w*168/378;$script:dragOrigin=[Windows.Point]::new($pt.X,$pt.Y)}});$resize.Add_MouseLeftButtonUp({if($resize.IsMouseCaptured){$resize.ReleaseMouseCapture();Save-Settings}})
$script:pollBusy=$false
function Start-Poll { if($script:pollBusy){return};$script:pollBusy=$true;$script:nextPoll=[datetime]::UtcNow.AddMinutes(1);$script:pollJob=Start-Job -ScriptBlock {param($file) & powershell -NoProfile -ExecutionPolicy Bypass -File $file -CheckUsage | Out-Null} -ArgumentList $PSCommandPath }
$script:nextPoll=[datetime]::MinValue
$app=[Windows.Application]::new();$app.ShutdownMode=[Windows.ShutdownMode]::OnExplicitShutdown
$timer=New-Object Windows.Threading.DispatcherTimer; $timer.Interval=[timespan]::FromMilliseconds(500);$timer.Add_Tick({ if($script:pollJob -and $script:pollJob.State -in @('Completed','Failed','Stopped')){Remove-Job $script:pollJob -Force;$script:pollJob=$null;$script:pollBusy=$false;Refresh-Hud}; if(!$script:pollBusy -and [datetime]::UtcNow -ge $script:nextPoll){Start-Poll}; Refresh-Hud; $visible=[HudNative]::HasRestoredAppWindow(); if($visible -and !$win.IsVisible){$win.Show()};if(!$visible -and $win.IsVisible){$win.Hide()} });$timer.Start();Start-Poll
$app.MainWindow=$win;$null=$wp.Handle
if([HudNative]::HasRestoredAppWindow()){$win.Show()}
$app.Run()|Out-Null; if($script:hotkeyRegistered){[HudNative]::UnregisterHotKey($wp.Handle,$script:hotkeyId)|Out-Null};$script:tray.Visible=$false; $script:instanceMutex.ReleaseMutex();$script:instanceMutex.Dispose()
