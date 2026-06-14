# Ollama for AMD GPU - Full Automatic Build Script
# Usage: .\auto_build.ps1 -Version 0.20.6

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$Version,

    [switch]$SkipMerge,

    [switch]$SkipROCm,

    [int]$Jobs = 6
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

$DistDir = Join-Path $ScriptDir "dist\windows-amd64"
$TagVersion = "v$Version"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Ollama for AMD GPU Auto Build" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Target Version: $TagVersion" -ForegroundColor Yellow
Write-Host "Parallel Jobs:  $Jobs" -ForegroundColor Yellow
Write-Host "Output Dir:     $DistDir" -ForegroundColor Yellow
Write-Host ""

# Helper function to run commands and suppress stderr progress output
function RunCommand {
    param([scriptblock]$Command)
    $prevEAP = $Global:ErrorActionPreference
    $Global:ErrorActionPreference = "Continue"
    try {
        & $Command
    } finally {
        $Global:ErrorActionPreference = $prevEAP
    }
}

# Helper function to kill lingering build processes and clean locked files
function CleanBuildDir {
    param([string]$Path)

    # Kill lingering build processes
    $processes = @("ninja", "cmake", "clang++", "clang", "hipcc")
    foreach ($proc in $processes) {
        Get-Process -Name $proc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    # Wait for processes to terminate
    Start-Sleep -Seconds 3

    # Force remove directory (retry if locked)
    $retries = 3
    for ($i = 0; $i -lt $retries; $i++) {
        try {
            Remove-Item -Recurse -Force $Path -ErrorAction Stop
            break
        } catch {
            if ($i -lt $retries - 1) {
                Write-Host "Directory locked, waiting..." -ForegroundColor Yellow
                Start-Sleep -Seconds 5
            } else {
                Write-Warning "Could not fully clean $Path"
            }
        }
    }
}

# Step 1: Configure VS BuildTools Environment
Write-Host "[Step 1] Configure VS BuildTools Environment" -ForegroundColor Green

$vsWhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vsWhere)) {
    Write-Error "vswhere.exe not found. Please install Visual Studio Installer."
}

# Prefer BuildTools over Enterprise/Professional (better ROCm clang compatibility)
$vsBuildTools = & $vsWhere -products Microsoft.VisualStudio.Product.BuildTools -latest -property installationPath 2>$null
if ($null -eq $vsBuildTools) {
    $vsPath = & $vsWhere -latest -property installationPath
    Write-Warning "VS BuildTools not found, using: $vsPath"
    Write-Warning "Note: VS Insiders/Enterprise may have STL compatibility issues with ROCm Clang"
} else {
    $vsPath = $vsBuildTools
    Write-Host "Using VS BuildTools: $vsPath"
}

$vcvarsPath = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvarsPath)) {
    Write-Error "vcvars64.bat not found: $vcvarsPath"
}

$tempFile = [System.IO.Path]::GetTempFileName()
cmd /c "`"$vcvarsPath`" >nul 2>&1 && set > `"$tempFile`""
$envVars = Get-Content $tempFile
Remove-Item $tempFile

foreach ($line in $envVars) {
    if ($line -match "^([^=]+)=(.*)$") {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
    }
}

$ninjaPath = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja"
if (Test-Path $ninjaPath) {
    $env:PATH = "$ninjaPath;$env:PATH"
    Write-Host "Ninja: $ninjaPath"
}

# Step 2: Merge upstream version
if (-not $SkipMerge) {
    Write-Host ""
    Write-Host "[Step 2] Merge upstream version $TagVersion" -ForegroundColor Green

    $upstream = git remote get-url upstream 2>$null
    if ($null -eq $upstream) {
        Write-Host "Adding upstream remote..."
        git remote add upstream https://github.com/ollama/ollama.git
    }

    Write-Host "Fetching upstream tags..."
    # --force avoids exit code 1 from "would clobber existing tag" warnings
    RunCommand { git fetch upstream --tags --force --quiet }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git fetch failed"
    }

    $tagExists = git rev-parse "$TagVersion" 2>$null
    if ($null -eq $tagExists) {
        Write-Error "Tag $TagVersion does not exist"
    }

    $status = git status --porcelain
    if ($status) {
        Write-Host "Stashing uncommitted changes..."
        RunCommand { git stash --quiet }
    }

    Write-Host "Merging $TagVersion..."
    RunCommand { git merge "$TagVersion" --no-edit --quiet }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Merge failed. Please resolve conflicts manually."
    }

    Write-Host "Merge successful" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[Step 2] Skipping merge" -ForegroundColor Gray
}

