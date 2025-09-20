# =================== All-in Dev Setup (Windows, Miniforge) ===================
# - Install Miniforge (conda-forge, with mamba)
# - Create env: agent_test
# - Install lemonade-sdk[dev,oga-ryzenai] (in agent_test, first thing)
# - Install MCP CLIs via npm (scoped to env)
# - Start MySQL 8 in Docker (restart unless-stopped, persistent volume)
# - (Removed) Creating "lemon" env

$ErrorActionPreference = "Stop"

# ---------------- Utilities (PS 5.1 safe) ----------------
function Test-CommandOrInstall {
  param(
    [Parameter(Mandatory=$true)] [string] $Name,
    [Parameter(Mandatory=$true)] [scriptblock] $InstallAction
  )
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) { & $InstallAction }
  else { Write-Host "[OK] $Name found" -ForegroundColor Green }
}
function Stop-Setup { param([string]$Message) Write-Error $Message; exit 1 }

# ---------------- 1) Miniforge ----------------
$InstallMiniforge = {
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host "[*] Installing Miniforge..." -ForegroundColor Yellow
    winget install -e --id CondaForge.Miniforge3
  } else {
    Stop-Setup "winget not found. Install App Installer from Microsoft Store or install Miniforge manually."
  }
}
Test-CommandOrInstall -Name conda -InstallAction $InstallMiniforge

# Load conda into this session even if not initialized yet
$condaRoot = "$env:USERPROFILE\miniforge3"
try { conda init powershell | Out-Null } catch {}
if (Test-Path "$condaRoot\condabin\conda.bat") {
  (& "$condaRoot\condabin\conda.bat" "shell.powershell" "hook") | Out-String | Invoke-Expression
} elseif (Test-Path "$condaRoot\shell\condabin\conda-hook.ps1") {
  . "$condaRoot\shell\condabin\conda-hook.ps1"
} elseif (Test-Path "$condaRoot\Scripts\activate.bat") {
  & "$condaRoot\Scripts\activate.bat" | Out-Null
}

# Prefer mamba if available
$Solver = "conda"
if (Get-Command mamba -ErrorAction SilentlyContinue) { $Solver = "mamba" }

# ---------------- 2) Create/activate main env ----------------
$envName = "agent_test"
if (-not (conda env list | Select-String "^\s*$envName\s")) {
  & $Solver create -y -n $envName -c conda-forge python=3.10
}
conda activate $envName

# ---------------- 3) (FIRST) Lemonade SDK in agent_test ----------------
python -m pip install -U pip wheel
# 直接把 lemonade 裝進 agent_test；保留 AMD 來源與 extras
pip install -U "lemonade-sdk[dev,oga-ryzenai]" --extra-index-url=https://pypi.amd.com/simple

# ---------------- 4) Node.js in env ----------------
& $Solver install -y -n $envName -c conda-forge nodejs=20.*

# Scope npm "global" to this env (PS 5.1 safe hooks)
$prefix  = Join-Path $env:CONDA_PREFIX "npm-global"
$actDir  = Join-Path $env:CONDA_PREFIX "etc\conda\activate.d"
$deactDir= Join-Path $env:CONDA_PREFIX "etc\conda\deactivate.d"
New-Item -ItemType Directory -Force $prefix, $actDir, $deactDir | Out-Null

# Single-quoted here-strings so expansion happens at activate time.
$activatePs1 = @'
# scope npm prefix to current conda env
$prefix = Join-Path $env:CONDA_PREFIX 'npm-global'
$env:NPM_CONFIG_PREFIX = $prefix
$paths = $env:PATH -split ';'
if ($paths -notcontains $prefix) {
  $env:PATH = "$prefix;$env:PATH"
}
'@
Set-Content -Path (Join-Path $actDir 'npm_prefix.ps1') -Value $activatePs1 -Encoding ASCII

$deactivatePs1 = @'
# remove npm prefix scoped to this env
$prefix = Join-Path $env:CONDA_PREFIX 'npm-global'
if ($env:NPM_CONFIG_PREFIX -eq $prefix) { Remove-Item Env:\NPM_CONFIG_PREFIX -ErrorAction SilentlyContinue }
$paths = ($env:PATH -split ';') | Where-Object { $_ -and ($_ -ne $prefix) }
$env:PATH = [string]::Join(';', $paths)
'@
Set-Content -Path (Join-Path $deactDir 'npm_prefix.ps1') -Value $deactivatePs1 -Encoding ASCII

