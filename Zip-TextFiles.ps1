#Requires -Version 5.1
<#
.SYNOPSIS
    Zips all text-based files listed in filelist.txt into a single zip,
    preserving the original folder structure.

.DESCRIPTION
    Reads a list of absolute Windows file paths (one per line), keeps only
    the ones whose extension is in the text-extension list (or whose name is
    a known dotfile like .htaccess), and adds them to a zip archive using
    their path relative to the drive root.

    Run on the Windows machine where E:\wwwroot actually exists:
        powershell -ExecutionPolicy Bypass -File .\Zip-TextFiles.ps1

.EXAMPLE
    .\Zip-TextFiles.ps1 -DryRun
    Preview what would be zipped (counts per extension) without creating anything.

.EXAMPLE
    .\Zip-TextFiles.ps1 -ZipPath D:\backup\wwwroot-text.zip -MaxSizeMB 10
#>
[CmdletBinding()]
param(
    [string]$FileList = (Join-Path $PSScriptRoot 'filelist.txt'),
    [string]$ZipPath  = (Join-Path $PSScriptRoot 'text-files.zip'),
    [long]  $MaxSizeMB = 0,          # 0 = no per-file size limit
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$TextExtensions = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    'php','js','mjs','cjs','ts','json','map','md','markdown','txt','log',
    'htm','html','css','scss','less','xml','svg','csv','sql','yml','yaml',
    'ini','conf','config','tpl','twig','pot','coffee','cmd','ps1','cshtml',
    'npmignore','eslintrc','jshintrc','editorconfig'
))

$DotFileNames = [System.Collections.Generic.HashSet[string]]::new([string[]]@(
    '.htaccess','.htpasswd','.gitignore','.gitattributes','.env','.babelrc',
    '.eslintrc','.jshintrc','.editorconfig','.stylelintrc','.prettierrc',
    '.npmignore','.browserslistrc'
))

$fileListFull = (Resolve-Path -LiteralPath $FileList).Path
$zipFull      = [IO.Path]::GetFullPath($ZipPath)
$maxBytes     = if ($MaxSizeMB -gt 0) { $MaxSizeMB * 1MB } else { [long]::MaxValue }

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression            -ErrorAction SilentlyContinue
} catch { }

$skipLog = Join-Path ([IO.Path]::GetDirectoryName($zipFull)) 'zip-skipped.log'
if (Test-Path -LiteralPath $skipLog) { Remove-Item -LiteralPath $skipLog }

$totalLines = [System.IO.File]::ReadAllLines($fileListFull).LongLength

$scanned = 0; $matched = 0; $added = 0; $skipped = 0
$byExt   = @{}

$zip = $null
try {
    if (-not $DryRun) {
        if (Test-Path -LiteralPath $zipFull) { Remove-Item -LiteralPath $zipFull }
        New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($zipFull)) | Out-Null
        $zip = [System.IO.Compression.ZipFile]::Open(
            $zipFull, [System.IO.Compression.ZipArchiveMode]::Create)
    }

    $reader = [System.IO.StreamReader]::new($fileListFull)
    try {
        while ($null -ne ($path = $reader.ReadLine())) {
            $scanned++
            $path = $path.Trim().Trim('"')
            if (-not $path) { continue }

            # normalize separators so parsing works on any OS
            $fwd     = $path.Replace('\', '/')
            $name    = [IO.Path]::GetFileName($fwd)
            $ext     = [IO.Path]::GetExtension($fwd).TrimStart('.').ToLowerInvariant()

            if (-not ($TextExtensions.Contains($ext) -or $DotFileNames.Contains($name.ToLowerInvariant()))) { continue }

            # never zip the file list itself or our own output
            if ($path -ieq $fileListFull -or $path -ieq $zipFull) { continue }

            $matched++
            $key = if ($ext) { ".$ext" } else { $name }
            $byExt[$key] = 1 + $byExt[$key]

            if ($DryRun) { continue }

            $fi = [IO.FileInfo]::new($path)
            if (-not $fi.Exists) {
                $skipped++
                "MISSING`t$path" | Out-File -FilePath $skipLog -Append -Encoding utf8
                continue
            }
            if ($fi.Length -gt $maxBytes) {
                $skipped++
                "TOO BIG`t$path`t$([math]::Round($fi.Length/1MB,2)) MB" | Out-File -FilePath $skipLog -Append -Encoding utf8
                continue
            }

            # entry name: path relative to drive root, forward slashes (zip convention)
            $entryName = ($path -replace '^[A-Za-z]:\\', '') -replace '\\', '/'
            try {
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $path, $entryName,
                    [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
                $added++
            } catch {
                $skipped++
                "LOCKED/ERROR`t$path`t$($_.Exception.Message)" | Out-File -FilePath $skipLog -Append -Encoding utf8
            }

            if ($added % 500 -eq 0) {
                Write-Progress -Activity 'Zipping text files' `
                    -Status "scanned $scanned / added $added / skipped $skipped" `
                    -PercentComplete ([math]::Min(100, [int](100 * $scanned / $totalLines)))
            }
        }
    } finally {
        $reader.Dispose()
    }
} finally {
    if ($zip) { $zip.Dispose() }
    Write-Progress -Activity 'Zipping text files' -Completed
}

if ($DryRun) {
    Write-Host "`nDRY RUN - $matched text-based entries found in list."
    $byExt.GetEnumerator() | Sort-Object Value -Descending | Format-Table Name, Value -AutoSize | Out-Host
} else {
    Write-Host "`nDone. Scanned $scanned entries | added $added files | skipped $skipped."
    Write-Host "Zip written to: $zipFull  ($([math]::Round((Get-Item -LiteralPath $zipFull).Length/1MB,1)) MB)"
    if ($skipped -gt 0) { Write-Host "See details in: $skipLog" }
}
