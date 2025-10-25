# ==========================================
# NVIDIA GPU Puanlama – Evrensel (Tesla → Blackwell)
# NVML yalnız: çekirdek sayısı, saatler, bellek, bus width
# 1080 ↔ 5090 sabit kalibrasyon; 5090 = 10000 puan
# ==========================================

# ================================
# ExecutionPolicy Bootstrap (Self)
# ================================
if (-not $env:__GPU_BOOT_DONE) {
  $env:__GPU_BOOT_DONE = "1"
  try { if ($PSCommandPath) { Unblock-File -Path $PSCommandPath -ErrorAction Stop } } catch {}
  try {
    if ((Get-ExecutionPolicy -Scope Process) -ne 'Bypass') {
      Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
    }
  } catch {}
  $needRelaunch = $true
  try { if ((Get-ExecutionPolicy) -eq 'Bypass') { $needRelaunch = $false } } catch {}
  if ($needRelaunch -and $PSCommandPath) {
    $psExe = $null
    try { $psExe = (Get-Command pwsh -ErrorAction Stop).Source } catch {}
    if (-not $psExe) { $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $args
    try { & $psExe @argList; exit $LASTEXITCODE } catch {}
  }
}

# -- NVML P/Invoke türünü yalnızca bir kez ekle --
if (-not ('NvmlWrapper' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NvmlWrapper {
    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlInit_v2();

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlShutdown();

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetPowerManagementLimitConstraints(
        IntPtr device, out uint minLimitMilliWatts, out uint maxLimitMilliWatts);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetHandleByIndex_v2(uint index, out IntPtr device);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetName(IntPtr device, byte[] name, uint length);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetCudaComputeCapability(IntPtr device, out int major, out int minor);

    // Opsiyonel; bazı NVML sürümlerinde yok
    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint="nvmlDeviceGetNumGpuCores")]
    public static extern int nvmlDeviceGetNumGpuCores(IntPtr device, out uint numCores);

    // Attributes V2 yoksa V1'e düş
    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint="nvmlDeviceGetAttributes_v2")]
    public static extern int nvmlDeviceGetAttributes_v2(IntPtr device, out DeviceAttributes attributes);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint="nvmlDeviceGetAttributes")]
    public static extern int nvmlDeviceGetAttributes(IntPtr device, out DeviceAttributes attributes);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetMaxClockInfo(IntPtr device, int type, out int clockMHz);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetMemoryInfo(IntPtr device, out Memory memory);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetMemoryBusWidth(IntPtr device, out uint busWidth);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetEnforcedPowerLimit(IntPtr device, out uint limitMilliWatts);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetPowerManagementDefaultLimit(IntPtr device, out uint defaultLimitMilliWatts);

    public const int NVML_CLOCK_SM  = 1;
    public const int NVML_CLOCK_MEM = 2;

    [StructLayout(LayoutKind.Sequential)]
    public struct Memory { public ulong total; public ulong free; public ulong used; }

    [StructLayout(LayoutKind.Sequential)]
    public struct DeviceAttributes {
        public uint multiprocessorCount;
        public uint sharedCopyEngineCount;
        public uint sharedDecoderCount;
        public uint sharedEncoderCount;
        public uint sharedJpegCount;
        public uint sharedOfaCount;
        public uint gpuInstanceSliceCount;
        public uint computeInstanceSliceCount;
        public ulong memorySizeMB;
    }
}
"@
}

# --- Parametreler / Katsayılar ---
$alpha = 0.55; $beta = 0.45

$ArchEff = @{
  "Tesla"     = 0.45
  "Fermi"     = 0.55
  "Kepler"    = 0.62
  "Maxwell"   = 0.80
  "Pascal"    = 1.00
  "Turing"    = 1.05
  "Ampere"    = 1.08
  "Ada"       = 1.10
  "Blackwell" = 1.12
}
$CompFac = @{
  "Tesla"     = 1.00
  "Fermi"     = 1.00
  "Kepler"    = 1.00
  "Maxwell"   = 1.15
  "Pascal"    = 1.25
  "Turing"    = 1.30
  "Ampere"    = 1.35
  "Ada"       = 1.40
  "Blackwell" = 1.45
}
$LegacyCal = @{
  "Tesla"     = 6.0
  "Fermi"     = 4.5
  "Kepler"    = 1.0
  "Maxwell"   = 1.0
  "Pascal"    = 1.0
  "Turing"    = 1.0
  "Ampere"    = 1.0
  "Ada"       = 1.0
  "Blackwell" = 1.0
}