# Reload env so npm prefix takes effect
conda deactivate
conda activate $envName

# ---------------- 5) Python packages in env ----------------
# 用 conda 安裝二進位友善套件
& $Solver install -y -n $envName -c conda-forge sqlalchemy mysqlclient
# 其他用 pip
python -m pip install "tf-keras==2.20.*"
pip install -U PySide6
pip install -U huggingface_hub==0.33.0 modelcontextprotocol fastmcp deepface

# ---------------- 6) MCP CLIs (scoped to env via npm prefix) ----------------
npm install -g @modelcontextprotocol/sdk @modelcontextprotocol/inspector

# ---------------- 7) MySQL 8 — Docker (restart + persistent volume) ----------------
Write-Host "`n[*] Starting MySQL in Docker..." -ForegroundColor Yellow

function Get-FirstFreePort {
  param([int]$Start = 3306)
  $p = $Start
  while ((netstat -ano | Select-String "LISTENING\s+.*:$p\s")) { $p++ }
  return $p
}

# Ensure Docker Desktop is running and daemon is ready
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Stop-Setup "Docker not found. Install Docker Desktop first, or switch to a ZIP/system install."
}
if (-not (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)) {
  $dockerExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
  if (Test-Path $dockerExe) { Start-Process $dockerExe | Out-Null }
}
$daemonReady = $false
for ($i=0; $i -lt 60 -and -not $daemonReady; $i++) {
  docker info *> $null
  if ($LASTEXITCODE -eq 0) { $daemonReady = $true; break }
  Start-Sleep -Seconds 3
}
if (-not $daemonReady) { Stop-Setup "Docker daemon not ready. Open Docker Desktop and retry." }

# Choose a host port (3306 if free, otherwise 3307, 3308, ...)
$hostPort = Get-FirstFreePort -Start 3306

# Persistent data dir under user profile
$dataDir = Join-Path $env:USERPROFILE "mysql-data"
New-Item -ItemType Directory -Force $dataDir | Out-Null

# Root password: from env or generated (alphanumeric)
$ROOT = $env:MYSQL_ROOT_PASSWORD
$generatedRoot = $false
if (-not $ROOT) {
  $chars = ([char[]](48..57 + 65..90 + 97..122))
  $ROOT = -join (1..20 | ForEach-Object { $chars | Get-Random })
  $generatedRoot = $true
}

# Remove old container and start a new one
docker rm -f mysql80 *> $null
$runArgs = @(
  "run","-d","--name","mysql80",
  "--restart","unless-stopped",
  "-p","$($hostPort):3306",
  "-v",("$dataDir" + ":/var/lib/mysql"),
  "-e","MYSQL_ROOT_PASSWORD=$ROOT",
  "-e","MYSQL_DATABASE=mcp-test",
  "-e","MYSQL_USER=mcp",
  "-e","MYSQL_PASSWORD=123456",
  "mysql:8.4"
)
docker @runArgs
if ($LASTEXITCODE -ne 0) { Stop-Setup "Failed to start mysql:8.4 container." }

# Wait for the port to accept TCP
$deadline = (Get-Date).AddMinutes(2)
$ready = $false
while (-not $ready -and (Get-Date) -lt $deadline) {
  $t = Test-NetConnection -ComputerName 127.0.0.1 -Port $hostPort
  if ($t.TcpTestSucceeded) { $ready = $true; break }
  Start-Sleep -Seconds 3
}
if (-not $ready) { Stop-Setup "MySQL container did not become ready on port $hostPort." }

# Save credentials to a file next to this script
$pwdFile = Join-Path $PSScriptRoot "mysql-credentials.txt"
"ROOT_PASSWORD=$ROOT`r`nHOST_PORT=$hostPort" | Set-Content -Path $pwdFile -Encoding ASCII

