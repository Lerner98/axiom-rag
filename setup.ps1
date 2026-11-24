<#
.SYNOPSIS
    One-command installer and launcher for Axiom RAG on Windows.

.DESCRIPTION
    Checks for (and installs, if missing) Python, Node.js and Ollama, downloads
    the AI model, installs the app, then starts the backend and the web UI and
    opens your browser. Safe to run again: steps that are already done are skipped.

    Easiest way to run it: double-click Start-Axiom.bat in this folder.

.PARAMETER Mode
    auto (default) - use the NVIDIA GPU if it has 6 GB+ of memory, otherwise CPU
    cpu            - always run the AI on the processor (works on any PC)
    gpu            - always use the NVIDIA GPU

.PARAMETER Model
    Override the Ollama model (default: llama3.2:3b on CPU, llama3.1:8b on GPU).

.PARAMETER InstallOnly
    Install everything but don't start the app.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup.ps1
    powershell -ExecutionPolicy Bypass -File setup.ps1 -Mode cpu
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'cpu', 'gpu')]
    [string]$Mode = 'auto',
    [string]$Model = '',
    [switch]$InstallOnly,
    [switch]$NoBrowser
)

# Native tools (pip, npm, winget) write warnings to stderr; with "Stop" Windows
# PowerShell 5.1 would treat those as fatal. Exit codes are checked instead.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # makes Invoke-WebRequest much faster

$Root        = $PSScriptRoot
$BackendDir  = Join-Path $Root 'original_rag\backend'
$FrontendDir = Join-Path $Root 'original_rag\frontend'
$LogDir      = Join-Path $Root 'logs'
$BackendPort = 8001
$FrontendPort = 8080
$CpuModel    = 'llama3.2:3b'
$GpuModel    = 'llama3.1:8b'
$OllamaUrl   = 'http://localhost:11434'

