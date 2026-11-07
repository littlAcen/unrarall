#Requires -Version 5.1
# unrarall.ps1 - Extract RAR / multi-volume archives with progress, password list and cleanup hooks.
# Version 0.6.0-acen-configured (ASCII only on purpose: safe for Windows PowerShell 5.1 without BOM)

param(
    [Parameter(Position=0)]
    [string]$Directory = ".",

    [ValidateSet('all','none','nfo','rar','osx_junk','windows_junk','covers_folders','proof_folders','sample_folders','sample_videos','empty_folders')]
    [string[]]$Clean = @('all'),

    [switch]$Force,
    [switch]$ShowProgress,
    [switch]$Quiet,
    [switch]$DisableCksfv,      # deprecated, ignored (SFV check was never implemented); kept for compatibility
    [string]$Output,
    [ValidateRange(0,20)]
    [int]$Depth = 4,
    [Alias('SearchDepth','MaxScanDepth')]
    [ValidateRange(-1,100)]
    [int]$ScanDepth = -1,       # folder levels below the start folder to search for archives (-1 = unlimited, 0 = start folder only)
    [switch]$SkipIfExists,
    [string]$PasswordFile = "C:\Users\JAMy\Documents\important_FileZ\unrar_passwords.txt",
    [switch]$SevenZip,
    [string]$SevenZipPath = "C:\Program Files\7-Zip\7z.exe",
    [ValidateSet('7z','unrar','rar')]
    [string]$Backend,
    [switch]$Dry,
    [switch]$AllowFailures,
    [switch]$FullPath,          # legacy: keeping folder structure is the default now
    [switch]$Flat,              # extract all files without folder structure
    [switch]$Help,
    [switch]$Version
)

$UNRARALL_VERSION = "0.6.0-acen-configured"

# ---- defaults for parameters that cannot default to $true in the param block ----
if (-not $PSBoundParameters.ContainsKey('ShowProgress')) { $ShowProgress = [switch](-not $Quiet) }
if ($Quiet) { $ShowProgress = [switch]$false }
if (-not $PSBoundParameters.ContainsKey('AllowFailures')) { $AllowFailures = [switch]$true }

# ---- script state ----
$script:Tool           = $null
$script:Count          = 0
$script:FailCount      = 0
$script:Found          = 0
$script:Skipped        = 0
$script:FilePasswords  = $null
$script:KnownPasswords = New-Object 'System.Collections.Generic.List[string]'
$script:Processed      = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:ProbePassword  = 'x-unrarall-probe-x'   # dummy so 7z never waits for a password prompt
$script:AllHooks       = @('nfo','rar','osx_junk','windows_junk','covers_folders','proof_folders','sample_folders','sample_videos','empty_folders')
$script:Hooks          = @()