Write-Host "`n[OK] MySQL container is running." -ForegroundColor Green
Write-Host (" - Container : mysql80")
Write-Host (" - Image     : mysql:8.4")
Write-Host (" - Host Port : {0} -> 3306" -f $hostPort)
Write-Host (" - Saved credentials to: {0}" -f $pwdFile) -ForegroundColor Yellow
if ($generatedRoot) {
  Write-Host (" - ROOT password (display): {0}" -f $ROOT) -ForegroundColor Yellow
} else {
  Write-Host " - ROOT password: from env MYSQL_ROOT_PASSWORD" -ForegroundColor Yellow
}
Write-Host "`nUse these in your JSON args:" -ForegroundColor Cyan
Write-Host ("--mysql --host localhost --database mcp-test --port {0} --user mcp --password 123456" -f $hostPort)

# ---------------- 8) Versions ----------------
Write-Host "`n=== Versions (agent_test) ===" -ForegroundColor Green
python --version
node --version
npm --version
pip --version
conda --version
if (Get-Command inspector -ErrorAction SilentlyContinue) { inspector --version }
pip show lemonade-sdk | Select-String 'Version'
if (Get-Command mysql -ErrorAction SilentlyContinue) { mysql --version }

Write-Host "`n[Done] Environments ready." -ForegroundColor Green
Write-Host "Activate:  conda activate $envName"
Write-Host "MySQL (Docker): docker logs mysql80"

# ---------------- 9) Rebase agent.json paths (remove \installer\ segment; PS5-safe; UTF-8 no BOM) ----------------
try {
  # 取得執行檔/腳本所在資料夾
  $Root = $PSScriptRoot
  if (-not $Root) {
    $Root = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
  }

  # 去除路徑中的 "\installer\" 段（不分大小寫）。若為結尾的 "\installer" 也一併處理。
  $norm  = $Root.TrimEnd('\','/')
  $lower = $norm.ToLower()
  $pos   = $lower.LastIndexOf('\installer\')
  if ($pos -ge 0) {
    $BaseRoot = $norm.Substring(0, $pos)
  } elseif ($lower.EndsWith('\installer')) {
    $BaseRoot = Split-Path -Parent $norm
  } else {
    $BaseRoot = $Root
  }

  # 目標 JSON 檔（若檔名不同請改這行）
  $cfgFile = Join-Path $BaseRoot 'agent.json'
  if (-not (Test-Path -LiteralPath $cfgFile)) {
    throw "agent.json not found at: $cfgFile"
  }

  $json = (Get-Content -LiteralPath $cfgFile -Raw) | ConvertFrom-Json
  if (-not $json.servers) { throw "No 'servers' array in JSON." }

  $changed = 0
  foreach ($srv in ($json.servers | Where-Object { $_.type -eq 'stdio' -and $_.config -and $_.config.args })) {
    $rebasedArgs = @()
    foreach ($a in $srv.config.args) {
      if ($a -is [string]) {
        $idx = $a.IndexOf('\servers\', [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -ge 0) {
          $tail   = $a.Substring($idx + 1)                 # "servers\..."
          $rebased = Join-Path $BaseRoot $tail             # "<BaseRoot>\servers\..."
          $rebased = $rebased -replace '/', '\'            # 保險：統一反斜線
          if ($rebased -ne $a) {
            Write-Host "[Change]" -ForegroundColor Cyan
            Write-Host "  old: $a"    -ForegroundColor Cyan
            Write-Host "  new: $rebased" -ForegroundColor Cyan
            $changed++
          }
          $rebasedArgs += $rebased
        } else {
          $rebasedArgs += $a
        }
      } else {
        $rebasedArgs += $a
      }
    }
    $srv.config.args = $rebasedArgs
  }

  # 寫回 UTF-8 無 BOM
  $outJson   = $json | ConvertTo-Json -Depth 64
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($cfgFile, $outJson, $utf8NoBom)

  if ($changed -gt 0) {
    Write-Host "[OK] Updated agent.json ($changed arg(s) changed)" -ForegroundColor Green
    Write-Host "     BaseRoot: $BaseRoot"
    Write-Host "     File    : $cfgFile"
  } else {
    Write-Warning "No args contained '\servers\' or paths already correct. Nothing changed."
  }
}
catch {
  Write-Warning ("Failed to rewrite agent.json: " + $_.Exception.Message)
}