function Get-ArchFromCC($major,$minor){
  switch ($major) {
    1{"Tesla"}
    2{"Fermi"}
    3{"Kepler"}
    5{"Maxwell"}
    6{"Pascal"}
    7{"Turing"}
    8{ if($minor -ge 9){"Ada"} else {"Ampere"} }
    9{"Blackwell"}
    10{"Blackwell"}
    11{"Blackwell"}
    12{"Blackwell"}
    default{"Pascal"}
  }
}

# --- Form factor profilleri + tag ---
$script:FormFactor = @{
  Laptop  = @{ P_ref = 120000.0; Exp = 0.18 }
  Desktop = @{ P_ref = 160000.0; Exp = 0.25 }
}
$script:MobileNamePatterns = '(?i)\b(Laptop|Notebook|Mobile|Max\-Q)\b'
function Get-FormFactorTag { param([string]$gpuName)
  if ([string]::IsNullOrWhiteSpace($gpuName)) { return 'Desktop' }
  if ($gpuName -match $script:MobileNamePatterns) { return 'Laptop' }
  'Desktop'
}

# --- Mobil uplift ---
$script:MobileBoost = @{
  Default   = 1.06
  Turing    = 1.05
  Ampere    = 1.06
  Ada       = 1.07
  Blackwell = 1.05
}
function Get-MobileBoost {
  param([string]$arch, [uint32]$plMaxLocal)
  [double]$b = 1.06
  if ($script:MobileBoost.ContainsKey($arch)) { $b = [double]$script:MobileBoost[$arch] }
  if     ($plMaxLocal -lt  90000) { $b *= 1.10 }
  elseif ($plMaxLocal -lt 110000) { $b *= 1.06 }
  elseif ($plMaxLocal -lt 130000) { $b *= 1.03 }
  else                            { $b *= 1.01 }
  return [double]$b
}

# --- SM başına CUDA çekirdeği ---
function Get-CudaPerSM($major,$minor){
  $key = "$major.$minor"
  switch ($key) {
    { $_ -like "9.*" } { return 128 } # Blackwell (varsay)
    "8.9" { return 128 }  # Ada
    "8.6" { return 128 }  # Ampere GA106+
    "7.5" { return 64 }   # Turing
    "7.0" { return 64 }   # Turing
    "6.1" { return 128 }  # Pascal GP104
    "5.0" { return 128 }  # Maxwell
    default {
      if ($major -le 2)      { return 32 }
      elseif ($major -eq 3)  { return 192 }
      else                   { return 128 }
    }
  }
}

# --- Bileşik ve Skor fonksiyonları ---
function Compute-Composite { param([double]$tf,[double]$rawBW,[string]$arch)
  $effBW = $rawBW * $CompFac[$arch]
  $p1 = [math]::Pow($tf,    [double]$alpha)
  $p2 = [math]::Pow($effBW, [double]$beta)
  return $p1 * $p2 * $ArchEff[$arch] * $LegacyCal[$arch]
}

# Kalibrasyon (GTX1080 ↔ RTX5090)
$B_Comp = 105.5
$SB     = 10000/4.25
$Z_Comp = 747.0
$SZ     = 10000
$Gamma  = ([math]::Log($SZ)-[math]::Log($SB)) / ([math]::Log($Z_Comp)-[math]::Log($B_Comp))

function Score-FromComposite { param([double]$C)
  if ($C -le 0) { return 0.0 }
  $y = [math]::Log($SB) + $Gamma * ([math]::Log($C) - [math]::Log($B_Comp))
  [math]::Round([math]::Exp($y), 4)
}

