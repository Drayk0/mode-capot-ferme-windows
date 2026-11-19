# Mode sans veille pour Windows, pendant du menu « Mode capot fermé » du Mac (SwiftBar).
# Icône dans la zone de notification. Tant que c'est actif, le PC ne se met pas en veille tout seul
# (SetThreadExecutionState, lié à ce processus : s'il s'arrête ou si le PC redémarre, la veille revient seule ;
# l'écran, lui, peut toujours s'éteindre). Sur un portable, met aussi « fermeture du capot = ne rien faire »
# et remet l'ancien réglage en coupant, ou au lancement suivant si le PC a redémarré entre-temps.
# Lancement sans fenêtre : conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File veille-off.ps1
# -Apercu : enregistre des captures du menu et de l'icône dans %LOCALAPPDATA%\VeilleOff, sans rien activer.
param([switch]$Apercu)

$ErrorActionPreference = 'Stop'
if (-not $Apercu) {
  $mutex = New-Object Threading.Mutex($false, 'Local\VeilleOff')
  if (-not $mutex.WaitOne(0)) { exit }   # déjà lancé
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Runtime.InteropServices; using System.Windows.Forms;
public static class Natif {
  [DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(int f);  // int : PS 5.1 lit 0x80000001 comme un Int32 négatif
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int t);
  public static void Arrondir(IntPtr h) { int v = 2; DwmSetWindowAttribute(h, 33, ref v, 4); }  // coins ronds de Windows 11
}
public class Sombre : ProfessionalColorTable {
  static Color F = Color.FromArgb(44, 44, 44), S = Color.FromArgb(64, 64, 64), B = Color.FromArgb(72, 72, 72);
  public override Color ToolStripDropDownBackground { get { return F; } }
  public override Color ImageMarginGradientBegin { get { return F; } }
  public override Color ImageMarginGradientMiddle { get { return F; } }
  public override Color ImageMarginGradientEnd { get { return F; } }
  public override Color MenuBorder { get { return B; } }
  public override Color MenuItemBorder { get { return S; } }
  public override Color MenuItemSelected { get { return S; } }
  public override Color SeparatorDark { get { return B; } }
  public override Color SeparatorLight { get { return F; } }
}
'@
[void][Natif]::SetProcessDPIAware()   # icône et menu nets à 150 %
[Windows.Forms.Application]::EnableVisualStyles()

$SEUIL_BATTERIE = 20   # coupure sous ce pourcentage
$SEUIL_ALERTE = 30     # notification sous ce pourcentage
$dossier = "$env:LOCALAPPDATA\VeilleOff"
$sauveCapot = "$dossier\capot-avant.txt"   # réglage du capot avant activation : « secteur batterie »
New-Item -ItemType Directory -Force $dossier | Out-Null

# --- Capot (portables seulement) ---
function Lire-Capot {
  $ErrorActionPreference = 'Continue'   # powercfg écrit sur stderr sans capot ; sous Stop, PS 5.1 en ferait une erreur
  $v = @(powercfg /q SCHEME_CURRENT SUB_BUTTONS LIDACTION 2>$null | Select-String ':\s*0x([0-9a-fA-F]+)\s*$' |
    ForEach-Object { [Convert]::ToInt32($_.Matches[0].Groups[1].Value, 16) })
  if ($v.Count -ge 2) { , $v[-2..-1] }   # secteur, batterie
}
function Poser-Capot($ac, $dc) {
  $ErrorActionPreference = 'Continue'
  # shortcut: vise le mode d'alimentation actif ; si on en change pendant l'activation, l'ancien garde « ne rien faire »
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $ac 2>$null
  powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $dc 2>$null
  powercfg /setactive SCHEME_CURRENT 2>$null
  $LASTEXITCODE -eq 0
}
$aCapot = [bool](Lire-Capot)

function Etat-Batterie {
  $s = [Windows.Forms.SystemInformation]::PowerStatus
  if ($s.BatteryChargeStatus -band [Windows.Forms.BatteryChargeStatus]::NoSystemBattery) { return $null }
  [pscustomobject]@{ Pct = [int]($s.BatteryLifePercent * 100); Secteur = $s.PowerLineStatus -eq 'Online' }
}
$aBatterie = [bool](Etat-Batterie)
$nom = if ($aCapot) { 'Mode capot fermé' } else { 'Mode sans veille' }

# --- Icône : ordinateur (portable ou écran), pastille verte quand c'est actif ---
$police = 'Segoe Fluent Icons'
if ((New-Object Drawing.Font($police, 10)).Name -ne $police) { $police = 'Segoe MDL2 Assets' }
$glyphe = if ($aBatterie) { [char]0xE7F8 } else { [char]0xE7F4 }   # Laptop / TVMonitor
$barreClaire = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).SystemUsesLightTheme -eq 1
$menuSombre = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue).AppsUseLightTheme -ne 1