# Step 3: Build ROCm Backend
if (-not $SkipROCm) {
    Write-Host ""
    Write-Host "[Step 3] Build ROCm Backend" -ForegroundColor Green

    $HipPath = "C:\Program Files\AMD\ROCm\7.1"
    if (-not (Test-Path $HipPath)) {
        Write-Error "ROCm 7.1 not found: $HipPath"
    }

    $env:HIP_PATH = $HipPath
    $env:HIPCXX = Join-Path $HipPath "bin\clang++.exe"
    $env:HIP_PLATFORM = "amd"
    $env:CMAKE_PREFIX_PATH = $HipPath
    $env:CC = Join-Path $HipPath "bin\clang.exe"
    $env:CXX = Join-Path $HipPath "bin\clang++.exe"
    $env:LIB = "$env:LIB;$HipPath\lib"
    $env:INCLUDE = "$env:INCLUDE;$HipPath\include"

    Write-Host "ROCm: $HipPath"

    # Use dynamic build directory name with retry to avoid locked file issues
    $BuildDir = $null
    for ($retry = 0; $retry -lt 10; $retry++) {
        $candidate = "build\rocm-$(Get-Date -Format 'yyyyMMddHHmmss')"
        if (-not (Test-Path $candidate)) {
            $BuildDir = $candidate
            break
        }
        Start-Sleep -Seconds 1
    }
    if (-not $BuildDir) {
        Write-Error "Could not find available build directory"
    }
    Write-Host "Build directory: $BuildDir"
    # AMD GPU target list for reference:
    # gfx1030;gfx1031;gfx1032;gfx1034;gfx1035;gfx1036;gfx1100;gfx1101;gfx1102;gfx1103;gfx900:xnack-;gfx906:xnack-;gfx90c:xnack-;gfx1010:xnack-;gfx1011:xnack-;gfx1012:xnack-
    $GPUTargets = "gfx1031"

    Write-Host "CMake configure..."
    $configureLog = "$BuildDir\cmake-configure.log"
    New-Item -ItemType Directory -Force $BuildDir | Out-Null

    $cmakeExe = (Get-Command cmake.exe -ErrorAction SilentlyContinue).Source
    if (-not $cmakeExe) {
        Write-Error "cmake.exe not found in PATH"
    }
    Write-Host "CMake: $cmakeExe"

    # Use splatting for cmake args (avoids space-in-path quoting issues)
    $cmakeArgs = @(
        "-S", "llama/server",
        "-B", $BuildDir,
        "--preset", "rocm_v7_1_windows",
        "-G", "Ninja",
        "-DAMDGPU_TARGETS=$GPUTargets",
        "-DCMAKE_HIP_FLAGS=-parallel-jobs=$Jobs",
        "-DCMAKE_PREFIX_PATH=""$HipPath"""
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $cmakeExe $cmakeArgs 2>&1 | Out-File $configureLog -Encoding UTF8
    $cmakeExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($cmakeExit -ne 0) {
        Write-Host "" -ForegroundColor Red
        Write-Host "=== CMake configure output (last 40 lines) ===" -ForegroundColor Red
        Get-Content $configureLog -Tail 40
        Write-Host "=== Full log: $configureLog ===" -ForegroundColor Yellow
        Write-Error "CMake configure failed (exit code: $cmakeExit)"
    }

    Write-Host "Building HIP backend (parallel: $Jobs)..."
    $buildStart = Get-Date
    $buildLog = "$BuildDir\cmake-build.log"
    $buildArgs = @(
        "--build", $BuildDir,
        "--target", "ggml-hip",
        "--config", "Release",
        "--parallel", "$Jobs"
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $cmakeExe $buildArgs 2>&1 | Out-File $buildLog -Encoding UTF8
    $buildExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($buildExit -ne 0) {
        Write-Host "=== CMake build output (last 30 lines) ===" -ForegroundColor Red
        Get-Content $buildLog -Tail 30
        Write-Host "=== Full log: $buildLog ===" -ForegroundColor Yellow
        Write-Error "ROCm build failed (exit code: $buildExit)"
    }

    $buildTime = (Get-Date) - $buildStart
    Write-Host "ROCm build completed (time: $($buildTime.ToString('mm\:ss')))" -ForegroundColor Green

    Write-Host "Installing output files..."
    $installLog = "$BuildDir\cmake-install.log"
    $installArgs = @(
        "--install", $BuildDir,
        "--component", "llama-server",
        "--prefix", """$DistDir""",
        "--strip"
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $cmakeExe $installArgs 2>&1 | Out-File $installLog -Encoding UTF8
    $installExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP

    if ($installExit -ne 0) {
        Write-Host "=== CMake install output (last 20 lines) ===" -ForegroundColor Red
        Get-Content $installLog -Tail 20
        Write-Host "=== Full log: $installLog ===" -ForegroundColor Yellow
        Write-Error "Install failed (exit code: $installExit)"
    }

    $hipDll = Join-Path $DistDir "lib\ollama\rocm_v7_1\ggml-hip.dll"
    if (Test-Path $hipDll) {
        $hipSize = (Get-Item $hipDll).Length / 1MB
        Write-Host "ggml-hip.dll: $([math]::Round($hipSize, 1)) MB" -ForegroundColor Green
    } else {
        Write-Error "ggml-hip.dll not generated"
    }
} else {
    Write-Host ""
    Write-Host "[Step 3] Skipping ROCm build" -ForegroundColor Gray
}

# Step 4: Build Ollama CLI
Write-Host ""
Write-Host "[Step 4] Build Ollama CLI" -ForegroundColor Green

$mingwPath = "C:\msys64\mingw64\bin"
if (-not (Test-Path "$mingwPath\gcc.exe")) {
    Write-Error "MinGW GCC not found: $mingwPath"
}

$env:PATH = "$mingwPath;$env:PATH"
$env:CGO_ENABLED = "1"
$env:CC = "gcc"
$env:CXX = "g++"
$env:CGO_CFLAGS = "-O3"
$env:CGO_CXXFLAGS = "-O3"

Write-Host "GCC: $mingwPath"

$cliStart = Get-Date
Write-Host "Compiling CLI..."
RunCommand { go build -trimpath -ldflags "-s -w -X=github.com/ollama/ollama/version.Version=$Version-amd -X=github.com/ollama/ollama/server.mode=release" . }
if ($LASTEXITCODE -ne 0) {
    Write-Error "CLI build failed"
}

$cliTime = (Get-Date) - $cliStart
Write-Host "CLI build completed (time: $($cliTime.ToString('mm\:ss')))" -ForegroundColor Green

Copy-Item ollama.exe "$DistDir\" -Force
$cliSize = (Get-Item "$DistDir\ollama.exe").Length / 1MB
Write-Host "ollama.exe: $([math]::Round($cliSize, 1)) MB ($Version-amd)" -ForegroundColor Green

# Copy MinGW runtime DLLs needed by CGO-built Go binary
Write-Host "Copying MinGW runtime DLLs..."
$mingwDlls = @("libwinpthread-1.dll", "libgcc_s_seh-1.dll", "libstdc++-6.dll")
foreach ($dll in $mingwDlls) {
    $src = Join-Path $mingwPath $dll
    if (Test-Path $src) {
        Copy-Item $src "$DistDir\" -Force
        Write-Host "  $dll" -ForegroundColor Gray
    }
}

# Step 5: Generate build report
Write-Host ""
Write-Host "[Step 5] Generate build report" -ForegroundColor Green

$reportFile = Join-Path $DistDir "BUILD_INFO.txt"
$buildDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$gitCommit = git rev-parse --short HEAD
$gitBranch = git rev-parse --abbrev-ref HEAD

$hipDll = Join-Path $DistDir "lib\ollama\rocm_v7_1\ggml-hip.dll"
$hipSizeStr = "N/A"
if (Test-Path $hipDll) {
    $hipSizeStr = [math]::Round((Get-Item $hipDll).Length/1MB, 1).ToString() + " MB"
}

$report = @"
Ollama for AMD GPU - Build Report
=================================

Build Time: $buildDate
Version:    $Version-amd
Git Commit: $gitCommit
Git Branch: $gitBranch

Build Files:
------------
ollama.exe:     $([math]::Round($cliSize, 1)) MB
ggml-hip.dll:   $hipSizeStr

Supported GPUs:
---------------
RDNA 3:  gfx1100-1103 (RX 7900/7800/7700/7600 series)
RDNA 2:  gfx1030-1036 (RX 6900/6800/6700/6600 series)
RDNA 1:  gfx1010-1012 (RX 5700/5600/5500 series)
GCN:     gfx900, gfx906 (Vega, Radeon VII)

Requirements:
-------------
- ROCm 7.1 SDK
- AMD GPU Driver (latest)
- Windows 10/11 x64

Usage:
------
cd dist\windows-amd64
.\ollama.exe serve
.\ollama.exe run llama3
"@

Set-Content -Path $reportFile -Value $report -Encoding UTF8
Write-Host "Report saved: $reportFile"

# Complete
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Build Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Output: $DistDir" -ForegroundColor Yellow
Write-Host ""
Write-Host "Usage:" -ForegroundColor White
Write-Host "  cd dist\windows-amd64" -ForegroundColor Gray
Write-Host "  .\ollama.exe serve" -ForegroundColor Gray
Write-Host "  .\ollama.exe run llama3" -ForegroundColor Gray
Write-Host ""

Write-Host "Files:" -ForegroundColor White
Get-ChildItem "$DistDir" -Recurse -File |
    Where-Object { $_.Extension -in '.exe','.dll' } |
    ForEach-Object {
        $size = [math]::Round($_.Length/1MB, 1)
        Write-Host "  $($_.Name): $size MB" -ForegroundColor Gray
    }
