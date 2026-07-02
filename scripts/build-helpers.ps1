param(
  [string]$AndroidHome = $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } elseif ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } else { "D:\DevDeps\AndroidSdk" }),
  [int]$AndroidApi = 23
)

$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $Root

function Resolve-Go {
  $cmd = Get-Command go -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $local = "D:\DevDeps\GoLang\bin\go.exe"
  if (Test-Path $local) { return $local }
  throw "go was not found. Install Go or pass it on PATH."
}

function Resolve-D8 {
  $cmd = Get-Command d8 -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $sdk = Resolve-Path $AndroidHome
  $candidate = Get-ChildItem -LiteralPath $sdk -Recurse -Filter d8.bat -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "\\build-tools\\" } |
    Sort-Object FullName -Descending |
    Select-Object -First 1
  if ($candidate) { return $candidate.FullName }
  throw "d8 was not found under $AndroidHome"
}

function Resolve-NdkBin {
  $sdk = Resolve-Path $AndroidHome
  $ndkRoot = Join-Path $sdk "ndk"
  if (!(Test-Path $ndkRoot)) {
    throw "Android NDK was not found under $ndkRoot"
  }
  $ndk = Get-ChildItem -LiteralPath $ndkRoot -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1
  if (!$ndk) { throw "Android NDK was not found under $ndkRoot" }

  $hostBin = Join-Path $ndk.FullName "toolchains\llvm\prebuilt\windows-x86_64\bin"
  if (!(Test-Path $hostBin)) {
    throw "Android NDK clang bin was not found: $hostBin"
  }
  return $hostBin
}

function Resolve-AndroidClang {
  param([string]$HostBin, [string]$Triple)
  $path = Join-Path $HostBin "$Triple-linux-android$AndroidApi-clang.cmd"
  if (Test-Path $path) { return $path }
  $fallback = Get-ChildItem -LiteralPath $HostBin -Filter "$Triple-linux-android*-clang.cmd" |
    Sort-Object Name -Descending |
    Select-Object -First 1
  if ($fallback) { return $fallback.FullName }
  throw "Android clang wrapper was not found for $Triple"
}

function Invoke-Native {
  param([string]$FilePath, [string[]]$Arguments)
  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$FilePath exited with code $LASTEXITCODE"
  }
}

$Go = Resolve-Go
$D8 = Resolve-D8
$Javac = (Get-Command javac -ErrorAction Stop).Source
$NdkBin = Resolve-NdkBin
$Arm64Cc = Resolve-AndroidClang $NdkBin "aarch64"
$X64Cc = Resolve-AndroidClang $NdkBin "x86_64"

New-Item -ItemType Directory -Force module/bin/arm64-v8a, module/bin/x86_64 | Out-Null

$oldGoos = $env:GOOS
$oldGoarch = $env:GOARCH
$oldCgo = $env:CGO_ENABLED
$oldCc = $env:CC
try {
  $env:CGO_ENABLED = "1"
  $env:GOOS = "android"

  $env:GOARCH = "arm64"
  $env:CC = $Arm64Cc
  Invoke-Native $Go @("build", "-trimpath", "-tags", "netgo,osusergo", "-ldflags", "-s -w", "-o", "module/bin/arm64-v8a/magic-fetch", "./tools/magic-fetch")
  Invoke-Native $Go @("build", "-trimpath", "-tags", "netgo,osusergo", "-ldflags", "-s -w", "-o", "module/bin/arm64-v8a/magicctl-go", "./tools/magicctl-go")

  $env:GOARCH = "amd64"
  $env:CC = $X64Cc
  Invoke-Native $Go @("build", "-trimpath", "-tags", "netgo,osusergo", "-ldflags", "-s -w", "-o", "module/bin/x86_64/magic-fetch", "./tools/magic-fetch")
  Invoke-Native $Go @("build", "-trimpath", "-tags", "netgo,osusergo", "-ldflags", "-s -w", "-o", "module/bin/x86_64/magicctl-go", "./tools/magicctl-go")
} finally {
  $env:GOOS = $oldGoos
  $env:GOARCH = $oldGoarch
  $env:CGO_ENABLED = $oldCgo
  $env:CC = $oldCc
}

$BuildDir = Join-Path $Root "build/applist"
$ClassesDir = Join-Path $BuildDir "classes"
$DexDir = Join-Path $BuildDir "dex"
Remove-Item -LiteralPath $BuildDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $ClassesDir, $DexDir | Out-Null

Invoke-Native $Javac @("--release", "8", "-encoding", "UTF-8", "-d", $ClassesDir, "module/tools/applist/AppList.java")
Invoke-Native $D8 @("--min-api", "33", "--output", $DexDir, (Join-Path $ClassesDir "AppList.class"))
Copy-Item -LiteralPath (Join-Path $DexDir "classes.dex") -Destination module/bin/applist.dex -Force

Write-Host "built module/bin/arm64-v8a/magic-fetch"
Write-Host "built module/bin/arm64-v8a/magicctl-go"
Write-Host "built module/bin/x86_64/magic-fetch"
Write-Host "built module/bin/x86_64/magicctl-go"
Write-Host "built module/bin/applist.dex"
