# =================== Lemonade Launcher (PS 5.1 compatible) ===================
# Start/Stop & One-Click All:
# - Docker Desktop + MySQL container (mysql80, restart unless-stopped)
# - Lemonade Server via conda (env "agent_test"): lemonade-server-dev serve
# - Python App via conda (env "agent_test"): python <your_app>.py
# Notes:
# - No unapproved verbs; no use of $args; PS 5.1 compatible
# - Custom NoFocusCueButton removes blue focus rectangles on buttons
# ============================================================================

$ErrorActionPreference = "Stop"

# ------------ CONFIG ------------
$MiniforgeRoot = Join-Path $env:USERPROFILE "miniforge3"
$CondaBat      = Join-Path $MiniforgeRoot "condabin\conda.bat"

# 都使用 agent_test
$EnvLemon   = "agent_test"
$EnvAgent   = "agent_test"

# Python 入口（空字串則停用按鈕）
$PythonAppPath = "$PSScriptRoot\python-agent\python_agent.py"  # TODO: change or leave empty

# Emotion MCP server 入口（空字串則停用按鈕）
$EmotionServerPath = Join-Path $PSScriptRoot "servers\emotion_detection_mcp.py"

# Positive Music MCP server 入口（空字串則停用按鈕）
$PositiveServerPath = Join-Path $PSScriptRoot "servers\positive_music_mcp_server.py"

# Puzzle MCP server 入口（空字串則停用按鈕）
$PuzzleServerPath = Join-Path $PSScriptRoot "servers\puzzle_mcp_server.py"

$ContainerName = "mysql80"
$DataDir       = Join-Path $env:USERPROFILE "mysql-data"
$RootCredFile  = Join-Path $PSScriptRoot "mysql-credentials.txt"

# Track spawned windows (script-scope)
$script:LemonadeProc       = $null
$script:PythonProc         = $null
$script:EmotionProc        = $null
$script:PositiveProc       = $null
$script:PuzzleProc         = $null
$script:DelayTimer         = $null # for Python App
$script:PositiveDelayTimer = $null # for Positive
$script:PuzzleDelayTimer   = $null # for Puzzle
$script:LemonDelayTimer    = $null # for Lemonade


# --------------------------------

# ------------ Helpers ------------
function Write-Log {
  param([string]$Message)
  $timestamp = (Get-Date).ToString("HH:mm:ss")
  $script:LogBox.AppendText("[$timestamp] $Message`r`n")
  $script:LogBox.ScrollToCaret()
}

function Test-DockerReady {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Log "Docker CLI not found. Please install Docker Desktop."
    return $false
  }

  if (-not (Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)) {
    $dockerExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $dockerExe) {
      Write-Log "Starting Docker Desktop..."
      Start-Process $dockerExe | Out-Null
    }
  }

  Write-Log "Waiting for Docker daemon..."
  $ready = $false
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    for ($i=0; $i -lt 60 -and -not $ready; $i++) {
      $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c","docker info >NUL 2>&1" -PassThru -WindowStyle Hidden -Wait
      if ($p.ExitCode -eq 0) { $ready = $true; break }
      Start-Sleep -Seconds 3
    }
  } finally {
    $ErrorActionPreference = $old
  }

  if (-not $ready) {
    Write-Log "Docker daemon not ready. Please open Docker Desktop and retry."
    return $false
  }
  Write-Log "Docker is ready."
  return $true
}

function Get-FirstFreePort {
  param([int]$Start = 3306)
  $p = $Start
  while ((netstat -ano | Select-String "LISTENING\s+.*:$p\s")) { $p++ }
  return $p
}