# --- Ref 4060 skor hedefi (fonksiyonlar tanımlandıktan sonra) ---
[double]$ref4060_tf    = (3072 * 2.0 * 2460) / 1e6
[double]$ref4060_rawBW = ((128)/8.0) * 17000 * 1.0 / 1000.0
[double]$ref4060_comp  = Compute-Composite -tf $ref4060_tf -rawBW $ref4060_rawBW -arch 'Ada'
[double]$Ref4060Score  = [double](Score-FromComposite $ref4060_comp)

# =================
# NVML Oku + Skor
# =================
[NvmlWrapper]::nvmlInit_v2() | Out-Null
try {
  $dev=[IntPtr]::Zero
  [void][NvmlWrapper]::nvmlDeviceGetHandleByIndex_v2(0,[ref]$dev)

  # İsim
  $buf = New-Object byte[] 96
  [void][NvmlWrapper]::nvmlDeviceGetName($dev,$buf,[uint32]$buf.Length)
  $name = ([Text.Encoding]::ASCII.GetString($buf)).Trim([char]0)

  # Compute capability ve mimari
  $maj=0;$min=0; [void][NvmlWrapper]::nvmlDeviceGetCudaComputeCapability($dev,[ref]$maj,[ref]$min)
  $arch = Get-ArchFromCC $maj $min

  # CUDA çekirdek sayısı
  $cuda = 0
  try {
    $n=[uint32]0
    $r=[NvmlWrapper]::nvmlDeviceGetNumGpuCores($dev,[ref]$n)
    if ($r -eq 0 -and $n -gt 0) { $cuda = [int]$n }
  } catch [System.EntryPointNotFoundException] { $cuda = 0 }
  if ($cuda -le 0) {
    $attrs = New-Object NvmlWrapper+DeviceAttributes
    $ok = [NvmlWrapper]::nvmlDeviceGetAttributes_v2($dev,[ref]$attrs)
    if ($ok -ne 0) { $ok = [NvmlWrapper]::nvmlDeviceGetAttributes($dev,[ref]$attrs) }
    if ($ok -eq 0 -and $attrs.multiprocessorCount -gt 0) {
      $cuda = [int]$attrs.multiprocessorCount * (Get-CudaPerSM $maj $min)
    }
  }

  # Saatler
  $smClk=0;  [void][NvmlWrapper]::nvmlDeviceGetMaxClockInfo($dev,[NvmlWrapper]::NVML_CLOCK_SM, [ref]$smClk)
  $memClk=0; [void][NvmlWrapper]::nvmlDeviceGetMaxClockInfo($dev,[NvmlWrapper]::NVML_CLOCK_MEM,[ref]$memClk)

  # TFLOPS
  $tf = ([double]$cuda * 2.0 * [double]$smClk) / 1e6

  # Bellek ve bus width
  $memInfo = New-Object NvmlWrapper+Memory
  [void][NvmlWrapper]::nvmlDeviceGetMemoryInfo($dev,[ref]$memInfo)
  $vramGB = [math]::Round($memInfo.total/1GB, 2)

  $busW = [uint32]0
  $bwrc = [NvmlWrapper]::nvmlDeviceGetMemoryBusWidth($dev,[ref]$busW)
  $busWidth = if ($bwrc -eq 0 -and $busW -gt 0) { [int]$busW } else { 128 }

  # DDR faktörü
  $ddrFactor = if ($arch -in @("Tesla","Fermi","Kepler","Maxwell","Pascal")) { 2.0 } else { 1.0 }

  # Bant genişliği (GB/s)
  $rawBW = (([double]$busWidth)/8.0) * ([double]$memClk) * $ddrFactor / 1000.0

  # Hesap ve skor (ön-normalizasyon)
  $comp  = Compute-Composite -tf $tf -rawBW $rawBW -arch $arch
  $score = Score-FromComposite $comp

  # -------------------------------
  # Mode-proof güç normalizasyonu
  # -------------------------------
  [string]$ff = Get-FormFactorTag -gpuName $name
  [double]$P_ref  = [double]$FormFactor[$ff].P_ref
  [double]$PowExp = [double]$FormFactor[$ff].Exp

  # Kartın donanımsal PL üst sınırı (constraint maksimum)
  [uint32]$plMax = 0; [uint32]$plMin = 0
  try {
    if ([NvmlWrapper]::nvmlDeviceGetPowerManagementLimitConstraints($dev, [ref]$plMin, [ref]$plMax) -ne 0) {
      $plMax = 0
    }
  } catch { $plMax = 0 }

  if ($plMax -le 0) { $plMax = if ($ff -eq 'Laptop') { 120000 } else { 160000 } }

  # Güç çarpanı
  [double]$PowerFac = [math]::Pow(([double]$plMax)/$P_ref, $PowExp)
  $score = [math]::Round([double]$score * $PowerFac, 4)

  # Tek seferlik mobil uplift
  if ($ff -eq 'Laptop') {
    [double]$uplift = Get-MobileBoost -arch $arch -plMaxLocal $plMax
    $score = [math]::Round([double]$score * $uplift, 4)
  }

  # Nihai skorun globalleştirilmesi
  $script:FinalScore = [double]$score
  $script:score      = [double]$score
  $script:name       = [string]$name

  # Çıktı
  Write-Output "GPU: $name"
  Write-Output "Architecture: $arch (CC: $maj.$min)"
  Write-Output "CUDA Cores: $cuda"
  Write-Output "SM Clock (MHz): $smClk"
  Write-Output "Mem Clock (MHz): $memClk"
  Write-Output "VRAM (GB): $vramGB"
  Write-Output "Bus Width (bit): $busWidth"
  Write-Output "TFLOPS: $([math]::Round($tf, 4))"
  Write-Output "Raw Bandwidth (GB/s): $([math]::Round($rawBW, 2))"
  Write-Output "Composite: $([math]::Round($comp, 6))"
  Write-Output "Score (Normalize, RTX 5090=10000): $score"

} finally {
  [NvmlWrapper]::nvmlShutdown() | Out-Null
}