function Dessiner-Icone([int]$t, [bool]$on) {
  $bmp = New-Object Drawing.Bitmap $t, $t
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAlias'
  $encre = if ($barreClaire) { [Drawing.Color]::Black } else { [Drawing.Color]::White }
  $f = New-Object Drawing.Font($police, [single]($t * 0.8), [Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $g.DrawString($glyphe, $f, (New-Object Drawing.SolidBrush $encre), (New-Object Drawing.RectangleF(0, 0, $t, $t)), $sf)
  if ($on) {
    $d = [single]($t * 0.42); $x = $t - $d
    $g.CompositingMode = 'SourceCopy'   # découpe le dessin sous la pastille
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::Transparent)), $x - 1.5, $x - 1.5, $d + 1.5, $d + 1.5)
    $g.CompositingMode = 'SourceOver'
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(52, 199, 89))), $x, $x, $d - 0.5, $d - 0.5)
  }
  $g.Dispose(); $bmp
}

$ni = New-Object Windows.Forms.NotifyIcon
$script:hIcone = [IntPtr]::Zero
function Maj-Icone {
  $bmp = Dessiner-Icone ([Windows.Forms.SystemInformation]::SmallIconSize.Width) $script:actif
  $h = $bmp.GetHicon(); $bmp.Dispose()
  $ni.Icon = [Drawing.Icon]::FromHandle($h)
  if ($script:hIcone -ne [IntPtr]::Zero) { [void][Natif]::DestroyIcon($script:hIcone) }
  $script:hIcone = $h
  $ni.Text = if ($script:actif) { "$nom : reste $(Reste)" } else { "$nom : désactivé" }
}
function Notifier($texte) { $ni.ShowBalloonTip(5000, $nom, $texte, 'None') }

# --- État ---
$script:actif = $false
$script:fin = $null          # heure de coupure, $null = sans limite
$script:debranche = $false   # avis de débranchement déjà envoyé
$script:alerte = $false      # alerte batterie faible déjà envoyée

function Reste {
  if (-not $script:fin) { return 'sans limite' }
  $s = [math]::Max(0, ($script:fin - (Get-Date)).TotalSeconds)
  $h = [math]::Floor($s / 3600); $m = [math]::Floor(($s % 3600) / 60)
  if ($h) { '{0} h {1:00}' -f $h, $m } else { "$m min" }
}

function Activer([int]$heures) {   # 0 = jusqu'à ce que je coupe
  $p = Etat-Batterie
  if ($p -and -not $p.Secteur -and $p.Pct -lt $SEUIL_BATTERIE) { Notifier "Pas activé : batterie à $($p.Pct) %."; return }
  if (-not $script:actif) {
    if ([Natif]::SetThreadExecutionState(0x80000001) -eq 0) { Notifier 'Pas activé : Windows a refusé.'; return }  # CONTINUOUS | SYSTEM_REQUIRED
    if ($aCapot -and -not (Test-Path $sauveCapot)) {
      $avant = Lire-Capot
      Set-Content $sauveCapot "$($avant[0]) $($avant[1])"
      if (-not (Poser-Capot 0 0)) { Notifier 'Veille bloquée, mais le réglage du capot a été refusé : ne ferme pas le capot.' }
    }
  }
  $script:fin = if ($heures) { (Get-Date).AddHours($heures) } else { $null }
  $script:actif = $true; $script:alerte = $false
  $script:debranche = [bool]($p -and -not $p.Secteur)
  Maj-Icone
  $suite = if ($aBatterie) { " Coupure auto sous $SEUIL_BATTERIE %." } else { '' }
  Notifier "Activé, reste $(Reste).$suite"
}

function Remettre-Capot {
  if (Test-Path $sauveCapot) {
    $v = (Get-Content $sauveCapot -Raw).Trim() -split ' '
    if (Poser-Capot $v[0] $v[1]) { Remove-Item $sauveCapot }
  }
}

function Desactiver($raison) {
  [void][Natif]::SetThreadExecutionState(0x80000000)
  Remettre-Capot
  $script:actif = $false
  Maj-Icone
  if ($raison) { Notifier "Désactivé : $raison." }
}

# --- Garde, toutes les 20 s ---
$garde = New-Object Windows.Forms.Timer
$garde.Interval = 20000
$garde.Add_Tick({
  if (-not $script:actif) { return }
  if ($script:fin -and (Get-Date) -ge $script:fin) { Desactiver 'durée écoulée'; return }
  $p = Etat-Batterie
  if ($p -and $p.Secteur) { $script:debranche = $false; $script:alerte = $false }
  elseif ($p) {
    if ($p.Pct -lt $SEUIL_BATTERIE) { Desactiver "batterie à $($p.Pct) %"; return }
    if (-not $script:debranche) { $script:debranche = $true; Notifier "Débranché : il reste actif et se coupera sous $SEUIL_BATTERIE % de batterie." }
    if ($p.Pct -lt $SEUIL_ALERTE -and -not $script:alerte) { $script:alerte = $true; Notifier "Batterie à $($p.Pct) % : coupure à $SEUIL_BATTERIE %, branche le PC pour le garder actif." }
  }
  Maj-Icone   # infobulle à jour
})

