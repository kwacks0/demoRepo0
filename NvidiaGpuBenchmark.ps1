# ==========================================
# NVIDIA GPU Puanlama – Evrensel (Tesla → Blackwell)
# NVML yalnız: çekirdek sayısı, saatler, bellek, bus width
# 1080 ↔ 5090 sabit kalibrasyon; 5090 = 10000 puan
# ==========================================

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
    public static extern int nvmlDeviceGetHandleByIndex_v2(uint index, out IntPtr device);
    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetName(IntPtr device, byte[] name, uint length);
    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int nvmlDeviceGetCudaComputeCapability(IntPtr device, out int major, out int minor);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl, EntryPoint="nvmlDeviceGetNumGpuCores")]
    public static extern int nvmlDeviceGetNumGpuCores(IntPtr device, out uint numCores);

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
} # tür zaten yüklüyse yeniden derlenmez


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
    8{ if($minor -eq 9){"Ada"} else {"Ampere"} }
    9{"Blackwell"}
    10{"Blackwell"}
    11{"Blackwell"}
    12{"Blackwell"}   # ← ekle
    default{"Pascal"}
  }
}


function Get-CudaPerSM($major,$minor){
  if ($major -eq 1) { return 8 }  # Tesla ~8/SM
  switch ("$major.$minor") {
    "9.0"{128};"8.9"{128};"8.6"{128}
    "7.5"{64}; "7.0"{64}
    "6.1"{128};"5.0"{128}
    "3.0"{192}; default{64}
  }
}

function Compute-Composite($tf,$rawBW,$arch){
  $effBW = $rawBW * $CompFac[$arch]
  $p1 = [math]::Pow([double]$tf,    [double]$alpha)
  $p2 = [math]::Pow([double]$effBW, [double]$beta)
  return $p1 * $p2 * $ArchEff[$arch] * $LegacyCal[$arch]
}

# --- Kalibrasyon (GTX1080 ↔ RTX5090) ---
$B_Comp = 105.5
$SB     = 10000/4.25
$Z_Comp = 747.0
$SZ     = 10000
$Gamma  = ([math]::Log($SZ)-[math]::Log($SB)) / ([math]::Log($Z_Comp)-[math]::Log($B_Comp))
function Score-FromComposite($C){
  if ([double]$C -le 0) { return 0.0 }
  $y = [math]::Log($SB) + $Gamma * ([math]::Log([double]$C) - [math]::Log($B_Comp))
  [math]::Round([math]::Exp($y), 4)
}

