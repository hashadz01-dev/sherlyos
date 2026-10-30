Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null

$asTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() |
  Where-Object {
    $_.Name -eq "AsTask" -and
    $_.IsGenericMethod -and
    $_.GetGenericArguments().Count -eq 1 -and
    $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq "IAsyncOperation`1"
  } |
  Select-Object -First 1

if (-not $asTaskGeneric) { throw "AsTask(IAsyncOperation) not found" }

function Await-WinRT($operation, [type]$resultType) {
  $asTask = $asTaskGeneric.MakeGenericMethod($resultType)
  $task = $asTask.Invoke($null, @($operation))
  $null = $task.Wait(-1)
  return $task.Result
}

function Get-ImageText([string]$path) {
  [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
  [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
  [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null

  $full = [System.IO.Path]::GetFullPath($path)
  $file = Await-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
  $stream = Await-WinRT ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await-WinRT ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap = Await-WinRT ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  $ocr = Await-WinRT ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
  return $ocr.Text
}

$outDir = Join-Path $PSScriptRoot "ocr"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Get-ChildItem (Join-Path $PSScriptRoot "source\*") -Include *.jpg,*.jpeg,*.png -File | ForEach-Object {
  if ($_.Name -like "sheet-d*") { return }
  Write-Output "OCR $($_.Name)..."
  $text = Get-ImageText $_.FullName
  $dest = Join-Path $outDir ($_.BaseName + ".txt")
  Set-Content -Path $dest -Value $text -Encoding UTF8
  Write-Output "Wrote $dest ($($text.Length) chars)"
}