function Show-Usage {
    $name = Split-Path -Leaf $PSCommandPath
    Write-Host @'
USAGE
  .\SCRIPT [-Directory] <dir> [-Clean <hook[,hook]>] [-Output <dir>] [-Depth <n>]
           [-ScanDepth <n>] [-Force] [-SkipIfExists] [-Flat] [-Dry] [-Quiet | -ShowProgress]
           [-Backend 7z|unrar|rar] [-SevenZip] [-SevenZipPath <path>]
           [-PasswordFile <file>] [-AllowFailures]
  .\SCRIPT -Help | -Version

DESCRIPTION
  Finds RAR archives (.rar, .partNN.rar, .001) recursively and extracts each one
  into a sub-folder named after the archive (or into -Output). Nested archives
  are extracted up to -Depth levels. Encrypted archives are opened with passwords
  from the password file; passwords that worked are tried first for later archives.

PRECONFIGURED DEFAULTS (Acen's setup)
  7-Zip path    C:\Program Files\7-Zip\7z.exe
  Password file C:\Users\acen\Documents\important_FileZ\unrar_passwords.txt
  Backend       7-Zip first, then unrar / rar (WinRAR)
  Clean         all
  Progress      on (use -Quiet to turn off)

OPTIONS
  -Directory <dir>     Directory to process (default: current directory)
  -Clean <hooks>       Hooks to run after a successful extraction (default: all)
  -Output <dir>        Extract into this directory instead of <archive folder>\<name>
  -Depth <n>           Maximum depth for nested archives, i.e. archives inside
                       extracted archives (default 4)
  -ScanDepth <n>       How many folder levels below <dir> are searched for archives
                       (default -1 = unlimited, 0 = only <dir> itself, 1 = <dir> and
                       its direct sub-folders). Aliases: -SearchDepth, -MaxScanDepth
  -Force               With -SkipIfExists: extract even if files already exist
  -SkipIfExists        Skip archives whose files already exist in the target
  -Flat                Extract without folder structure (name collisions get renamed)
  -Dry                 Dry run: show what would be extracted, change nothing
  -Quiet               No output (errors only via exit code)
  -ShowProgress        Show progress bars (default on)
  -Backend <b>         Force backend: 7z, unrar or rar
  -SevenZip            Force 7-Zip
  -AllowFailures       Exit 0 if at least one archive succeeded (default on;
                       use -AllowFailures:$false to exit 1 on any failure)
  -DisableCksfv        Deprecated, ignored
  -FullPath            Legacy, ignored (structure is kept by default)

CLEAN-UP HOOKS (content hooks only touch the extracted folder)
  nfo             Remove <name>.nfo next to the archive
  rar             Remove the archive volumes and <name>.sfv
  osx_junk        Remove .DS_Store and __MACOSX
  windows_junk    Remove Thumbs.db
  covers_folders  Remove Covers folders
  proof_folders   Remove Proof folders
  sample_folders  Remove Sample folders
  sample_videos   Remove small sample video files
  empty_folders   Remove empty folders
  all / none      All hooks / no hooks

EXAMPLES
  .\SCRIPT                               Extract everything below the current folder
  .\SCRIPT C:\Downloads -Clean rar,nfo   Only remove archives and nfo files
  .\SCRIPT C:\Downloads -Dry             Test run, nothing is changed
  .\SCRIPT C:\Downloads -ScanDepth 1     Only look in C:\Downloads and its direct sub-folders
'@.Replace('SCRIPT', $name)
    Write-Host ("`nVERSION: " + $UNRARALL_VERSION)
}

function Write-Message {
    param([string]$Type, [string]$Message)
    if ($Quiet) { return }
    switch ($Type) {
        'error' { Write-Host $Message -ForegroundColor Red }
        'warn'  { Write-Host $Message -ForegroundColor Yellow }
        'ok'    { Write-Host $Message -ForegroundColor Green }
        'nnl'   { Write-Host $Message -NoNewline }
        default { Write-Host $Message }
    }
}

# ------------------------------------------------------------------ native process helpers

function ConvertTo-NativeArgument {
    # Quotes one argument according to the Windows command-line rules (CommandLineToArgvW).
    param([string]$Arg)
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq [char]'\') {
            $bs++
        } elseif ($ch -eq [char]'"') {
            [void]$sb.Append([char]'\', ($bs * 2 + 1))
            [void]$sb.Append('"')
            $bs = 0
        } else {
            if ($bs -gt 0) { [void]$sb.Append([char]'\', $bs); $bs = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($bs -gt 0) { [void]$sb.Append([char]'\', ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-ProgressPercent {
    param([string]$Line)
    $m = [regex]::Match($Line, '^\s*(\d{1,3})%')
    if (-not $m.Success) { $m = [regex]::Match($Line, '\s(\d{1,3})%\s*$') }
    if ($m.Success) {
        $v = [int]$m.Groups[1].Value
        if ($v -le 100) { return $v }
    }
    return -1
}

function Invoke-Native {
    # Runs a program, returns @{ ExitCode; Lines }. Shows a progress bar when -Activity is given.
    # stdin is closed immediately so a password prompt can never hang the script.
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Activity,
        [switch]$CaptureAll,
        [switch]$Utf8
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $FilePath
    $psi.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    if ($Utf8) {
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $proc  = [System.Diagnostics.Process]::Start($psi)
    $exit  = -1
    try {
        $proc.StandardInput.Close()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $reader  = $proc.StandardOutput

        if ($Activity) {
            # character-wise reading, because progress is rewritten with carriage returns
            $sb = New-Object System.Text.StringBuilder
            $lastPct = -1
            while ($true) {
                $c = $reader.Read()
                if ($c -lt 0) { break }
                $ch = [char]$c
                if ($ch -ne "`r" -and $ch -ne "`n") { [void]$sb.Append($ch); continue }
                if ($sb.Length -eq 0) { continue }
                $line = $sb.ToString().Replace([string][char]8, '').TrimEnd()
                [void]$sb.Clear()
                $pct = Get-ProgressPercent $line
                if ($pct -ge 0) {
                    if ($pct -ne $lastPct) {
                        $lastPct = $pct
                        Write-Progress -Id 20 -Activity $Activity -Status ("{0} %" -f $pct) -PercentComplete $pct
                    }
                    continue
                }
                if ($line) {
                    $lines.Add($line)
                    if (-not $CaptureAll -and $lines.Count -gt 15) { $lines.RemoveAt(0) }
                }
            }
            if ($sb.Length -gt 0) {
                $rest = $sb.ToString().Replace([string][char]8, '').TrimEnd()
                if ($rest -and (Get-ProgressPercent $rest) -lt 0) { $lines.Add($rest) }
            }
        } else {
            $text = $reader.ReadToEnd()
            foreach ($l in ($text -split "\r?\n")) {
                if ($l.Trim() -ne '') { $lines.Add($l.TrimEnd()) }
            }
        }

        $proc.WaitForExit()
        $exit = $proc.ExitCode
        $err = $errTask.Result
        if ($err) {
            foreach ($l in ($err -split "\r?\n")) {
                if ($l.Trim() -ne '') { $lines.Add($l.TrimEnd()) }
            }
        }
    } finally {
        if (-not $proc.HasExited) { try { $proc.Kill() } catch {} }
        $proc.Dispose()
        if ($Activity) { Write-Progress -Id 20 -Activity $Activity -Completed }
    }
    return [pscustomobject]@{ ExitCode = $exit; Lines = $lines }
}

function Get-TreeEntries {
    # Iterative directory walk (no recursion, no stack overflow). Skips junctions/symlinks to avoid loops.
    # Returns files, or directories with -Directories. Unreadable folders are skipped silently.
    # -MaxDepth: levels below $Root to enter (-1 = unlimited, 0 = only $Root itself).
    param([string]$Root, [switch]$Directories, [int]$MaxDepth = -1)
    $stack  = New-Object 'System.Collections.Generic.Stack[string]'
    $depths = New-Object 'System.Collections.Generic.Stack[int]'
    $out    = New-Object 'System.Collections.Generic.List[System.IO.FileSystemInfo]'
    $stack.Push($Root)
    $depths.Push(0)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $level = $depths.Pop()
        try { $children = (New-Object System.IO.DirectoryInfo $dir).GetFileSystemInfos() } catch { continue }
        foreach ($c in $children) {
            if ($c -is [System.IO.DirectoryInfo]) {
                if (($c.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($MaxDepth -ge 0 -and $level -ge $MaxDepth) { continue }
                if ($Directories) { $out.Add($c) }
                $stack.Push($c.FullName)
                $depths.Push($level + 1)
            } elseif (-not $Directories) {
                $out.Add($c)
            }
        }
    }
    return $out.ToArray()
}

function Get-LastLines {
    param($Lines)
    $t = @($Lines | Where-Object { $_ } | Select-Object -Last 3)
    return ($t -join ' | ')
}

# ------------------------------------------------------------------ backend discovery

function Find-Binary {
    param([string]$Name)   # '7z', 'unrar' or 'rar'

    if ($Name -eq '7z' -and $SevenZipPath -and (Test-Path -LiteralPath $SevenZipPath -PathType Leaf)) {
        return $SevenZipPath
    }

    $cmd = Get-Command ($Name + '.exe') -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }

    $folder = if ($Name -eq '7z') { '7-Zip' } else { 'WinRAR' }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        $p = Join-Path $base ($folder + '\' + $Name + '.exe')
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    $choco = 'C:\ProgramData\chocolatey\bin\' + $Name + '.exe'
    if (Test-Path -LiteralPath $choco -PathType Leaf) { return $choco }
    return $null
}

# ------------------------------------------------------------------ passwords

function Get-PasswordCandidates {
    if ($null -eq $script:FilePasswords) {
        $script:FilePasswords = @()
        if ($PasswordFile -and (Test-Path -LiteralPath $PasswordFile -PathType Leaf)) {
            $script:FilePasswords = @(
                Get-Content -LiteralPath $PasswordFile -Encoding UTF8 |
                    Where-Object { $_.Trim() -ne '' -and -not $_.StartsWith('#') }
            )
        } else {
            Write-Message 'warn' ("Password file not found: " + $PasswordFile)
        }
    }
    # passwords that already worked go first
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in (@($script:KnownPasswords) + @($script:FilePasswords))) {
        if ($seen.Add([string]$p)) { $list.Add([string]$p) }
    }
    return $list
}

function Add-KnownPassword {
    param([string]$Password)
    if (-not $script:KnownPasswords.Contains($Password)) { $script:KnownPasswords.Add($Password) }
}

function Get-SevenZipInfo {
    # Lists an archive with 7-Zip (technical format) and returns what we need to know.
    param([string]$ArchivePath, [string]$Password)

    $pw = if ($Password) { $Password } else { $script:ProbePassword }
    $r = Invoke-Native -FilePath $script:Tool.Path `
        -ArgumentList @('l', '-slt', '-sccUTF-8', ('-p' + $pw), '--', $ArchivePath) -CaptureAll -Utf8

    $info = [pscustomobject]@{
        Listed          = $false
        HeaderEncrypted = $false
        HasEncrypted    = $false
        Smallest        = $null
        SmallestSize    = -1
        Paths           = (New-Object 'System.Collections.Generic.List[string]')
        Output          = $r.Lines
        ExitCode        = $r.ExitCode
    }

    $marker = $r.Lines.IndexOf('----------')
    if ($r.ExitCode -le 1 -and $marker -ge 0) {
        $info.Listed = $true
    } elseif (($r.Lines -join "`n") -match 'Wrong password|(Can not|Cannot) open encrypted archive|Enter password') {
        $info.HeaderEncrypted = $true
    }
    if (-not $info.Listed) { return $info }

    # blank lines are dropped by Invoke-Native, so a new record starts at every 'Path =' key
    $records = New-Object 'System.Collections.Generic.List[hashtable]'
    $cur = $null
    for ($i = $marker + 1; $i -lt $r.Lines.Count; $i++) {
        $line = $r.Lines[$i]
        $idx = $line.IndexOf(' = ')
        if ($idx -le 0) { continue }
        $key = $line.Substring(0, $idx)
        if ($key -eq 'Path') {
            if ($null -ne $cur) { $records.Add($cur) }
            $cur = @{}
        }
        if ($null -ne $cur) { $cur[$key] = $line.Substring($idx + 3) }
    }
    if ($null -ne $cur) { $records.Add($cur) }

    foreach ($rec in $records) {
        if ($rec['Folder'] -eq '+') { continue }
        $info.Paths.Add([string]$rec['Path'])
        if ($rec['Encrypted'] -eq '+') {
            $info.HasEncrypted = $true
            $size = [long]0
            [void][long]::TryParse([string]$rec['Size'], [ref]$size)
            # remember the smallest non-empty encrypted file: cheapest way to test a password
            if ($null -eq $info.Smallest -or ($size -gt 0 -and ($info.SmallestSize -le 0 -or $size -lt $info.SmallestSize))) {
                $info.Smallest = [string]$rec['Path']
                $info.SmallestSize = $size
            }
        }
    }
    return $info
}

function Resolve-ArchivePassword {
    # Returns @{ Encrypted; Password; FromList }. Throws if the archive cannot be opened.
    param([string]$ArchivePath)

    if ($script:Tool.Kind -eq '7z') {
        $probe = Get-SevenZipInfo $ArchivePath
        if ($probe.Listed -and -not $probe.HasEncrypted) {
            return [pscustomobject]@{ Encrypted = $false; Password = $null; FromList = $false }
        }
        if (-not $probe.Listed -and -not $probe.HeaderEncrypted) {
            throw ("Cannot read archive: " + (Get-LastLines $probe.Output))
        }

        $candidates = @(Get-PasswordCandidates)
        if ($candidates.Count -eq 0) { throw "Archive is encrypted and no passwords are available" }

        foreach ($pw in $candidates) {
            $info = if ($probe.Listed) { $probe } else { Get-SevenZipInfo $ArchivePath $pw }
            if (-not $info.Listed) { continue }
            if (-not $info.HasEncrypted -or -not $info.Smallest) {
                Add-KnownPassword $pw
                return [pscustomobject]@{ Encrypted = $true; Password = $pw; FromList = $true }
            }
            $t = Invoke-Native -FilePath $script:Tool.Path `
                -ArgumentList @('t', ('-p' + $pw), '-sccUTF-8', '-bso0', '-bse1', '-bsp0', '--', $ArchivePath, $info.Smallest) -Utf8
            if ($t.ExitCode -le 1) {
                Add-KnownPassword $pw
                return [pscustomobject]@{ Encrypted = $true; Password = $pw; FromList = $true }
            }
        }
        throw ("No working password found (tried " + $candidates.Count + ")")
    }
    else {
        $probe = Invoke-Native -FilePath $script:Tool.Path -ArgumentList @('l', '-p-', '-y', '--', $ArchivePath) -CaptureAll
        $text = $probe.Lines -join "`n"
        $encrypted = ($probe.Lines | Where-Object { $_ -match '^\s*\*' }).Count -gt 0 -or $text -match 'encrypted|password'
        if (-not $encrypted) {
            if ($probe.ExitCode -ne 0) { throw ("Cannot read archive: " + (Get-LastLines $probe.Lines)) }
            return [pscustomobject]@{ Encrypted = $false; Password = $null; FromList = $false }
        }

        $candidates = @(Get-PasswordCandidates)
        if ($candidates.Count -eq 0) { throw "Archive is encrypted and no passwords are available" }
        foreach ($pw in $candidates) {
            $t = Invoke-Native -FilePath $script:Tool.Path -ArgumentList @('t', '-y', '-idq', ('-p' + $pw), '--', $ArchivePath)
            if ($t.ExitCode -eq 0) {
                Add-KnownPassword $pw
                return [pscustomobject]@{ Encrypted = $true; Password = $pw; FromList = $true }
            }
        }
        throw ("No working password found (tried " + $candidates.Count + ")")
    }
}

# ------------------------------------------------------------------ extraction

function Test-AlreadyExtracted {
    param([string]$ArchivePath, [string]$TargetDir)
    try {
        $paths = @()
        if ($script:Tool.Kind -eq '7z') {
            $info = Get-SevenZipInfo $ArchivePath
            if (-not $info.Listed) { return $false }
            $paths = @($info.Paths)
        } else {
            $r = Invoke-Native -FilePath $script:Tool.Path -ArgumentList @('lb', '-p-', '--', $ArchivePath) -CaptureAll
            if ($r.ExitCode -ne 0) { return $false }
            $paths = @($r.Lines | Where-Object { $_ })
        }
        if ($paths.Count -eq 0) { return $false }
        foreach ($p in $paths) {
            $rel = if ($Flat) { Split-Path -Leaf $p } else { $p }
            if (-not (Test-Path -LiteralPath (Join-Path $TargetDir $rel))) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Invoke-Extract {
    param([string]$ArchivePath, [string]$TargetDir, [string]$Password, [string]$Activity)

    $act = if ($ShowProgress) { $Activity } else { $null }
    $cmd = if ($Flat) { 'e' } else { 'x' }
    $target = $TargetDir.TrimEnd('\', '/')

    if ($script:Tool.Kind -eq '7z') {
        $a = @($cmd, '-y', '-sccUTF-8', ('-o' + $target))
        if ($Flat) { $a += '-aou' }                       # rename on name collisions instead of overwriting
        if ($Password) { $a += ('-p' + $Password) }
        $a += '-bso0'
        $a += '-bse1'                                     # errors to stdout so we can show them
        $a += $(if ($act) { '-bsp1' } else { '-bsp0' })
        $a += '--'
        $a += $ArchivePath
        return Invoke-Native -FilePath $script:Tool.Path -ArgumentList $a -Activity $act -Utf8
    } else {
        $a = @($cmd, '-y', '-o+')
        $a += $(if ($Password) { '-p' + $Password } else { '-p-' })
        if (-not $act) { $a += '-idq' }
        $a += '--'
        $a += $ArchivePath
        $a += ($target + '/')                             # unrar needs a trailing separator; '/' avoids the \" quoting trap
        return Invoke-Native -FilePath $script:Tool.Path -ArgumentList $a -Activity $act
    }
}

function Get-ExtractError {
    param($Result)
    $code = $Result.ExitCode
    if ($script:Tool.Kind -eq '7z') {
        $msg = switch ($code) {
            2   { 'Fatal error (corrupt or missing volume, wrong password or write error)' }
            7   { 'Command line error' }
            8   { 'Not enough memory' }
            255 { 'Stopped by user' }
            default { "Extraction failed with exit code $code" }
        }
    } else {
        $msg = switch ($code) {
            2   { 'Fatal error in archive' }
            3   { 'CRC error - archive might be corrupted' }
            4   { 'Attempt to modify a locked archive' }
            5   { 'Write error' }
            6   { 'Open error' }
            7   { 'User error (wrong command)' }
            8   { 'Not enough memory' }
            9   { 'File create error' }
            10  { 'No files matching pattern' }
            11  { 'Wrong password' }
            255 { 'User break' }
            default { "Extraction failed with exit code $code" }
        }
    }
    $detail = Get-LastLines $Result.Lines
    if ($detail) { return "$msg [$detail]" }
    return $msg
}

# ------------------------------------------------------------------ clean-up hooks

function Remove-JunkItem {
    param([string]$Path, [string]$Hook)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ($Dry) { Write-Message 'info' ("[DRY] hook " + $Hook + ": would remove " + $Path); return }
    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        if ($ShowProgress) { Write-Message 'info' ("  [" + $Hook + "] removed: " + $Path) }
    } catch {
        Write-Message 'warn' ("  [" + $Hook + "] could not remove " + $Path + ": " + $_.Exception.Message)
    }
}

function Remove-NamedFolders {
    param([string]$Root, [string]$FolderName, [string]$Hook)
    $dirs = @(Get-TreeEntries $Root -Directories | Where-Object { $_.Name -ieq $FolderName })
    foreach ($d in $dirs) { Remove-JunkItem $d.FullName $Hook }
}

function Invoke-CleanHook {
    # Archive hooks (nfo, rar) work next to the archive; content hooks only inside the extracted folder.
    param([string]$Hook, [string]$BaseName, [string]$ArchiveDir, [string]$TargetDir)

    switch ($Hook) {
        'nfo' {
            Remove-JunkItem (Join-Path $ArchiveDir ($BaseName + '.nfo')) $Hook
        }
        'rar' {
            # only volumes/sfv of THIS release (zip/7z files with the same name are NOT touched)
            $pattern = '^' + [regex]::Escape($BaseName) + '\.(sfv|rar|r[0-9]{2}|[0-9]{3}|part[0-9]+\.rar)$'
            $files = @(Get-ChildItem -LiteralPath $ArchiveDir -File -Force -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match $pattern })
            foreach ($f in $files) { Remove-JunkItem $f.FullName $Hook }
        }
        'osx_junk' {
            $items = @(Get-TreeEntries $TargetDir | Where-Object { $_.Name -ieq '.DS_Store' })
            $items += @(Get-TreeEntries $TargetDir -Directories | Where-Object { $_.Name -ieq '__MACOSX' })
            foreach ($i in $items) { Remove-JunkItem $i.FullName $Hook }
        }
        'windows_junk' {
            $items = @(Get-TreeEntries $TargetDir | Where-Object { $_.Name -ieq 'Thumbs.db' })
            foreach ($i in $items) { Remove-JunkItem $i.FullName $Hook }
        }
        'covers_folders' { Remove-NamedFolders $TargetDir 'Covers' $Hook }
        'proof_folders'  { Remove-NamedFolders $TargetDir 'Proof'  $Hook }
        'sample_folders' { Remove-NamedFolders $TargetDir 'Sample' $Hook }
        'sample_videos' {
            $videoExt = @('.asf','.avi','.mkv','.mp4','.m4v','.mov','.mpg','.mpeg','.ogg','.ogv','.webm','.wmv')
            # name must contain "sample" as a separate word, and the file must be small (< 250 MB)
            $items = @(Get-TreeEntries $TargetDir |
                       Where-Object {
                           $videoExt -contains $_.Extension.ToLower() -and
                           $_.Length -lt 250MB -and
                           $_.Name -match '(?i)(^|[-._ ])sample([-._ ]|\.[^.]+$)'
                       })
            foreach ($i in $items) { Remove-JunkItem $i.FullName $Hook }
        }
        'empty_folders' {
            $dirs = @(Get-TreeEntries $TargetDir -Directories |
                      Sort-Object { $_.FullName.Length } -Descending)
            foreach ($d in $dirs) {
                if (-not (Test-Path -LiteralPath $d.FullName)) { continue }
                $has = Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $has) { Remove-JunkItem $d.FullName $Hook }
            }
        }
    }
}

# ------------------------------------------------------------------ main work

function Get-ArchiveStarts {
    # First volumes only: *.rar (not .partNN.rar with NN > 1) and *.001
    param([string]$Path)
    $result = New-Object 'System.Collections.Generic.List[object]'
    $files = @(Get-TreeEntries $Path -MaxDepth $ScanDepth |
               Where-Object { $_.Extension -in @('.rar', '.001') } |
               Sort-Object FullName)
    foreach ($f in $files) {
        $m = [regex]::Match($f.Name, '(?i)^(?<base>.+)\.part(?<n>\d+)\.rar$')
        if ($m.Success) {
            if ([int]$m.Groups['n'].Value -ne 1) { continue }
            $base = $m.Groups['base'].Value
        } else {
            $base = $f.BaseName
        }
        $result.Add([pscustomobject]@{ File = $f; BaseName = $base })
    }
    return $result
}

function Invoke-ArchiveDirectory {
    param([string]$Path, [int]$RemainingDepth, [int]$Level = 0)

    if ($ShowProgress) { Write-Message 'info' ("Scanning: " + $Path) }

    $archives = @(Get-ArchiveStarts $Path)
    $total = $archives.Count
    $i = 0

    foreach ($item in $archives) {
        $i++
        $file = $item.File
        $base = $item.BaseName

        if (-not $script:Processed.Add($file.FullName)) { continue }   # never handle an archive twice
        $script:Found++

        $targetDir = if ($Output) { $Output } else { Join-Path $file.DirectoryName $base }
        $label = ("[{0}/{1}] {2}" -f $i, $total, $file.Name)

        if ($ShowProgress -and $total -gt 0) {
            $pp = @{ Id = (10 + $Level); Activity = ("Archives (level " + $Level + ")"); Status = $label;
                     PercentComplete = [int](($i - 1) / $total * 100) }
            if ($Level -gt 0) { $pp['ParentId'] = (9 + $Level) }
            Write-Progress @pp
        }

        if ($SkipIfExists -and -not $Force -and (Test-AlreadyExtracted $file.FullName $targetDir)) {
            $script:Skipped++
            Write-Message 'ok' ("Already extracted: " + $file.Name)
            continue
        }

        if ($Dry) {
            Write-Message 'info' ("[DRY] " + $label + " -> " + $targetDir)
            continue
        }

        Write-Message 'nnl' ($label + " ... ")
        $ok = $false
        $createdDir = $false
        try {
            if (-not (Test-Path -LiteralPath $targetDir)) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                $createdDir = $true
            }
            $pw = Resolve-ArchivePassword $file.FullName
            $r = Invoke-Extract $file.FullName $targetDir $pw.Password $label
            if ($r.ExitCode -gt 1) { throw (Get-ExtractError $r) }

            if ($r.ExitCode -eq 1)  { Write-Message 'warn' 'OK (with warnings)' }
            elseif ($pw.FromList)   { Write-Message 'ok' 'OK (password from list)' }
            else                    { Write-Message 'ok' 'OK' }
            $ok = $true
        } catch {
            Write-Message 'error' ("FAILED: " + $_.Exception.Message)
            $script:FailCount++
            if ($createdDir -and -not (Get-ChildItem -LiteralPath $targetDir -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $targetDir -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $ok) { continue }
        $script:Count++

        # nested archives
        if ($RemainingDepth -gt 0) {
            $nested = @(Get-ArchiveStarts $targetDir)
            if ($nested.Count -gt 0) {
                if ($ShowProgress) { Write-Message 'info' ("Nested archives found in " + $file.Name + ", extracting") }
                Invoke-ArchiveDirectory $targetDir ($RemainingDepth - 1) ($Level + 1)
            }
        }

        # clean-up hooks
        foreach ($hook in $script:Hooks) {
            try { Invoke-CleanHook $hook $base $file.DirectoryName $targetDir }
            catch { Write-Message 'warn' ("Hook " + $hook + " failed: " + $_.Exception.Message) }
        }
    }

    if ($ShowProgress) { Write-Progress -Id (10 + $Level) -Activity 'Archives' -Completed }
}

# ------------------------------------------------------------------ entry point

if ($Help)    { Show-Usage; exit 0 }
if ($Version) { Write-Host $UNRARALL_VERSION; exit 0 }

# backend
$order = if ($Backend) { @($Backend) } elseif ($SevenZip) { @('7z') } else { @('7z', 'unrar', 'rar') }
foreach ($n in $order) {
    $p = Find-Binary $n
    if ($p) {
        $script:Tool = [pscustomobject]@{ Path = $p; Kind = $(if ($n -eq '7z') { '7z' } else { 'rar' }) }
        break
    }
}
if (-not $script:Tool) {
    Write-Message 'error' "No extraction tool found. Please install 7-Zip (7z.exe) or WinRAR (unrar.exe / rar.exe),"
    Write-Message 'error' "or point -SevenZipPath / -Backend to it."
    exit 1
}

# hooks (run in a fixed, sensible order regardless of how they were typed)
if ($Clean -contains 'none') { $script:Hooks = @() }
elseif ($Clean -contains 'all') { $script:Hooks = $script:AllHooks }
else { $script:Hooks = @($script:AllHooks | Where-Object { $Clean -contains $_ }) }

# paths
if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    Write-Message 'error' ("Directory not found: " + $Directory)
    exit 1
}
$Directory = (Resolve-Path -LiteralPath $Directory).Path
if ($Output) {
    $Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
}

if ($ShowProgress) {
    Write-Message 'info' ("Using " + $script:Tool.Path + " for extraction")
    Write-Message 'info' ("Scan depth: " + $(if ($ScanDepth -lt 0) { 'unlimited' } else { $ScanDepth }) + ", nested archive depth: " + $Depth)
    if ($script:Hooks.Count -gt 0) { Write-Message 'info' ("Clean-up hooks: " + ($script:Hooks -join ', ')) }
}

Invoke-ArchiveDirectory $Directory $Depth 0

# summary
if ($Dry) {
    Write-Message 'info' ("Dry run finished: {0} archive(s) would be processed" -f $script:Found)
    exit 0
}

if ($script:Count -gt 0) {
    $phrase = 'found and extracted'
    if ($script:Hooks.Count -gt 0) {
        $phrase = 'found, extracted and cleaned using: ' + ($script:Hooks -join ', ')
    }
    Write-Message 'info' ("{0} archive(s) {1}" -f $script:Count, $phrase)
} elseif ($script:Found -eq 0) {
    Write-Message 'warn' 'No archives found'
} elseif ($script:Skipped -gt 0 -and $script:FailCount -eq 0) {
    Write-Message 'info' ("Nothing to do: {0} archive(s) already extracted" -f $script:Skipped)
}

if ($script:FailCount -gt 0) {
    Write-Message 'error' ("{0} failure(s)" -f $script:FailCount)
    if (-not $AllowFailures -or $script:Count -eq 0) { exit 1 }
}
exit 0