# =================
# NVML Oku + Skor
# =================
[NvmlWrapper]::nvmlInit_v2() | Out-Null
try {
  $dev=[IntPtr]::Zero
  [NvmlWrapper]::nvmlDeviceGetHandleByIndex_v2(0,[ref]$dev) | Out-Null

  # İsim
  $buf = New-Object byte[] 96
  [NvmlWrapper]::nvmlDeviceGetName($dev,$buf,[uint32]$buf.Length) | Out-Null
  $name = ([Text.Encoding]::ASCII.GetString($buf)).Trim([char]0)

  # Compute capability ve mimari
  $maj=0;$min=0; [NvmlWrapper]::nvmlDeviceGetCudaComputeCapability($dev,[ref]$maj,[ref]$min) | Out-Null
  $arch = Get-ArchFromCC $maj $min

  # CUDA çekirdek sayısı
  $cuda = 0
  try {
    $n=[uint32]0
    $r=[NvmlWrapper]::nvmlDeviceGetNumGpuCores($dev,[ref]$n)
    if ($r -eq 0 -and $n -gt 0) { $cuda = [int]$n }
  } catch [System.EntryPointNotFoundException] {
    $cuda = 0
  }
  if ($cuda -le 0) {
    $attrs = New-Object NvmlWrapper+DeviceAttributes
    $ok = [NvmlWrapper]::nvmlDeviceGetAttributes_v2($dev,[ref]$attrs)
    if ($ok -ne 0) { $ok = [NvmlWrapper]::nvmlDeviceGetAttributes($dev,[ref]$attrs) }
    if ($ok -eq 0 -and $attrs.multiprocessorCount -gt 0) {
      $cuda = [int]$attrs.multiprocessorCount * (Get-CudaPerSM $maj $min)
    }
  }

  # Saatler
  $smClk=0;  [NvmlWrapper]::nvmlDeviceGetMaxClockInfo($dev,[NvmlWrapper]::NVML_CLOCK_SM, [ref]$smClk)  | Out-Null
  $memClk=0; [NvmlWrapper]::nvmlDeviceGetMaxClockInfo($dev,[NvmlWrapper]::NVML_CLOCK_MEM,[ref]$memClk) | Out-Null

  # TFLOPS
  $tf = ([double]$cuda * 2.0 * [double]$smClk) / 1e6

  # Bellek ve bus width
  $memInfo = New-Object NvmlWrapper+Memory
  [NvmlWrapper]::nvmlDeviceGetMemoryInfo($dev,[ref]$memInfo) | Out-Null
  $vramGB = [math]::Round($memInfo.total/1GB, 2)

  $busW = [uint32]0
  $bwrc = [NvmlWrapper]::nvmlDeviceGetMemoryBusWidth($dev,[ref]$busW)
  $busWidth = if ($bwrc -eq 0 -and $busW -gt 0) { [int]$busW } else { 128 }

  # GDDR data-rate koruması (NVML çoğu zaman efektif değeri döndürür)
  $ddrFactor = 2.0
  if ([double]$memClk -gt 6000) { $ddrFactor = 1.0 }

  # Bant genişliği (GB/s) = (BusWidth/8) * MemClock(MHz) * DDRfactor / 1000
  $rawBW = (([double]$busWidth)/8.0) * ([double]$memClk) * $ddrFactor / 1000.0

  # Hesap ve skor
  $comp  = Compute-Composite -tf $tf -rawBW $rawBW -arch $arch
  $score = Score-FromComposite $comp

  # Güç sınıfı normalizasyonu (mobil vs desktop)
  $pl = [uint32]0
  $plRc = -1
  try { $plRc = [NvmlWrapper]::nvmlDeviceGetEnforcedPowerLimit($dev,[ref]$pl) } catch { $plRc = -1 }
  if ($plRc -ne 0 -or $pl -le 0) { $pl = 120000 }    # mW varsayılan mobil
  $P_ref = 200000.0                                  # mW desktop referansı
  $PowerFac = [math]::Pow(([double]$pl)/$P_ref, 0.35)
  $score = [math]::Round($score * $PowerFac, 4)

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
# GPU Skor Grafiği (APPEND)
# ==========================
function Get-UserGpuLabelAndScore {
    # 1) Ad
    $userLabel = $null
    if (Get-Variable -Name name -ErrorAction SilentlyContinue)          { $userLabel = [string]$name }
    elseif (Get-Variable -Name gpuName -ErrorAction SilentlyContinue)   { $userLabel = [string]$gpuName }
    elseif (Get-Variable -Name active -ErrorAction SilentlyContinue)    { try { $userLabel = [string]$active.Name } catch {} }
    if ([string]::IsNullOrWhiteSpace($userLabel)) { $userLabel = "My GPU" }

    # 2) Skor
    $userScore = $null
    if (Get-Variable -Name score -ErrorAction SilentlyContinue)           { $userScore = [double]$score }
    elseif (Get-Variable -Name activeScore -ErrorAction SilentlyContinue) { $userScore = [double]$activeScore }
    elseif (Get-Variable -Name Score -ErrorAction SilentlyContinue)       { $userScore = [double]$Score }
    elseif (Get-Variable -Name comp -ErrorAction SilentlyContinue) {
        if (Get-Command -Name Score-FromComposite -ErrorAction SilentlyContinue) {
            try { $userScore = [double](Score-FromComposite $comp) } catch {}
        }
    }
    if ($null -eq $userScore -or [double]::IsNaN($userScore)) {
        $userScore = 0.0
        $userLabel = "$userLabel (score not found)"
    }
    return [PSCustomObject]@{ Label = $userLabel; Score = [double]$userScore }
}

# Referansları formülden üret
function Score-FromSpecs($r){
    $tf = ([double]$r.CUDA * 2.0 * [double]$r.SMclk) / 1e6
    $ddrFactor = 2.0
    if ([double]$r.Memclk -gt 6000) { $ddrFactor = 1.0 }
    $rawBW = (([double]$r.Bus)/8.0) * ([double]$r.Memclk) * $ddrFactor / 1000.0
    $c = Compute-Composite -tf $tf -rawBW $rawBW -arch $r.Arch
    [PSCustomObject]@{ Label=$r.Name; Score=(Score-FromComposite $c) }
}

$refs = @(
  @{ Name="GTX 1050 (Desktop)"; CUDA=640;  SMclk=1455; Memclk=7000;  Bus=128; Arch="Pascal"    },
  @{ Name="RTX 2060 (Desktop)"; CUDA=1920; SMclk=1680; Memclk=14000; Bus=192; Arch="Turing"    },
  @{ Name="RTX 3050 (Desktop)"; CUDA=2560; SMclk=1777; Memclk=14000; Bus=128; Arch="Ampere"    },
  @{ Name="RTX 4060 (Desktop)"; CUDA=3072; SMclk=2460; Memclk=17000; Bus=128; Arch="Ada"       },
  @{ Name="RTX 5060 (Desktop)"; CUDA=3584; SMclk=2600; Memclk=21000; Bus=192; Arch="Blackwell" }
)

$gpuScores = [ordered]@{}
foreach($r in $refs){
    $s = Score-FromSpecs $r
    $gpuScores[$s.Label] = [double]$s.Score
}

# Kullanıcı GPU bilgisi
$user = Get-UserGpuLabelAndScore
$userKey = if ($gpuScores.Contains($user.Label)) { "$($user.Label) • mine" } else { "$($user.Label) (My GPU)" }
$gpuScores[$userKey] = [double]$user.Score

# ---- Grafik çizimi + PNG kaydı ----
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Windows.Forms.DataVisualization
Add-Type -AssemblyName System.Drawing

$form = New-Object Windows.Forms.Form
$form.Text = "GPU Puanları Karşılaştırma (Normalize: RTX 5090 = 10000)"
$form.Width = 980
$form.Height = 620
$form.StartPosition = 'CenterScreen'

$chart = New-Object Windows.Forms.DataVisualization.Charting.Chart
$chart.Width = 940
$chart.Height = 520
$chart.Left = 10
$chart.Top  = 10

$area = New-Object Windows.Forms.DataVisualization.Charting.ChartArea "Main"
$area.AxisX.Interval = 1
$area.AxisX.Title = "GPU Modeli"
$area.AxisY.Title = "Skor (Normalize)"
$area.AxisY.MajorGrid.LineDashStyle = "Dash"
$area.AxisX.MajorGrid.Enabled = $false
$chart.ChartAreas.Add($area)

$series = New-Object Windows.Forms.DataVisualization.Charting.Series "Scores"
$series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Column
$series.IsValueShownAsLabel = $true
$series.LabelFormat = "F0"
$series.ChartArea = "Main"

foreach ($kvp in $gpuScores.GetEnumerator()) {
    $idx = $series.Points.AddXY([string]$kvp.Key, [double]$kvp.Value)
    $pt  = $series.Points[$idx]
    $pt.ToolTip = "$($kvp.Key): $([double]$kvp.Value)"
}

$chart.Series.Add($series)
[void]$chart.Titles.Add("GPU Puanları Karşılaştırma")

$form.Controls.Add($chart)

# PNG olarak masaüstüne kaydet
$desktop = [Environment]::GetFolderPath("Desktop")
$outfile = Join-Path $desktop ("GPU_Scores_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".png")
$chart.SaveImage($outfile, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output "PNG kaydedildi: $outfile"

try { [void]$form.ShowDialog() } catch { Write-Warning "Grafik penceresi açılamadı, ancak PNG dosyası kaydedildi: $outfile" }
sleep(3)
