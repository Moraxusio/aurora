param(
    [string]$Source='C:\Users\finwe\AppData\Local\Temp\opencode\aurora-workbench-client\shots-final4',
    [string]$OutputName='contact-sheets-final4'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot $OutputName
New-Item -ItemType Directory -Path $out -Force | Out-Null
$files = @(Get-ChildItem -LiteralPath $source -Filter *.png | Sort-Object Name)
$font = [Drawing.Font]::new('Segoe UI', 10)
try {
    for ($start = 0; $start -lt $files.Count; $start += 6) {
        $canvas = [Drawing.Bitmap]::new(1500,1100)
        $g = [Drawing.Graphics]::FromImage($canvas)
        try {
            $g.Clear([Drawing.Color]::FromArgb(210,210,210))
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            for ($i = 0; $i -lt 6 -and $start + $i -lt $files.Count; $i++) {
                $file = $files[$start + $i]
                $image = [Drawing.Image]::FromFile($file.FullName)
                try {
                    $x = ($i % 3) * 500
                    $y = [math]::Floor($i / 3) * 550
                    $g.DrawString($file.BaseName,$font,[Drawing.Brushes]::Black,$x + 8,$y + 4)
                    $scale = [math]::Min(484.0/$image.Width,516.0/$image.Height)
                    $w = [int]($image.Width * $scale)
                    $h = [int]($image.Height * $scale)
                    $g.DrawImage($image,[Drawing.Rectangle]::new($x + 8, $y + 26,$w,$h))
                } finally { $image.Dispose() }
            }
            $name = 'sheet-{0:D2}.png' -f [int](1 + $start/6)
            $canvas.Save((Join-Path $out $name),[Drawing.Imaging.ImageFormat]::Png)
        } finally { $g.Dispose(); $canvas.Dispose() }
    }
} finally { $font.Dispose() }
Write-Output "Contact sheets: $($files.Count) screenshots in $out"
