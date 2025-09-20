param(
  [Parameter(Mandatory=$true)] [string] $AgentJsonPath,
  [Parameter(Mandatory=$true)] [string] $ContainerName,
  [Parameter(Mandatory=$false)] [string] $StatePath
)

$ErrorActionPreference = "Stop"

function Get-HostPortFromStateFile {
  param([string]$Path)
  if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $line = Get-Content -LiteralPath $Path -Encoding ASCII |
            Where-Object { $_ -like 'HOST_PORT=*' } | Select-Object -First 1
    if ($line) {
      $val = ($line -split '=',2)[1].Trim()
      if ($val -match '^\d+$') { return [int]$val }
    }
  } catch {}
  return $null
}

function Get-HostPortFromDockerInspect {
  param([string]$Name)
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $null }
  try {
    $line = docker port $Name 3306 2>$null | Select-Object -First 1
    if ($line -match ':(\d+)\s*$') { return [int]$Matches[1] }
  } catch {}
  return $null
}

# 1) 取得主機埠（state 檔 → docker → fallback 3306）
$HostPort = Get-HostPortFromStateFile -Path $StatePath
if (-not $HostPort) { $HostPort = Get-HostPortFromDockerInspect -Name $ContainerName }
if (-not $HostPort) { $HostPort = 3306 }

# 2) 讀取 agent.json
if (-not (Test-Path -LiteralPath $AgentJsonPath)) {
  throw "Agent JSON not found: $AgentJsonPath"
}
$jsonText = Get-Content -LiteralPath $AgentJsonPath -Raw -Encoding UTF8
$agent = $jsonText | ConvertFrom-Json
if (-not $agent.servers) { throw "No 'servers' array in agent.json" }

# 3) 尋找包含 '--mysql' 的條目（只改第一筆）
$targetIdx = $null
for ($i = 0; $i -lt $agent.servers.Count; $i++) {
  $srv = $agent.servers[$i]
  if ($srv.config -and $srv.config.args) {
    $argvList = @()
    foreach ($item in $srv.config.args) { $argvList += [string]$item }
    if ($argvList -contains '--mysql') { $targetIdx = $i; break }
  }
}
if ($null -eq $targetIdx) {
  throw "No server entry with '--mysql' found in servers[].config.args"
}

# 4) 只支援 '--port', '<n>' 這種兩格形式；找到就覆寫下一格，找不到就追加
$finalList = New-Object System.Collections.ArrayList
foreach ($s in $agent.servers[$targetIdx].config.args) { [void]$finalList.Add([string]$s) }

$updated = $false
for ($j = 0; $j -lt $finalList.Count; $j++) {
  if ([string]$finalList[$j] -eq '--port') {
    if ($j + 1 -lt $finalList.Count) {
      $finalList[$j+1] = "$HostPort"
      $updated = $true
    }
    break
  }
}
if (-not $updated) {
  [void]$finalList.Add('--port')
  [void]$finalList.Add("$HostPort")
}

$agent.servers[$targetIdx].config.args = $finalList

# 5) 寫回（UTF-8 無 BOM，PS 5.1 / 7+ 皆可）
$jsonOut = $agent | ConvertTo-Json -Depth 100
if ($PSVersionTable.PSVersion.Major -ge 7) {
  $jsonOut | Set-Content -LiteralPath $AgentJsonPath -Encoding utf8NoBOM
} else {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($AgentJsonPath, $jsonOut, $utf8NoBom)
}

Write-Host "[OK] Updated $AgentJsonPath (MySQL port -> $HostPort)" -ForegroundColor Green


