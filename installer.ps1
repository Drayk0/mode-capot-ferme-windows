# Installe le menu « Mode capot fermé » : copie dans %LOCALAPPDATA%\VeilleOff, lancement à l'ouverture de session, démarrage tout de suite.
# Lancé par installer.cmd / desinstaller.cmd (double-clic, pas besoin d'être admin). -Desinstaller pour tout enlever.
param([switch]$Desinstaller)

$d = "$env:LOCALAPPDATA\VeilleOff"
$lien = "$([Environment]::GetFolderPath('Startup'))\Mode capot fermé.lnk"

# Arrêter une copie déjà lancée (par son PID exact), en coupant proprement n'importe quelle activation en cours
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object CommandLine -like "*$d\veille-off.ps1*" |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
if (Test-Path "$d\capot-avant.txt") {   # le capot avait été mis sur « ne rien faire » : remettre l'ancien réglage
  $v = (Get-Content "$d\capot-avant.txt" -Raw).Trim() -split ' '
  powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $v[0]
  powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION $v[1]
  powercfg /setactive SCHEME_CURRENT
  Remove-Item "$d\capot-avant.txt"
}

if ($Desinstaller) {
  Remove-Item $lien, $d -Recurse -Force -ErrorAction SilentlyContinue
  'Désinstallé.'; return
}

New-Item -ItemType Directory -Force $d | Out-Null
Copy-Item "$PSScriptRoot\veille-off.ps1" "$d\veille-off.ps1" -Force

$sh = (New-Object -ComObject WScript.Shell).CreateShortcut($lien)
$sh.TargetPath = "$env:WINDIR\System32\conhost.exe"
$sh.Arguments = "--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$d\veille-off.ps1`""
$sh.WindowStyle = 7
$sh.Save()

Start-Process $sh.TargetPath $sh.Arguments
'Installé : l''icône est dans la zone de notification (flèche ^ en bas à droite si elle est cachée).'