# ==========================
# Yardımcılar: skor/etiket
# ==========================
function Get-UserGpuLabelAndScore {
    $userLabel = $null
    foreach ($nm in 'name','gpuName','active') {
        if (Get-Variable -Scope Script -Name $nm -ErrorAction SilentlyContinue) {
            $val = Get-Variable -Scope Script -Name $nm -ValueOnly
            if ($nm -eq 'active') { try { $userLabel = [string]$val.Name } catch {} }
            else { $userLabel = [string]$val }
            if (-not [string]::IsNullOrWhiteSpace($userLabel)) { break }
        }
    }
    if ([string]::IsNullOrWhiteSpace($userLabel)) { $userLabel = 'My GPU' }

    $userScore = $null
    foreach ($v in 'FinalScore','score','activeScore','Score') {
        if (Get-Variable -Scope Script -Name $v -ErrorAction SilentlyContinue) {
            try { $userScore = [double](Get-Variable -Scope Script -Name $v -ValueOnly) } catch {}
            if ($null -ne $userScore -and -not [double]::IsNaN($userScore)) { break }
        }
    }
    if ($null -eq $userScore -and (Get-Variable -Scope Script -Name 'comp' -ErrorAction SilentlyContinue)) {
        try { [double]$c = [double](Get-Variable -Scope Script -Name 'comp' -ValueOnly)
              $userScore = [double](Score-FromComposite $c) } catch {}
    }
    if ($null -eq $userScore -or [double]::IsNaN($userScore)) {
        $userScore = 0.0
        $userLabel = "$userLabel (score not found)"
    }
    [PSCustomObject]@{ Label = $userLabel; Score = $userScore }
}

function Score-FromSpecs($r){
    [double]$tf = ([double]$r.CUDA * 2.0 * [double]$r.SMclk) / 1e6
    [double]$ddrFactor = if ($r.Arch -in @("Tesla","Fermi","Kepler","Maxwell","Pascal")) { 2.0 } else { 1.0 }
    [double]$rawBW = (([double]$r.Bus)/8.0) * ([double]$r.Memclk) * $ddrFactor / 1000.0
    [double]$c = Compute-Composite -tf $tf -rawBW $rawBW -arch $r.Arch
    [PSCustomObject]@{ Label=[string]$r.Name; Score=[double](Score-FromComposite $c) }
}

