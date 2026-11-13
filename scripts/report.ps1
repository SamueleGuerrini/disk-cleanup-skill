<#
.SYNOPSIS
  Render an audit JSON file as a self-contained HTML report.

.DESCRIPTION
  The template has no external dependencies: no CDN, no fonts, no tracking. It
  works offline and from a file:// URL.

  audit.ps1 calls this automatically. Run it directly to re-render an older
  report or to render a checkpoint left by Ctrl+C.

.PARAMETER InputJson
  Report produced by audit.ps1 (schema 1).

.PARAMETER Path
  Destination HTML file. Default: the input path with .html

.PARAMETER Template
  Override the template. Default: lib\report.template.html

.EXAMPLE
  .\report.ps1 -InputJson "$env:LOCALAPPDATA\disk-cleanup\reports\audit-C-20260101-120000.json"
#>
[CmdletBinding()]
param(
  [string]$InputJson,
  [string]$Path,
  [string]$Template
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\common.ps1')

function Write-HtmlReport {
  param(
    $Report,
    [string]$Path,
    [string]$Template
  )

  if (-not $Template) { $Template = Join-Path $PSScriptRoot 'lib\report.template.html' }
  if (-not (Test-Path -LiteralPath $Template)) { throw "Report template not found: $Template" }

  $json = ConvertTo-Json -InputObject $Report -Depth 12 -Compress
  # A literal </script> inside the JSON payload would close the data block.
  $json = $json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')

  $html = Get-Content -LiteralPath $Template -Raw
  $title = 'Disk audit ' + [System.Net.WebUtility]::HtmlEncode([string]$Report.root)
  $html = $html.Replace('__TITLE__', $title)
  $html = $html.Replace('__DATA__', $json)

  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
  $tmp = "$Path.tmp.$([guid]::NewGuid().ToString('N'))"
  [System.IO.File]::WriteAllText($tmp, $html, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

if ($MyInvocation.InvocationName -ne '.') {
  if (-not (Test-Path -LiteralPath $InputJson)) { throw "Report JSON not found: $InputJson" }
  $report = ConvertFrom-JsonSafe (Get-Content -LiteralPath $InputJson -Raw)
  if (-not $Path) { $Path = [System.IO.Path]::ChangeExtension($InputJson, '.html') }
  $report | Add-Member -NotePropertyName tool -NotePropertyValue 'disk-cleanup' -Force
  Write-HtmlReport -Report $report -Path $Path -Template $Template
  Write-Host "HTML written: $Path" -ForegroundColor Green
  exit 0
}