function Start-MySQLContainer {
  if (-not (Test-DockerReady)) { return $false }

  $hostPort = $null
  $rootPwd  = $null
  if (Test-Path $RootCredFile) {
    foreach ($line in Get-Content $RootCredFile -Encoding ASCII) {
      if ($line -like "HOST_PORT=*") { $hostPort = $line.Split("=")[1].Trim() }
      if ($line -like "ROOT_PASSWORD=*") { $rootPwd = $line.Split("=")[1].Trim() }
    }
  }
  if (-not $hostPort) { $hostPort = Get-FirstFreePort -Start 3306 }
  if (-not $rootPwd)  { $rootPwd  = "Root" + (Get-Random) }

  Write-Log "Starting container '$ContainerName' (if exists)..."
  docker start $ContainerName *> $null
  if ($LASTEXITCODE -ne 0) {
    New-Item -ItemType Directory -Force $DataDir | Out-Null
    Write-Log "Creating container '$ContainerName' on port $hostPort with persistent data..."
    $dockerArgs = @(
      "run","-d","--name",$ContainerName,
      "--restart","unless-stopped",
      "-p","$($hostPort):3306",
      "-v",("$DataDir" + ":/var/lib/mysql"),
      "-e","MYSQL_ROOT_PASSWORD=$rootPwd",
      "-e","MYSQL_DATABASE=mcp-test",
      "-e","MYSQL_USER=mcp",
      "-e","MYSQL_PASSWORD=123456",
      "mysql:8.4"
    )
    docker @dockerArgs
    if ($LASTEXITCODE -ne 0) {
      Write-Log "Failed to run mysql:8.4 container."
      return $false
    }
    "ROOT_PASSWORD=$rootPwd`r`nHOST_PORT=$hostPort" | Set-Content -Path $RootCredFile -Encoding ASCII
    Write-Log "Saved credentials to: $RootCredFile"
    if ($script:lblCredPath) { $script:lblCredPath.Text = "Credentials file: $RootCredFile" }
  }

  Write-Log "Waiting for MySQL to accept connections on $hostPort..."
  $deadline = (Get-Date).AddMinutes(2)
  $ready = $false
  while (-not $ready -and (Get-Date) -lt $deadline) {
    $t = Test-NetConnection -ComputerName 127.0.0.1 -Port $hostPort
    if ($t.TcpTestSucceeded) { $ready = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $ready) {
    Write-Log "MySQL not ready on port $hostPort."
    return $false
  }

  Write-Log "MySQL running. Port=$hostPort  (user=mcp / pass=123456)"

  # 同步 agent.json 的 --port
  try {
    $updateScript = Join-Path $PSScriptRoot "scripts\update-agent-json.ps1"
    if (Test-Path $updateScript) {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $updateScript `
        -AgentJsonPath (Join-Path $PSScriptRoot "agent.json") `
        -ContainerName $ContainerName `
        -StatePath $RootCredFile
      Write-Log "agent.json port sync done."
    } else {
      Write-Log "update-agent-json.ps1 not found; skipped port sync."
    }
  } catch {
    Write-Log "agent.json port sync failed: $($_.Exception.Message)"
  }

  return $true
}

function Stop-MySQLContainer {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Log "Docker CLI not found."
    return
  }
  Write-Log "Stopping container '$ContainerName'..."
  docker stop $ContainerName *> $null
  if ($LASTEXITCODE -eq 0) { Write-Log "MySQL container stopped." }
  else { Write-Log "No running container named '$ContainerName'." }
}

function Test-DockerStopped {
  $cli = $false; $svc = $false; $proc = $false; $wsl = $false
  try { docker info *> $null; $cli = ($LASTEXITCODE -eq 0) } catch {}
  try { $s = Get-Service com.docker.service -ErrorAction SilentlyContinue; if ($s -and $s.Status -eq 'Running') { $svc = $true } } catch {}
  try { $p = Get-Process "Docker Desktop","com.docker.backend","com.docker.build","dockerd","DockerCli","vpnkit" -ErrorAction SilentlyContinue; if ($p) { $proc = $true } } catch {}
  try {
    $w = wsl -l -v 2>$null
    $wsl = [bool]( ($w | Select-String 'docker-desktop\s+\d+\s+Running') -or ($w | Select-String 'docker-desktop-data\s+\d+\s+Running') )
  } catch {}
  $stopped = -not ($cli -or $svc -or $proc -or $wsl)
  if ($stopped) { Write-Log "=> Docker daemon appears STOPPED." } else { Write-Log "=> Docker daemon appears RUNNING." }
  return $stopped
}

function Stop-DockerDesktop {
  Write-Log "Stopping Docker Desktop (force)..."
  $isAdmin = $false
  try {
    $wp = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {}

  try { $ids = docker ps -q 2>$null; if ($ids) { $ids | ForEach-Object { docker stop $_ *> $null } } } catch {}
  if ($isAdmin) {
    try { & sc.exe stop com.docker.service | Out-Null } catch {}
    $deadline = (Get-Date).AddSeconds(20)
    do {
      $s = Get-Service com.docker.service -ErrorAction SilentlyContinue
      if (-not $s -or $s.Status -ne 'Running') { break }
      Start-Sleep -Milliseconds 800
    } while ((Get-Date) -lt $deadline)
  } else {
    Write-Log "Not elevated: skipping Windows service stop (run launcher as Administrator for full quit)."
  }

  foreach ($name in @('com.docker.build','com.docker.backend','Docker Desktop','dockerd','DockerCli','vpnkit')) {
    try { Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
  }
  foreach ($d in @('docker-desktop','docker-desktop-data')) {
    try { wsl.exe -t $d 2>$null } catch {}
  }

  if (Test-DockerStopped) { Write-Log "Docker Desktop has been stopped." }
  else { Write-Log "Docker still appears to be running. Try running this launcher as Administrator or quit from the Docker tray menu." }
}

function Start-EmotionServer {
  if (-not $EmotionServerPath -or -not (Test-Path $EmotionServerPath)) {
    Write-Log "Emotion MCP path not set or not found: $EmotionServerPath"
    return
  }
  if (-not (Test-Path $CondaBat)) {
    Write-Log "conda.bat not found at $CondaBat"
    return
  }
  if ($script:EmotionProc -and -not $script:EmotionProc.HasExited) {
    Write-Log "Emotion MCP window already running (PID $($script:EmotionProc.Id))."
    return
  }

  $tmpCmd = Join-Path $env:TEMP "launch-emotion-mcp.cmd"
  $cmdText = @"
@echo off
title Emotion MCP
chcp 65001 >NUL
call "$CondaBat" activate $EnvAgent
set PYTHONUNBUFFERED=1
set PYTHONIOENCODING=utf-8
set FORCE_COLOR=1
echo [Emotion MCP] Using interpreter:
where python
python -V
echo.
echo [Emotion MCP] Running: "$EmotionServerPath"
echo ------------------------------------------------------------
python "$EmotionServerPath"
echo ------------------------------------------------------------
echo [Emotion MCP] Process exited with code %ERRORLEVEL%
"@
  Set-Content -Path $tmpCmd -Value $cmdText -Encoding ASCII

  Write-Log "Starting Emotion MCP via $tmpCmd ..."
  $script:EmotionProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/k","`"$tmpCmd`"" -PassThru -WindowStyle Minimized
  Write-Log "Emotion MCP window PID: $($script:EmotionProc.Id)"
}

function Stop-EmotionServer {
  Write-Log "Stopping Emotion MCP window..."
  if ($script:EmotionProc -and -not $script:EmotionProc.HasExited) {
    try {
      Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID",$script:EmotionProc.Id,"/T","/F" -WindowStyle Hidden -Wait
    } catch {}
    $script:EmotionProc = $null
    Start-Sleep -Milliseconds 200
  }
  try {
    Start-Process -FilePath "taskkill.exe" -ArgumentList '/FI','WINDOWTITLE eq "Emotion MCP"','/T','/F' -WindowStyle Hidden -Wait
  } catch {}
  try {
    Get-Process -Name "cmd" -ErrorAction SilentlyContinue | ForEach-Object {
      try { if ($_.MainWindowTitle -like "*Emotion MCP*") { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
  } catch {}
  Write-Log "Emotion MCP stop requested."
}

function Start-PositiveServer {
  if (-not $PositiveServerPath -or -not (Test-Path $PositiveServerPath)) {
    Write-Log "Positive MCP path not set or not found: $PositiveServerPath"
    return
  }
  if (-not (Test-Path $CondaBat)) {
    Write-Log "conda.bat not found at $CondaBat"
    return
  }
  if ($script:PositiveProc -and -not $script:PositiveProc.HasExited) {
    Write-Log "Positive MCP window already running (PID $($script:PositiveProc.Id))."
    return
  }

  $tmpCmd = Join-Path $env:TEMP "launch-positive-mcp.cmd"
  $cmdText = @"
@echo off
title Positive Music MCP
chcp 65001 >NUL
call "$CondaBat" activate $EnvAgent
set PYTHONUNBUFFERED=1
set PYTHONIOENCODING=utf-8
set FORCE_COLOR=1
echo [Positive MCP] Using interpreter:
where python
python -V
echo.
echo [Positive MCP] Running: "$PositiveServerPath"
echo ------------------------------------------------------------
python "$PositiveServerPath"
echo ------------------------------------------------------------
echo [Positive MCP] Process exited with code %ERRORLEVEL%
"@
  Set-Content -Path $tmpCmd -Value $cmdText -Encoding ASCII

  Write-Log "Starting Positive MCP via $tmpCmd ..."
  $script:PositiveProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/k","`"$tmpCmd`"" -PassThru -WindowStyle Minimized
  Write-Log "Positive MCP window PID: $($script:PositiveProc.Id)"
}

function Start-PositiveServer-AfterDelay {
  param([int]$Seconds = 5)

  if ($script:PositiveProc -and -not $script:PositiveProc.HasExited) {
    Write-Log "Positive MCP already running (PID $($script:PositiveProc.Id)). Skip delayed start."
    return
  }
  if ($script:PositiveDelayTimer) {
    try { $script:PositiveDelayTimer.Stop() } catch {}
    $script:PositiveDelayTimer = $null
  }

  Write-Log ("Waiting {0}s before starting Positive MCP..." -f $Seconds)

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(1, $Seconds) * 1000
  $timer.Add_Tick({
    try {
      $script:PositiveDelayTimer.Stop()
      $script:PositiveDelayTimer = $null
      Write-Log "Delay done. Starting Positive MCP now."
      Start-PositiveServer
    } catch {
      Write-Log ("Positive MCP delayed start failed: " + $_.Exception.Message)
    }
  })
  $script:PositiveDelayTimer = $timer
  $script:PositiveDelayTimer.Start()
}

function Stop-PositiveServer {
  Write-Log "Stopping Positive MCP window..."
  if ($script:PositiveProc -and -not $script:PositiveProc.HasExited) {
    try {
      Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID",$script:PositiveProc.Id,"/T","/F" -WindowStyle Hidden -Wait
    } catch {}
    $script:PositiveProc = $null
    Start-Sleep -Milliseconds 200
  }
  try {
    Start-Process -FilePath "taskkill.exe" -ArgumentList '/FI','WINDOWTITLE eq "Positive Music MCP"','/T','/F' -WindowStyle Hidden -Wait
  } catch {}
  try {
    Get-Process -Name "cmd" -ErrorAction SilentlyContinue | ForEach-Object {
      try { if ($_.MainWindowTitle -like "*Positive Music MCP*") { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
  } catch {}
  Write-Log "Positive MCP stop requested."
}

function Start-PuzzleServer {
  if (-not $PuzzleServerPath -or -not (Test-Path $PuzzleServerPath)) {
    Write-Log "Puzzle MCP path not set or not found: $PuzzleServerPath"
    return
  }
  if (-not (Test-Path $CondaBat)) {
    Write-Log "conda.bat not found at $CondaBat"
    return
  }
  if ($script:PuzzleProc -and -not $script:PuzzleProc.HasExited) {
    Write-Log "Puzzle MCP window already running (PID $($script:PuzzleProc.Id))."
    return
  }

  $tmpCmd = Join-Path $env:TEMP "launch-puzzle-mcp.cmd"
  $cmdText = @"
@echo off
title Puzzle MCP
chcp 65001 >NUL
call "$CondaBat" activate $EnvAgent
set PYTHONUNBUFFERED=1
set PYTHONIOENCODING=utf-8
set FORCE_COLOR=1
echo [Puzzle MCP] Using interpreter:
where python
python -V
echo.
echo [Puzzle MCP] Running: "$PuzzleServerPath"
echo ------------------------------------------------------------
python "$PuzzleServerPath"
echo ------------------------------------------------------------
echo [Puzzle MCP] Process exited with code %ERRORLEVEL%
"@
  Set-Content -Path $tmpCmd -Value $cmdText -Encoding ASCII

  Write-Log "Starting Puzzle MCP via $tmpCmd ..."
  $script:PuzzleProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/k","`"$tmpCmd`"" -PassThru -WindowStyle Minimized
  Write-Log "Puzzle MCP window PID: $($script:PuzzleProc.Id)"
}

function Start-PuzzleServer-AfterDelay {
  param([int]$Seconds = 5)

  if ($script:PuzzleProc -and -not $script:PuzzleProc.HasExited) {
    Write-Log "Puzzle MCP already running (PID $($script:PuzzleProc.Id)). Skip delayed start."
    return
  }
  if ($script:PuzzleDelayTimer) {
    try { $script:PuzzleDelayTimer.Stop() } catch {}
    $script:PuzzleDelayTimer = $null
  }

  Write-Log ("Waiting {0}s before starting Puzzle MCP..." -f $Seconds)

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(1, $Seconds) * 1000
  $timer.Add_Tick({
    try {
      $script:PuzzleDelayTimer.Stop()
      $script:PuzzleDelayTimer = $null
      Write-Log "Delay done. Starting Puzzle MCP now."
      Start-PuzzleServer
    } catch {
      Write-Log ("Puzzle MCP delayed start failed: " + $_.Exception.Message)
    }
  })
  $script:PuzzleDelayTimer = $timer
  $script:PuzzleDelayTimer.Start()
}

function Stop-PuzzleServer {
  Write-Log "Stopping Puzzle MCP window..."
  if ($script:PuzzleProc -and -not $script:PuzzleProc.HasExited) {
    try {
      Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID",$script:PuzzleProc.Id,"/T","/F" -WindowStyle Hidden -Wait
    } catch {}
    $script:PuzzleProc = $null
    Start-Sleep -Milliseconds 200
  }
  try {
    Start-Process -FilePath "taskkill.exe" -ArgumentList '/FI','WINDOWTITLE eq "Puzzle MCP"','/T','/F' -WindowStyle Hidden -Wait
  } catch {}
  try {
    Get-Process -Name "cmd" -ErrorAction SilentlyContinue | ForEach-Object {
      try { if ($_.MainWindowTitle -like "*Puzzle MCP*") { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
  } catch {}
  Write-Log "Puzzle MCP stop requested."
}


function Start-LemonadeServer {
  if (-not (Test-Path $CondaBat)) {
    Write-Log "conda.bat not found at $CondaBat"
    return
  }
  if ($script:LemonadeProc -and -not $script:LemonadeProc.HasExited) {
    Write-Log "Lemonade Server window already running (PID $($script:LemonadeProc.Id))."
    return
  }

  # 用暫存 .cmd（在 agent_test 啟動 lemonade）
  $tmpCmd = Join-Path $env:TEMP "launch-lemonade.cmd"
  $cmdText = @"
@echo off
title Lemonade Server
call "$CondaBat" activate $EnvLemon
set PYTHONUNBUFFERED=1
set PYTHONIOENCODING=utf-8
set FORCE_COLOR=1
lemonade-server-dev serve
"@
  Set-Content -Path $tmpCmd -Value $cmdText -Encoding ASCII

  Write-Log "Starting Lemonade Server via $tmpCmd (env=$EnvLemon)..."
  $script:LemonadeProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/k","`"$tmpCmd`"" -PassThru -WindowStyle Minimized
  Write-Log "Lemonade Server window PID: $($script:LemonadeProc.Id)"
}

function Start-LemonadeServer-AfterDelay {
  param([int]$Seconds = 5)

  if ($script:LemonadeProc -and -not $script:LemonadeProc.HasExited) {
    Write-Log "Lemonade Server already running (PID $($script:LemonadeProc.Id)). Skip delayed start."
    return
  }
  if ($script:LemonDelayTimer) {
    try { $script:LemonDelayTimer.Stop() } catch {}
    $script:LemonDelayTimer = $null
  }

  Write-Log ("Waiting {0}s before starting Lemonade Server..." -f $Seconds)

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(1, $Seconds) * 1000
  $timer.Add_Tick({
    try {
      $script:LemonDelayTimer.Stop()
      $script:LemonDelayTimer = $null
      Write-Log "Delay done. Starting Lemonade Server now."
      Start-LemonadeServer
    } catch {
      Write-Log ("Lemonade delayed start failed: " + $_.Exception.Message)
    }
  })
  $script:LemonDelayTimer = $timer
  $script:LemonDelayTimer.Start()
}

function Stop-LemonadeServer {
  Write-Log "Stopping Lemonade Server..."
  if ($script:LemonadeProc -and -not $script:LemonadeProc.HasExited) {
    try { Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID",$script:LemonadeProc.Id,"/T","/F" -WindowStyle Hidden -Wait } catch {}
    $script:LemonadeProc = $null
    Start-Sleep -Milliseconds 300
  }
  try {
    Start-Process -FilePath "taskkill.exe" -ArgumentList '/FI','WINDOWTITLE eq "Lemonade Server"','/T','/F' -WindowStyle Hidden -Wait
  } catch {}
  try {
    $procs = Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
             Where-Object { $_.CommandLine -match 'lemonade-server-dev' }
    foreach ($p in $procs) {
      try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }
  } catch {}
  Write-Log "Lemonade Server stop requested."
}

# function Start-PythonApp {
#   if (-not $PythonAppPath -or -not (Test-Path $PythonAppPath)) {
#     Write-Log "Python app path not set or not found: $PythonAppPath"
#     return
#   }
#   if (-not (Test-Path $CondaBat)) {
#     Write-Log "conda.bat not found at $CondaBat"
#     return
#   }
#   if ($script:PythonProc -and -not $script:PythonProc.HasExited) {
#     Write-Log "Python App window already running (PID $($script:PythonProc.Id))."
#     return
#   }

#   $tmpCmd = Join-Path $env:TEMP "launch-python-app.cmd"
#   $cmdText = @"
# @echo off
# title Python App
# chcp 65001 >NUL
# call "$CondaBat" activate $EnvAgent
# set PYTHONUNBUFFERED=1
# set PYTHONIOENCODING=utf-8
# set FORCE_COLOR=1
# echo [Python] Using interpreter:
# where python
# python -V
# echo.
# echo [Python] Running: "$PythonAppPath"
# echo ------------------------------------------------------------
# python "$PythonAppPath"
# echo ------------------------------------------------------------
# echo [Python] Process exited with code %ERRORLEVEL%
# "@
#   Set-Content -Path $tmpCmd -Value $cmdText -Encoding ASCII

#   Write-Log "Starting Python App via $tmpCmd ..."
#   $script:PythonProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/k","`"$tmpCmd`"" -PassThru
#   Write-Log "Python App window PID: $($script:PythonProc.Id)"
# }

function Start-PythonApp-AfterDelay {
  param([int]$Seconds = 10)
  if (-not $PythonAppPath -or -not (Test-Path $PythonAppPath)) {
    Write-Log "Python app path not set or not found: $PythonAppPath"
    return
  }
  if ($script:PythonProc -and -not $script:PythonProc.HasExited) {
    Write-Log "Python App already running (PID $($script:PythonProc.Id)). Skip delayed start."
    return
  }
  if ($script:DelayTimer) {  # 避免重複排程
    try { $script:DelayTimer.Stop() } catch {}
    $script:DelayTimer = $null
  }

  Write-Log ("Waiting {0}s before starting Python App..." -f $Seconds)

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = [Math]::Max(1, $Seconds) * 1000
  $timer.Add_Tick({
    try {
      $script:DelayTimer.Stop()
      $script:DelayTimer = $null
      Write-Log "Delay done. Starting Python App now."
      Start-PythonApp
    } catch {
      Write-Log ("Delayed start failed: " + $_.Exception.Message)
    }
  })
  $script:DelayTimer = $timer
  $script:DelayTimer.Start()
}

function Stop-PythonApp {
  Write-Log "Stopping Python App window..."
  if ($script:PythonProc -and -not $script:PythonProc.HasExited) {
    try {
      Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID",$script:PythonProc.Id,"/T","/F" -WindowStyle Hidden -Wait
    } catch {}
    $script:PythonProc = $null
    Start-Sleep -Milliseconds 200
  }
  try {
    Start-Process -FilePath "taskkill.exe" -ArgumentList '/FI','WINDOWTITLE eq "Python App"','/T','/F' -WindowStyle Hidden -Wait
  } catch {}
  try {
    Get-Process -Name "cmd" -ErrorAction SilentlyContinue | ForEach-Object {
      try { if ($_.MainWindowTitle -like "*Python App*") { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
  } catch {}
  Write-Log "Python App stop requested."
}


# ----- One-Click All -----
function Start-All {
  $okDb = Start-MySQLContainer
  if ($okDb) {
    # 0s：Emotion
    Start-EmotionServer

    # +5s：Positive
    Start-PositiveServer-AfterDelay -Seconds 5

    # +10s：Puzzle
    Start-PuzzleServer-AfterDelay -Seconds 10

    # +15s：Lemonade
    Start-LemonadeServer-AfterDelay -Seconds 15

    # +20s：Python App（可選）
    if ($PythonAppPath -and (Test-Path $PythonAppPath)) {
      Start-PythonApp-AfterDelay -Seconds 20
    } else {
      Write-Log "Python App path missing; skip delayed start."
    }
  } else {
    Write-Log "Skip Emotion/Positive/Puzzle/Lemonade/Python start due to DB failure."
  }
  Write-Log "=== START INITIATED (staggered by 5s each) ==="
}


function Stop-All {
  Stop-PythonApp
  Stop-LemonadeServer
  Stop-PuzzleServer
  Stop-PositiveServer
  Stop-EmotionServer
  Stop-MySQLContainer
  Write-Log "=== STOP DONE ===  (Docker Desktop still running; use 'Quit Docker Desktop' if needed)"
}
# --------------------------------


# function Start-PythonApp {
#   if (-not $PythonAppPath -or -not (Test-Path $PythonAppPath)) {
#     Write-Log "Python app path not set or not found: $PythonAppPath"
#     return
#   }
#   if (-not (Test-Path $CondaBat)) {
#     Write-Log "conda.bat not found at $CondaBat"
#     return
#   }
#   if ($script:PythonProc -and -not $script:PythonProc.HasExited) {
#     Write-Log "Python App window already running (PID $($script:PythonProc.Id))."
#     return
#   }

#   $tmpCmd = Join-Path $env:TEMP "launch-python-app.cmd"
#   $cmdText = @"
# @echo off
# title Python App
# chcp 65001 >NUL
# call "$CondaBat" activate $EnvAgent
# set PYTHONUNBUFFERED=1
# set PYTHONIOENCODING=utf-8
# set FORCE_COLOR=1
# echo [Python] Using interpreter:
# where python
# python -V
# echo.
# echo [Python] Running: "$PythonAppPath"
# echo ------------------------------------------------------------
# python "$PythonAppPath"
# echo ------------------------------------------------------------
# echo [Python] Process exited with code %ERRORLEVEL%
# "@
#   Set-Content -Path $tmpCmd -Value $cmdText -Encoding ASCII

#   Write-Log "Starting Python App via $tmpCmd ..."
#   $script:PythonProc = Start-Process -FilePath "cmd.exe" -ArgumentList "/k","`"$tmpCmd`"" -PassThru
#   Write-Log "Python App window PID: $($script:PythonProc.Id)"
# }



function Start-PythonApp {
  # 需要的外部變數：$CondaBat, $EnvAgent, $PythonAppPath, Write-Log

  if (-not $PythonAppPath -or -not (Test-Path $PythonAppPath)) {
    Write-Log "Python app path not set or not found: $PythonAppPath"
    return
  }

  if ($script:PythonProc -and -not $script:PythonProc.HasExited) {
    Write-Log "Python App GUI already running (PID $($script:PythonProc.Id))."
    return
  }

  $guiClient = Join-Path $PSScriptRoot "gui_client.py"
  if (-not (Test-Path $guiClient)) {
    Write-Log "GUI client not found: $guiClient"
    return
  }

  # 準備要執行的主命令：python gui_client.py "<PythonAppPath>"
  $pyArgs = @(
    "`"$guiClient`""
    "`"$PythonAppPath`""
  ) -join ' '

  # 優先用 conda 啟動，否則退回系統 python
  if ($CondaBat -and (Test-Path $CondaBat)) {
    # 用 cmd.exe /k 是為了保留視窗；不想保留就把 /k 換成 /c
    $cmdLine = @(
      'chcp 65001 >NUL'
      "call `"$CondaBat`" activate $EnvAgent"
      'set "PYTHONIOENCODING=utf-8"'
      'set "PYTHONUNBUFFERED=1"'
      'set "FORCE_COLOR=1"'
      'where python'
      'python -V'
      "python -X utf8 $pyArgs"
    ) -join ' && '

    Write-Log "Starting Python App GUI via conda env '$EnvAgent' ..."
    $script:PythonProc = Start-Process -FilePath "cmd.exe" `
      -ArgumentList "/k", $cmdLine `
      -PassThru -WindowStyle Minimized
  }
  else {
    # 沒有 conda.bat 就直接用系統 python；用 PowerShell 方式啟動可完整支援 Unicode 路徑
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = @(
      "-NoLogo -NoProfile -ExecutionPolicy Bypass -Command",
      "`$env:PYTHONIOENCODING='utf-8'; `$env:PYTHONUNBUFFERED='1'; `$env:FORCE_COLOR='1'; " +
      "'Using system python:'; & where.exe python | Out-Host; & python -V | Out-Host; " +
      "& python -X utf8 $pyArgs"
    ) -join ' '

    # 讓使用者看到輸出：UseShellExecute=$true 就會有新視窗，也可保證 Unicode 路徑
    $psi.UseShellExecute = $true
    $psi.CreateNoWindow = $false

    Write-Log "Starting Python App GUI via system python ..."
    $script:PythonProc = New-Object System.Diagnostics.Process
    $script:PythonProc.StartInfo = $psi
    [void]$script:PythonProc.Start()
  }

  Write-Log "Python App GUI PID: $($script:PythonProc.Id)"
}


# ------------ WinForms UI (PS5-compatible; grouped & even spacing) ------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing `
  -Language CSharp `
  -TypeDefinition @"
using System;
using System.Windows.Forms;

public class NoFocusCueButton : Button
{
    public NoFocusCueButton() : base()
    {
        this.TabStop = false;
    }

    protected override bool ShowFocusCues { get { return false; } }

    public bool IsFocusCuesHidden { get { return true; } }
}
"@

[System.Windows.Forms.Application]::EnableVisualStyles()

# --- Form ---
$form               = New-Object System.Windows.Forms.Form
$form.Text          = "Lemonade Launcher"
$form.StartPosition = "CenterScreen"
$form.Size          = New-Object System.Drawing.Size(1080, 640)
$form.MaximizeBox   = $false
$form.KeyPreview    = $true

# --- Root table layout (padding & consistent gaps) ---
$root          = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock     = 'Fill'
$root.ColumnCount = 1
$root.RowCount = 5
$root.Padding  = New-Object System.Windows.Forms.Padding(12)
$root.AutoSize = $false
# Rows: One-Click, DB, Servers, App, Log+Exit
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null

# --- Helper: make button ---
function New-LLButton {
  param([string]$Text)
  $b = New-Object NoFocusCueButton
  $b.Text     = $Text
  $b.AutoSize = $true
  $b.Margin   = New-Object System.Windows.Forms.Padding(6) # 一致間距
  $b.Padding  = New-Object System.Windows.Forms.Padding(6,4,6,4)
  $b.MinimumSize = New-Object System.Drawing.Size(160, 34)
  return $b
}

# --- Row 0: One-Click ---
$flowOneClick = New-Object System.Windows.Forms.FlowLayoutPanel
$flowOneClick.FlowDirection = 'LeftToRight'
$flowOneClick.WrapContents  = $false
$flowOneClick.AutoSize      = $true
$flowOneClick.Dock          = 'Top'
$flowOneClick.Margin        = New-Object System.Windows.Forms.Padding(0,0,0,6)

$btnAllStart = New-LLButton "One-Click START"
$btnAllStop  = New-LLButton "One-Click STOP"
$btnAllStart.MinimumSize = New-Object System.Drawing.Size(220,36)
$btnAllStop.MinimumSize  = New-Object System.Drawing.Size(220,36)
$flowOneClick.Controls.AddRange(@($btnAllStart,$btnAllStop))

# --- Row 1: Database (Docker + MySQL) ---
$grpDB              = New-Object System.Windows.Forms.GroupBox
$grpDB.Text         = "Database (Docker + MySQL)"
$grpDB.AutoSize     = $true
$grpDB.Dock         = 'Top'
$grpDB.Margin       = New-Object System.Windows.Forms.Padding(0,0,0,6)
$flowDB             = New-Object System.Windows.Forms.FlowLayoutPanel
$flowDB.Dock        = 'Top'
$flowDB.AutoSize    = $true
$flowDB.WrapContents= $true

$btnDockerStart = New-LLButton "Start Docker + MySQL"
$btnDockerStop  = New-LLButton "Stop MySQL Container"

$flowDB.Controls.AddRange(@($btnDockerStart,$btnDockerStop))
$grpDB.Controls.Add($flowDB)

# --- Row 2: Servers (MCP & Lemonade) ---
$grpSrv              = New-Object System.Windows.Forms.GroupBox
$grpSrv.Text         = "Servers"
$grpSrv.AutoSize     = $true
$grpSrv.Dock         = 'Top'
$grpSrv.Margin       = New-Object System.Windows.Forms.Padding(0,0,0,6)
$flowSrv             = New-Object System.Windows.Forms.FlowLayoutPanel
$flowSrv.Dock        = 'Top'
$flowSrv.AutoSize    = $true
$flowSrv.WrapContents= $true

# Emotion
$btnEmotionStart = New-LLButton "Start Emotion MCP"
$btnEmotionStop  = New-LLButton "Stop Emotion MCP"
if (-not $EmotionServerPath -or -not (Test-Path $EmotionServerPath)) { $btnEmotionStart.Enabled = $false }

# Positive
$btnPositiveStart = New-LLButton "Start Positive MCP"
$btnPositiveStop  = New-LLButton "Stop Positive MCP"
if (-not $PositiveServerPath -or -not (Test-Path $PositiveServerPath)) { $btnPositiveStart.Enabled = $false }

# Puzzle
$btnPuzzleStart = New-LLButton "Start Puzzle MCP"
$btnPuzzleStop  = New-LLButton "Stop Puzzle MCP"
if (-not $PuzzleServerPath -or -not (Test-Path $PuzzleServerPath)) { $btnPuzzleStart.Enabled = $false }

# Lemonade
$btnLemonStart = New-LLButton "Start Lemonade Server"
$btnLemonStop  = New-LLButton "Stop Lemonade Server"

$flowSrv.Controls.AddRange(@(
  $btnEmotionStart,$btnEmotionStop,
  $btnPositiveStart,$btnPositiveStop,
  $btnPuzzleStart,$btnPuzzleStop,
  $btnLemonStart,$btnLemonStop
))
$grpSrv.Controls.Add($flowSrv)

# --- Row 3: App (Python) ---
$grpApp              = New-Object System.Windows.Forms.GroupBox
$grpApp.Text         = "Python App"
$grpApp.AutoSize     = $true
$grpApp.Dock         = 'Top'
$grpApp.Margin       = New-Object System.Windows.Forms.Padding(0,0,0,6)
$flowApp             = New-Object System.Windows.Forms.FlowLayoutPanel
$flowApp.Dock        = 'Top'
$flowApp.AutoSize    = $true
$flowApp.WrapContents= $true

$btnPyStart = New-LLButton "Start Python App"
$btnPyStop  = New-LLButton "Stop Python App"
if (-not $PythonAppPath -or -not (Test-Path $PythonAppPath)) { $btnPyStart.Enabled = $false }

$flowApp.Controls.AddRange(@($btnPyStart,$btnPyStop))
$grpApp.Controls.Add($flowApp)

# --- Row 4: Log + Exit ---
$panelLogExit = New-Object System.Windows.Forms.TableLayoutPanel
$panelLogExit.Dock       = 'Fill'
$panelLogExit.ColumnCount= 1
$panelLogExit.RowCount   = 2
$panelLogExit.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$panelLogExit.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$panelLogExit.Padding    = New-Object System.Windows.Forms.Padding(0)

$LogBox                   = New-Object System.Windows.Forms.TextBox
$script:LogBox            = $LogBox
$LogBox.Multiline         = $true
$LogBox.ScrollBars        = "Vertical"
$LogBox.ReadOnly          = $true
$LogBox.WordWrap          = $true
$LogBox.Font              = New-Object System.Drawing.Font("Consolas", 9)
$LogBox.Dock              = 'Fill'
$LogBox.Margin            = New-Object System.Windows.Forms.Padding(0,0,0,6)

$flowExit = New-Object System.Windows.Forms.FlowLayoutPanel
$flowExit.FlowDirection = 'RightToLeft'
$flowExit.Dock          = 'Top'
$flowExit.AutoSize      = $true

$btnClose   = New-LLButton "Exit"
$btnClose.MinimumSize = New-Object System.Drawing.Size(100,30)
$flowExit.Controls.Add($btnClose)

$panelLogExit.Controls.Add($LogBox, 0, 0)
$panelLogExit.Controls.Add($flowExit, 0, 1)

# --- Add to root ---
$root.Controls.Add($flowOneClick)
$root.Controls.Add($grpDB)
$root.Controls.Add($grpSrv)
$root.Controls.Add($grpApp)
$root.Controls.Add($panelLogExit)
$form.Controls.Add($root)

# --- Events ---
# One-Click
$btnAllStart.Add_Click({
  try { $btnAllStart.Enabled = $false; Write-Log "=== One-Click START ==="; Start-All }
  finally { $btnAllStart.Enabled = $true }
})
$btnAllStop.Add_Click({
  try { $btnAllStop.Enabled = $false; Write-Log "=== One-Click STOP ==="; Stop-All }
  finally { $btnAllStop.Enabled = $true }
})

# DB
$btnDockerStart.Add_Click({
  try { $btnDockerStart.Enabled = $false; Write-Log "=== Docker + MySQL (Start) ==="; if (Start-MySQLContainer) { Write-Log "Docker + MySQL ready." } else { Write-Log "Docker/MySQL start failed." } }
  finally { $btnDockerStart.Enabled = $true }
})
$btnDockerStop.Add_Click({
  try { $btnDockerStop.Enabled = $false; Write-Log "=== MySQL Container (Stop) ==="; Stop-MySQLContainer }
  finally { $btnDockerStop.Enabled = $true }
})

# Servers
$btnEmotionStart.Add_Click({
  try { $btnEmotionStart.Enabled = $false; Write-Log "=== Emotion MCP (Start) ==="; Start-EmotionServer }
  finally { $btnEmotionStart.Enabled = $true }
})
$btnEmotionStop.Add_Click({
  try { $btnEmotionStop.Enabled = $false; Write-Log "=== Emotion MCP (Stop) ==="; Stop-EmotionServer }
  finally { $btnEmotionStop.Enabled = $true }
})

$btnPositiveStart.Add_Click({
  try { $btnPositiveStart.Enabled = $false; Write-Log "=== Positive MCP (Start) ==="; Start-PositiveServer }
  finally { $btnPositiveStart.Enabled = $true }
})
$btnPositiveStop.Add_Click({
  try { $btnPositiveStop.Enabled = $false; Write-Log "=== Positive MCP (Stop) ==="; Stop-PositiveServer }
  finally { $btnPositiveStop.Enabled = $true }
})

$btnPuzzleStart.Add_Click({
  try { $btnPuzzleStart.Enabled = $false; Write-Log "=== Puzzle MCP (Start) ==="; Start-PuzzleServer }
  finally { $btnPuzzleStart.Enabled = $true }
})
$btnPuzzleStop.Add_Click({
  try { $btnPuzzleStop.Enabled = $false; Write-Log "=== Puzzle MCP (Stop) ==="; Stop-PuzzleServer }
  finally { $btnPuzzleStop.Enabled = $true }
})

$btnLemonStart.Add_Click({
  try { $btnLemonStart.Enabled = $false; Write-Log "=== Lemonade Server (Start) ==="; Start-LemonadeServer }
  finally { $btnLemonStart.Enabled = $true }
})
$btnLemonStop.Add_Click({
  try { $btnLemonStop.Enabled = $false; Write-Log "=== Lemonade Server (Stop) ==="; Stop-LemonadeServer }
  finally { $btnLemonStop.Enabled = $true }
})

# App
$btnPyStart.Add_Click({
  try { $btnPyStart.Enabled = $false; Write-Log "=== Python App (Start) ==="; Start-PythonApp }
  finally { $btnPyStart.Enabled = $true }
})
$btnPyStop.Add_Click({
  try { $btnPyStop.Enabled = $false; Write-Log "=== Python App (Stop) ==="; Stop-PythonApp }
  finally { $btnPyStop.Enabled = $true }
})

# Exit
$btnClose.Add_Click({ $form.Close() })

# 移走初始焦點
$form.Add_Shown({ $form.ActiveControl = $null })

[void]$form.ShowDialog()