# ==========================
# GPU Skor Grafiği (APPEND)
# ==========================
$refs = @(
  @{ Name="GTX 1050 (Desktop)"; CUDA=640;  SMclk=1455; Memclk=7000;  Bus=128; Arch="Pascal"    },
  @{ Name="RTX 2060 (Desktop)"; CUDA=1920; SMclk=1680; Memclk=14000; Bus=192; Arch="Turing"    },
  @{ Name="RTX 3050 (Desktop)"; CUDA=2560; SMclk=1777; Memclk=14000; Bus=128; Arch="Ampere"    },
  @{ Name="RTX 4060 (Desktop)"; CUDA=3072; SMclk=2460; Memclk=17000; Bus=128; Arch="Ada"       },
  @{ Name="RTX 5060 (Desktop)"; CUDA=3584; SMclk=2600; Memclk=21000; Bus=192; Arch="Blackwell" }
)

$gpuScores = [ordered]@{}
foreach($r in $refs){ $s = Score-FromSpecs $r; $gpuScores[[string]$s.Label] = [double]$s.Score }

$user = Get-UserGpuLabelAndScore
$userKey = if ($gpuScores.Contains($user.Label)) { "$($user.Label) • mine" } else { "$($user.Label) (My GPU)" }
$gpuScores[[string]$userKey] = [double]$user.Score

[string]$desktop = [Environment]::GetFolderPath("Desktop")
[string]$outfile = Join-Path $desktop ("GPU_Scores_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".png")

try {
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    [string[]]$labels = @($gpuScores.Keys | ForEach-Object { [string]$_ })
    [double[]]$values = @($labels | ForEach-Object { [double]$gpuScores[$_] })
    [int]$n = [int]$labels.Length
    if ($n -le 0) { throw "No data" }

    [int]$bmpW = 1200
    [int]$bmpH = 640
    [int]$margin = 80
    [int]$plotW = [int]($bmpW - (2 * $margin))
    [int]$plotH = [int]($bmpH - (2 * $margin))

    $bmp = New-Object System.Drawing.Bitmap([int]$bmpW, [int]$bmpH)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

    $font     = New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericSansSerif,10)
    $fntTitle = New-Object System.Drawing.Font([System.Drawing.FontFamily]::GenericSansSerif,14,[System.Drawing.FontStyle]::Bold)

    [double]$maxScore = [double](($values | Measure-Object -Maximum).Maximum)
    if ($maxScore -le 0) { $maxScore = 1.0 }

    [int]$barW  = [int]([math]::Max(6, ([math]::Floor($plotW / [math]::Max(1,$n)) - 10)))
    [int]$x = [int]$margin

    $g.DrawString("GPU Puanları Karşılaştırma", $fntTitle, [System.Drawing.Brushes]::Black, [int]20, [int]15)

    for ([int]$i=0; $i -lt $n; $i++) {
        [double]$val = [double]$values[$i]
        [int]$h = [int]([math]::Floor($plotH * ($val / $maxScore)))
        $rect = New-Object System.Drawing.Rectangle(
            [int]$x, [int]([int]$bmpH - [int]$margin - [int]$h),
            [int]$barW, [int]$h
        )
        $g.FillRectangle([System.Drawing.Brushes]::Gray, $rect)
        $g.DrawRectangle([System.Drawing.Pens]::Black, $rect)

        $g.DrawString(([math]::Round($val,0)).ToString(), $font, [System.Drawing.Brushes]::Black,
            [int]$x, [int](([int]$bmpH - [int]$margin - [int]$h) - 20))
        $g.DrawString([string]$labels[$i], $font, [System.Drawing.Brushes]::Black,
            [int]$x, [int](([int]$bmpH - [int]$margin) + 5))

        $x = [int]($x + $barW + 10)
    }

    $bmp.Save([string]$outfile, [System.Drawing.Imaging.ImageFormat]::Png) | Out-Null
    Write-Output "PNG kaydedildi: $outfile"
}
catch {
    throw "Grafik oluşturulamadı: $($_.Exception.Message)"
}
finally {
    if ($g)   { $g.Dispose() }
    if ($bmp) { $bmp.Dispose() }
}