# ---------------------------------------------------------------- helpers ---
$script:StepNo = 0
$TotalSteps = 8
function Step($text) {
    $script:StepNo++
    Write-Host ''
    Write-Host "[$script:StepNo/$TotalSteps] $text" -ForegroundColor Cyan
}
function Ok($text)   { Write-Host "    OK  $text" -ForegroundColor Green }
function Info($text) { Write-Host "        $text" -ForegroundColor Gray }
function Warn($text) { Write-Host "    !!  $text" -ForegroundColor Yellow }
function Fail($text, $help) {
    Write-Host ''
    Write-Host "    X   $text" -ForegroundColor Red
    if ($help) { Write-Host "        $help" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host 'Setup stopped. Fix the problem above and run it again - finished steps are skipped.' -ForegroundColor Red
    exit 1
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Test-Command($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Install-WithWinget($id, $friendly) {
    if (-not (Test-Command 'winget')) {
        Fail "$friendly is not installed, and the Windows package installer (winget) is missing." `
             "Install $friendly yourself, then run this again. (winget comes with 'App Installer' from the Microsoft Store.)"
    }
    Info "Installing $friendly (this can take a few minutes; Windows may ask for permission)..."
    & winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
    Refresh-Path
}

function Test-Url($url, $timeoutSec = 2) {
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $timeoutSec
        return ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500)
    } catch { return $false }
}

function Test-PortInUse($port) {
    [bool](Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue)
}

function Get-FileHashText($path) { (Get-FileHash -Algorithm SHA256 -Path $path).Hash }

function Set-EnvValue($file, $key, $value) {
    $lines = @()
    if (Test-Path $file) { $lines = @(Get-Content $file) }
    $found = $false
    $lines = $lines | ForEach-Object {
        if ($_ -match "^\s*$([regex]::Escape($key))\s*=") { $found = $true; "$key=$value" } else { $_ }
    }
    if (-not $found) { $lines += "$key=$value" }
    Set-Content -Path $file -Value $lines -Encoding ascii
}

# Find a Python 3.11 - 3.13 interpreter. Returns @(exe, extraArgs, version) or $null.
function Find-Python {
    $candidates = @()
    if (Test-Command 'py') {
        foreach ($v in '3.12', '3.13', '3.11') { $candidates += , @('py', "-$v") }
    }
    if (Test-Command 'python') { $candidates += , @('python') }
    foreach ($c in $candidates) {
        try {
            $exe = $c[0]; $extra = @($c | Select-Object -Skip 1)
            $out = & $exe @extra -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
            if ($LASTEXITCODE -eq 0 -and $out -match '^3\.(1[1-3])$') { return , @($exe, $extra, $out) }
        } catch { }
    }
    return $null
}

# --------------------------------------------------------------- banner ---
Write-Host ''
Write-Host '  =============================================' -ForegroundColor White
Write-Host '   Axiom RAG - private document Q&A, on your PC' -ForegroundColor White
Write-Host '  =============================================' -ForegroundColor White
Write-Host '  First run downloads about 3-4 GB and takes 10-20 minutes.'
Write-Host '  Later runs start in under a minute.'

if (-not (Test-Path $BackendDir) -or -not (Test-Path $FrontendDir)) {
    Fail 'Could not find the app folders next to this script.' 'Run setup.ps1 from the top folder of the Axiom RAG download.'
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Quieter model downloads from Hugging Face on Windows (inherited by the backend).
$env:HF_HUB_DISABLE_SYMLINKS_WARNING = '1'
$env:TOKENIZERS_PARALLELISM = 'false'

# ------------------------------------------------------------- 1. Python ---
Step 'Checking Python'
$py = Find-Python
if (-not $py) {
    Install-WithWinget 'Python.Python.3.12' 'Python 3.12'
    $py = Find-Python
    if (-not $py) {
        Fail 'Python was installed but this window cannot see it yet.' 'Close this window and double-click Start-Axiom.bat again.'
    }
}
$PyExe = $py[0]; $PyArgs = $py[1]
Ok "Python $($py[2])"

# --------------------------------------------------------------- 2. Node ---
Step 'Checking Node.js'
$nodeOk = $false
if (Test-Command 'node') {
    $nv = (& node --version) -replace '^v', ''
    if ([int]($nv.Split('.')[0]) -ge 18) { $nodeOk = $true }
    else { Warn "Node.js $nv is too old (need 18 or newer)." }
}
if (-not $nodeOk) {
    Install-WithWinget 'OpenJS.NodeJS.LTS' 'Node.js LTS'
    if (-not (Test-Command 'node')) {
        Fail 'Node.js was installed but this window cannot see it yet.' 'Close this window and double-click Start-Axiom.bat again.'
    }
}
Ok "Node.js $(& node --version)"

# ------------------------------------------------------------- 3. Ollama ---
Step 'Checking Ollama (runs the AI model locally)'
$OllamaExe = (Get-Command 'ollama' -ErrorAction SilentlyContinue).Source
if (-not $OllamaExe) {
    $guess = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path $guess) { $OllamaExe = $guess }
}
if (-not $OllamaExe) {
    Install-WithWinget 'Ollama.Ollama' 'Ollama'
    $guess = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path $guess) { $OllamaExe = $guess }
    elseif (Test-Command 'ollama') { $OllamaExe = (Get-Command 'ollama').Source }
    else { Fail 'Ollama install did not finish.' 'Install it from https://ollama.com/download and run this again.' }
}
if (-not (Test-Url "$OllamaUrl/api/tags")) {
    Info 'Starting Ollama in the background...'
    Start-Process -FilePath $OllamaExe -ArgumentList 'serve' -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $LogDir 'ollama.log') -RedirectStandardError (Join-Path $LogDir 'ollama.err.log')
    $deadline = (Get-Date).AddSeconds(60)
    while (-not (Test-Url "$OllamaUrl/api/tags") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    if (-not (Test-Url "$OllamaUrl/api/tags")) { Fail 'Ollama did not start.' "See $LogDir\ollama.err.log" }
}
Ok 'Ollama is running'

# ------------------------------------------------- 4. CPU or GPU, model ---
Step 'Choosing CPU or GPU mode'
$device = $Mode
if ($Mode -eq 'auto') {
    $device = 'cpu'
    if (Test-Command 'nvidia-smi') {
        try {
            $vramMb = (& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null |
                       Select-Object -First 1).Trim()
            if ([int]$vramMb -ge 6000) { $device = 'gpu' }
            Info "NVIDIA GPU found with $vramMb MB of memory."
        } catch { }
    } else {
        Info 'No NVIDIA GPU found - that is fine, the AI will run on the processor.'
    }
}
if (-not $Model) { $Model = if ($device -eq 'gpu') { $GpuModel } else { $CpuModel } }
Ok "Mode: $($device.ToUpper())   Model: $Model"

Step "Downloading the AI model ($Model) - only needed once"
$have = (& $OllamaExe list 2>$null) -join "`n"
if ($have -match [regex]::Escape($Model)) {
    Ok 'Model already downloaded'
} else {
    & $OllamaExe pull $Model
    if ($LASTEXITCODE -ne 0) { Fail "Could not download $Model." 'Check your internet connection and run this again.' }
    Ok 'Model downloaded'
}

# ------------------------------------------------------------ 5. Backend ---
Step 'Installing the backend (Python packages)'
$VenvPy  = Join-Path $BackendDir '.venv\Scripts\python.exe'
$ReqFile = Join-Path $BackendDir 'requirements-app.txt'
$ConFile = Join-Path $BackendDir 'constraints.txt'   # exact tested versions
$Stamp   = Join-Path $BackendDir '.venv\.axiom-installed'
if (-not (Test-Path $VenvPy)) {
    Info 'Creating a private Python environment for the app...'
    & $PyExe @PyArgs -m venv (Join-Path $BackendDir '.venv')
    if ($LASTEXITCODE -ne 0) { Fail 'Could not create the Python environment.' }
}
$pipArgs = @('-r', $ReqFile)
$reqHash = Get-FileHashText $ReqFile
if (Test-Path $ConFile) { $pipArgs += @('-c', $ConFile); $reqHash += (Get-FileHashText $ConFile) }
if ((Test-Path $Stamp) -and ((Get-Content $Stamp -Raw).Trim() -eq $reqHash)) {
    Ok 'Backend packages already installed'
} else {
    Info 'Installing packages (about 1 GB, 3-10 minutes)...'
    & $VenvPy -m pip install --disable-pip-version-check -q --upgrade pip | Out-Host
    & $VenvPy -m pip install --disable-pip-version-check -q @pipArgs 2>&1 |
        Tee-Object -FilePath (Join-Path $LogDir 'pip-install.log') | Out-Host
    if ($LASTEXITCODE -ne 0) { Fail 'Installing Python packages failed.' "Details: $LogDir\pip-install.log" }
    Set-Content -Path $Stamp -Value $reqHash
    Ok 'Backend packages installed'
}

# Backend settings (.env). Only the keys below are managed; other edits are kept.
$EnvFile = Join-Path $BackendDir '.env'
if (-not (Test-Path $EnvFile)) {
    Set-Content -Path $EnvFile -Encoding ascii -Value @(
        '# Created by setup.ps1. Re-running setup.ps1 updates LLM_PROVIDER, OLLAMA_MODEL and COMPUTE_DEVICE.'
    )
}
Set-EnvValue $EnvFile 'LLM_PROVIDER'    'ollama'
Set-EnvValue $EnvFile 'OLLAMA_MODEL'    $Model
Set-EnvValue $EnvFile 'COMPUTE_DEVICE'  $device
Set-EnvValue $EnvFile 'OLLAMA_BASE_URL' $OllamaUrl

Info 'Pre-downloading the small search models (embeddings + reranker)...'
$warm = @'
from fastembed import TextEmbedding
from sentence_transformers import CrossEncoder
TextEmbedding("BAAI/bge-small-en-v1.5")
CrossEncoder("cross-encoder/ms-marco-MiniLM-L-6-v2")
print("ok")
'@
$warmOut = $warm | & $VenvPy - 2>&1
if ($LASTEXITCODE -ne 0) { Warn 'Could not pre-download search models; they will download on first use.'; Info ($warmOut | Select-Object -Last 3 | Out-String) }
else { Ok 'Search models ready' }

# ----------------------------------------------------------- 6. Frontend ---
Step 'Installing the web interface'
$Lock   = Join-Path $FrontendDir 'package-lock.json'
$NStamp = Join-Path $FrontendDir 'node_modules\.axiom-installed'
$lockHash = Get-FileHashText $Lock
if ((Test-Path $NStamp) -and ((Get-Content $NStamp -Raw).Trim() -eq $lockHash)) {
    Ok 'Web interface already installed'
} else {
    Push-Location $FrontendDir
    try {
        & npm ci --no-audit --no-fund --loglevel=error 2>&1 | Tee-Object -FilePath (Join-Path $LogDir 'npm-install.log') | Out-Host
        if ($LASTEXITCODE -ne 0) { Fail 'Installing the web interface failed.' "Details: $LogDir\npm-install.log" }
    } finally { Pop-Location }
    Set-Content -Path $NStamp -Value $lockHash
    Ok 'Web interface installed'
}

if ($InstallOnly) {
    Write-Host ''
    Write-Host 'Install finished. Run Start-Axiom.bat (or setup.ps1) to start the app.' -ForegroundColor Green
    exit 0
}

# --------------------------------------------------------------- 7. Run ---
Step 'Starting Axiom RAG'
foreach ($p in $BackendPort, $FrontendPort) {
    if (Test-PortInUse $p) {
        Fail "Port $p is already in use - Axiom RAG may already be running in another window." `
             'Close the other Axiom window (or the program using that port) and run this again.'
    }
}

# -NoNewWindow keeps both servers attached to this console, so closing this
# window stops them too.
$backend = Start-Process -FilePath $VenvPy -WorkingDirectory $BackendDir -NoNewWindow -PassThru `
    -ArgumentList '-m', 'uvicorn', 'api.main:app', '--host', '127.0.0.1', '--port', "$BackendPort" `
    -RedirectStandardOutput (Join-Path $LogDir 'backend.log') -RedirectStandardError (Join-Path $LogDir 'backend.err.log')

$npmCmd = (Get-Command 'npm.cmd' -ErrorAction SilentlyContinue).Source
if (-not $npmCmd) { $npmCmd = 'npm.cmd' }
$frontend = Start-Process -FilePath $npmCmd -WorkingDirectory $FrontendDir -NoNewWindow -PassThru `
    -ArgumentList 'run', 'dev', '--', '--port', "$FrontendPort", '--strictPort' `
    -RedirectStandardOutput (Join-Path $LogDir 'frontend.log') -RedirectStandardError (Join-Path $LogDir 'frontend.err.log')

Info 'Waiting for the backend...'
$deadline = (Get-Date).AddSeconds(180)
while (-not (Test-Url "http://127.0.0.1:$BackendPort/health" 3) -and (Get-Date) -lt $deadline) {
    if ($backend.HasExited) { Fail 'The backend stopped unexpectedly.' "Details: $LogDir\backend.err.log" }
    Start-Sleep -Seconds 2
}
if (-not (Test-Url "http://127.0.0.1:$BackendPort/health" 3)) { Fail 'The backend did not start in time.' "Details: $LogDir\backend.err.log" }
Ok "Backend running on http://localhost:$BackendPort"

Info 'Waiting for the web interface...'
$deadline = (Get-Date).AddSeconds(120)
while (-not (Test-Url "http://localhost:$FrontendPort" 3) -and (Get-Date) -lt $deadline) {
    if ($frontend.HasExited) { Fail 'The web interface stopped unexpectedly.' "Details: $LogDir\frontend.err.log" }
    Start-Sleep -Seconds 2
}
Ok "Web interface running on http://localhost:$FrontendPort"

Info 'Loading the AI model into memory (first answer is faster after this)...'
try {
    $body = @{ model = $Model; prompt = 'Hi'; stream = $false; options = @{ num_predict = 1 } }
    if ($device -eq 'cpu') { $body.options.num_gpu = 0 }
    Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post -ContentType 'application/json' `
        -Body ($body | ConvertTo-Json -Depth 4) -TimeoutSec 180 | Out-Null
    Ok 'Model loaded'
} catch { Warn 'Model warm-up skipped; the first answer may take longer.' }

# -------------------------------------------------------------- 8. Done ---
Step 'Ready'
$url = "http://localhost:$FrontendPort"
Write-Host ''
Write-Host "  Axiom RAG is running at  $url" -ForegroundColor Green
Write-Host '  1. Click "New chat", then upload a PDF, Word, text or Markdown file.'
Write-Host '  2. Ask a question about it.'
if ($device -eq 'cpu') {
    Write-Host '  Running on the processor: answers take roughly 10-40 seconds depending on your PC.' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '  Keep this window open while you use the app. Close it (or press Ctrl+C) to stop.' -ForegroundColor White
Write-Host "  Logs: $LogDir"
if (-not $NoBrowser) { Start-Process $url }

try {
    while (-not $backend.HasExited -and -not $frontend.HasExited) { Start-Sleep -Seconds 2 }
    if ($backend.HasExited)  { Warn "The backend stopped. Details: $LogDir\backend.err.log" }
    if ($frontend.HasExited) { Warn "The web interface stopped. Details: $LogDir\frontend.err.log" }
} finally {
    foreach ($proc in $backend, $frontend) {
        if ($proc -and -not $proc.HasExited) {
            & taskkill /PID $proc.Id /T /F 2>$null | Out-Null
        }
    }
    Write-Host 'Axiom RAG stopped.'
}