# --- Menu ---
$menu = New-Object Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $false
$menu.Font = New-Object Drawing.Font('Segoe UI', 10)
if ($menuSombre) {
  $menu.Renderer = New-Object Windows.Forms.ToolStripProfessionalRenderer (New-Object Sombre)
  $menu.ForeColor = [Drawing.Color]::FromArgb(240, 240, 240)
}
$petit = New-Object Drawing.Font('Segoe UI', 8.5)
$gris = if ($menuSombre) { [Drawing.Color]::FromArgb(140, 140, 140) } else { [Drawing.Color]::FromArgb(110, 110, 110) }

function Ajouter($texte, [scriptblock]$action, [switch]$Info) {
  $it = New-Object Windows.Forms.ToolStripMenuItem $texte
  $it.Padding = New-Object Windows.Forms.Padding(0, 3, 0, 3)
  if ($Info) { $it.Font = $petit }
  if ($action) { $it.Add_Click($action) } else { $it.Enabled = $false }
  [void]$menu.Items.Add($it)
}
function Separateur { [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator)) }

function Construire-Menu {
  $menu.Items.Clear()
  if ($script:actif) { Ajouter "✓  $nom : activé (reste $(Reste))" } else { Ajouter "$nom : désactivé" }
  Separateur
  Ajouter 'Activer pour 1 h' { Activer 1 }
  Ajouter 'Activer pour 4 h' { Activer 4 }
  Ajouter 'Activer pour 12 h' { Activer 12 }
  Ajouter "Jusqu'à ce que je coupe" { Activer 0 }
  if ($script:actif) { Ajouter 'Désactiver' { Desactiver } }
  Separateur
  if ($aBatterie) { Ajouter "Coupure auto sous $SEUIL_BATTERIE % de batterie ou si le PC redémarre" -Info }
  else { Ajouter 'Coupure auto si le PC redémarre' -Info }
  if ($aCapot) { Ajouter "Garde-le à l'air libre" -Info }
  Ajouter 'Quitter' { Desactiver; $ni.Visible = $false; [Windows.Forms.Application]::Exit() } -Info
  # le rendu désactivé grise déjà le texte ; on garde juste le gris plus doux des infos
  foreach ($it in $menu.Items) { if ($it.Font -eq $petit -and $it.Enabled) { $it.ForeColor = $gris } }
}
$menu.Add_Opening({ Construire-Menu })
Construire-Menu   # un menu vide au premier affichage se dimensionne mal
$menu.Add_Opened({ [Natif]::Arrondir($menu.Handle) })

$ni.ContextMenuStrip = $menu
$ni.Add_MouseUp({ param($s, $e)   # clic gauche : même menu que le clic droit
  if ($e.Button -eq 'Left') { $ni.GetType().GetMethod('ShowContextMenu', [Reflection.BindingFlags]'Instance,NonPublic').Invoke($ni, $null) }
})

if ($Apercu) {
  foreach ($etape in 'off', 'on') {
    if ($etape -eq 'on') { $script:actif = $true; $script:fin = (Get-Date).AddHours(4).AddMinutes(1) }   # état simulé, rien n'est appliqué
    $menu.Show(200, 200)
    1..30 | ForEach-Object { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    $r = $menu.Bounds
    $b = New-Object Drawing.Bitmap $r.Width, $r.Height
    $menu.DrawToBitmap($b, (New-Object Drawing.Rectangle(0, 0, $r.Width, $r.Height)))   # la capture d'écran arrive trop tôt sous RDP
    $b.Save("$dossier\apercu-menu-$etape.png")
    $menu.Close()
    $fond = New-Object Drawing.Bitmap 96, 96   # icône posée sur la couleur de la barre des tâches
    $g = [Drawing.Graphics]::FromImage($fond)
    $g.Clear($(if ($barreClaire) { [Drawing.Color]::FromArgb(238, 238, 238) } else { [Drawing.Color]::FromArgb(32, 32, 32) }))
    $g.DrawImage((Dessiner-Icone 64 $script:actif), 16, 16); $g.Dispose()
    $fond.Save("$dossier\apercu-icone-$etape.png")
  }
  exit
}

Maj-Icone
$ni.Visible = $true
# Le PC a redémarré (ou le script a été tué) pendant une activation : remettre le capot comme avant
if (Test-Path $sauveCapot) { Remettre-Capot; Notifier 'Désactivé : le PC a redémarré.' }
$garde.Start()
[Windows.Forms.Application]::Run()
$ni.Dispose()
