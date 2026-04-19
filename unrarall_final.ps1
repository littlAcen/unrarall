# unrarall.ps1 - Mit Fortschrittsanzeige
param(
    [Parameter(Position=0)]
    [string]$Directory = ".",

    [string[]]$Clean,
    [switch]$Force,
    [switch]$ShowProgress,
    [switch]$Quiet,
    [switch]$DisableCksfv,
    [string]$Output,
    [int]$Depth = 4,
    [switch]$SkipIfExists,
    [string]$PasswordFile = "C:\Users\acen\Documents\important_FileZ\unrar_passwords.txt",
    [switch]$SevenZip,
    [string]$SevenZipPath = "C:\Program Files\7-Zip\7z.exe",
    [string]$Backend,
    [switch]$Dry,
    [switch]$AllowFailures,
    [switch]$FullPath,
    [switch]$Help,
    [switch]$Version
)

# Set some defaults
$UNRARALL_VERSION = "0.5.0-acen-configured"
$UNRARALL_EXECUTABLE_NAME = $MyInvocation.MyCommand.Name
$UNRARALL_PID = $PID
$CKSFV = 0
$UNRAR_METHOD = if ($FullPath) { "x" } else { "e" }
$MV_BACKUP = $true

# Apply default values if parameters weren't explicitly provided
if (-not $PSBoundParameters.ContainsKey('Clean')) {
    $Clean = @("all")
}
if (-not $PSBoundParameters.ContainsKey('ShowProgress')) {
    $ShowProgress = $true
}
if (-not $PSBoundParameters.ContainsKey('DisableCksfv')) {
    $DisableCksfv = $true
}
if (-not $PSBoundParameters.ContainsKey('AllowFailures')) {
    $AllowFailures = $true
}

# Clean up hooks
$script:UNRARALL_DETECTED_CLEAN_UP_HOOKS = @()
$script:UNRARALL_CLEAN_UP_HOOKS_TO_RUN = @("all")
$UNRAR_BINARIES = @("7z.exe", "7z", "unrar.exe", "rar.exe")
$script:UNRARALL_BIN = ""
$script:COUNT = 0
$script:FAIL_COUNT = 0

# Password file - use configured default
$script:UNRARALL_PASSWORD_FILE = $PasswordFile

# Password caching - remember working passwords
$script:PASSWORD_CACHE = @{}
$script:PASSWORD_TEST_COUNT = 0
$script:MAX_PASSWORD_TESTS = 3  # Only test passwords on first 3 files

function Show-Usage {
    Write-Host @"
Usage: $UNRARALL_EXECUTABLE_NAME [-Directory <DIRECTORY>] [--Clean <hook[,hook]>] [--Force]
       [--ShowProgress | --Quiet] [--SevenZip] [--Dry] [--DisableCksfv] [--PasswordFile <file>]
       [--Output <DIRECTORY>] [--Depth <amt>] [--SkipIfExists]
       $UNRARALL_EXECUTABLE_NAME --Help
       $UNRARALL_EXECUTABLE_NAME --Version

DESCRIPTION
$UNRARALL_EXECUTABLE_NAME is a utility to unrar and clean up various files
(.e.g. rar files). Sub-directories are automatically recursed and if a rar file
exists in a sub-directory then the rar file is extracted into that subdirectory.

PRECONFIGURED DEFAULTS (Acen's Setup):
- 7-Zip Path:    C:\Program Files\7-Zip\7z.exe
- Password File: C:\Users\acen\Documents\important_FileZ\unrar_passwords.txt
- Backend:       7-Zip (preferred for all archive types)
- Progress:      Enabled by default

OPTIONS

-Directory <DIRECTORY>    Directory to process (default: current directory)
-Clean <hook[,hook]>      Clean up hooks to execute
-Force                    Force unrar even if sfv check failed
-ShowProgress             Show extraction progress (including % progress bar)
-Quiet                    Be completely quiet
-SevenZip                 Force using 7zip (default behavior)
-Dry                      Dry run, no action performed
-DisableCksfv             Disable CRC checking
-PasswordFile <file>      Path to password file (default: C:\Users\acen\Documents\important_FileZ\unrar_passwords.txt)
-SevenZipPath <path>      Path to 7z.exe (default: C:\Program Files\7-Zip\7z.exe)
-Output <DIRECTORY>       Directory to extract files
-Depth <amt>              Maximum depth for nested extraction (default: 4)
-SkipIfExists             Skip extraction if files already exist
-Backend <backend>        Force backend (unrar, rar, or 7z)
-AllowFailures            Ignore errors if any successful extractions
-FullPath                 Extract with full path
-Help                     Show this help
-Version                  Show version

CLEAN UP HOOKS:
- nfo: Removes .nfo files with the same name as the .rar file
- rar: Removes rar files and sfv files
- osx_junk: Removes junk OSX files (.DS_Store)
- windows_junk: Removes junk Windows files (Thumbs.db)
- covers_folders: Removes Covers folders
- proof_folders: Removes Proof folders
- sample_folders: Removes Sample folders
- sample_videos: Removes sample video files matching the release
- empty_folders: Removes empty folders
- all: Execute all the above hooks
- none: Do not execute any clean up hooks

EXAMPLES:
  $UNRARALL_EXECUTABLE_NAME                          # Extract all in current directory
  $UNRARALL_EXECUTABLE_NAME -Directory C:\Downloads  # Extract from specific folder
  $UNRARALL_EXECUTABLE_NAME -Clean all               # Extract and cleanup everything
  $UNRARALL_EXECUTABLE_NAME -Quiet -Clean rar        # Silent mode, only remove rar files
  $UNRARALL_EXECUTABLE_NAME -Dry                     # Test run (no changes)

VERSION: $UNRARALL_VERSION
"@
}

function Write-Message {
    param(
        [string]$Type,
        [string]$Message
    )

    if ($Quiet) { return }

    switch ($Type) {
        "error" { Write-Host $Message -ForegroundColor Red }
        "ok"    { Write-Host $Message -ForegroundColor Green }
        "info"  { Write-Host $Message }
        "nnl"   { Write-Host $Message -NoNewline }
        default { Write-Host $Message }
    }
}

function Show-ExtractionProgress {
    param(
        [string]$OutputLine
    )

    if (-not $ShowProgress) { return }

    if ($OutputLine -match "(\d{1,3})%") {
        $percent = $matches[1]
        Write-Host ("`rExtracting... {0}% complete" -f $percent) -NoNewline
    }
    elseif ($OutputLine -match "^\s*Extracting\s+") {
        Write-Host ("`r{0}" -f $OutputLine) -NoNewline
    }
    elseif ($OutputLine -match "OK") {
        Write-Host "`rExtracting... 100% complete" -NoNewline
    }
}

function Get-UnrarFlags {
    param([string]$Binary)

    $binaryName = [System.IO.Path]::GetFileNameWithoutExtension($Binary)

    switch ($binaryName) {
        { $_ -in @("unrar", "rar") } {
            if ($ShowProgress) {
                return "-o+"
            } else {
                return "-o+ -idq"
            }
        }
        "7z" {
            if ($ShowProgress) {
                return ""
            } else {
                return "-bd"
            }
        }
        default {
            Write-Message "error" ("Unsupported program: " + $Binary)
            exit 1
        }
    }
}

function Is-AlreadyExtracted {
    param(
        [string]$Binary,
        [string]$ArchivePath
    )

    if ($Binary -eq "echo") { return $false }

    try {
        $binaryName = [System.IO.Path]::GetFileNameWithoutExtension($Binary)

        if ($binaryName -in @("unrar", "rar")) {
            $files = & $Binary lb $ArchivePath
        } elseif ($binaryName -eq "7z") {
            $output = & $Binary L -ba -slt $ArchivePath
            $files = $output | Where-Object { $_ -match "^Path =" } |
                     ForEach-Object { $_ -replace "^Path =\s*", "" }
        }

        foreach ($file in $files) {
            if (-not (Test-Path $file)) {
                return $false
            }
        }
        return $true
    } catch {
        if ($ShowProgress) {
            Write-Message "info" ("Unable to check if already extracted: " + $_.Exception.Message)
        }
        return $false
    }
}

function Is-RarEncrypted {
    param(
        [string]$Binary,
        [string]$ArchivePath
    )

    try {
        $binaryName = [System.IO.Path]::GetFileNameWithoutExtension($Binary)

        if ($binaryName -in @("unrar", "rar")) {
            $output = & $Binary l -p- $ArchivePath
            if ($output -match "^\*" -or $output -match "encrypted headers") {
                return $true
            }
        } elseif ($binaryName -eq "7z") {
            $output = & $Binary l -slt -p- $ArchivePath
            if ($output -match "^Encrypted = \+$" -or $output -match "Can not open encrypted archive") {
                return $true
            }
        }
        return $false
    } catch {
        if ($ShowProgress) {
            Write-Message "info" ("Error checking encryption: " + $_.Exception.Message)
        }
        return $false
    }
}

function Find-WindowsBinary {
    param([string]$BinaryName)

    # For 7-Zip, check configured path first
    if ($BinaryName -match "7z" -and $SevenZipPath -and (Test-Path $SevenZipPath)) {
        return $SevenZipPath
    }

    try {
        $cmd = Get-Command $BinaryName -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    } catch {}

    if ($BinaryName -like "*.exe") {
        $nameWithoutExe = $BinaryName -replace '\.exe$', ''
        try {
            $cmd = Get-Command $nameWithoutExe -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
        } catch {}
    }

    $commonPaths = @()
    switch -Wildcard ($BinaryName) {
        "*unrar*" {
            $commonPaths = @(
                "C:\Program Files\WinRAR\unrar.exe",
                "C:\Program Files (x86)\WinRAR\unrar.exe",
                "$env:ProgramFiles\WinRAR\unrar.exe",
                "${env:ProgramFiles(x86)}\WinRAR\unrar.exe",
                "C:\ProgramData\chocolatey\bin\unrar.exe"
            )
        }
        "*rar*" {
            $commonPaths = @(
                "C:\Program Files\WinRAR\rar.exe",
                "C:\Program Files (x86)\WinRAR\rar.exe",
                "$env:ProgramFiles\WinRAR\rar.exe",
                "${env:ProgramFiles(x86)}\WinRAR\rar.exe"
            )
        }
        "*7z*" {
            $commonPaths = @(
                "C:\Program Files\7-Zip\7z.exe",
                "C:\Program Files (x86)\7-Zip\7z.exe",
                "$env:ProgramFiles\7-Zip\7z.exe",
                "${env:ProgramFiles(x86)}\7-zip\7z.exe",
                "C:\ProgramData\chocolatey\bin\7z.exe"
            )
        }
    }

    foreach ($path in $commonPaths) {
        if (Test-Path $path) {
            return $path
        }
    }

    return $null
}

function Detect-CleanUpHooks {
    $hooks = @(
        "nfo",
        "rar",
        "osx_junk",
        "windows_junk",
        "covers_folders",
        "proof_folders",
        "sample_folders",
        "sample_videos",
        "empty_folders"
    )
    $script:UNRARALL_DETECTED_CLEAN_UP_HOOKS = $hooks
}

# NEW FUNCTION: Convert hook name to PascalCase function name
function ConvertTo-PascalCase {
    param([string]$HookName)
    
    # Split by underscore and capitalize each part
    $parts = $HookName -split '_'
    $pascalParts = $parts | ForEach-Object {
        if ($_.Length -gt 0) {
            $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower()
        }
    }
    return ($pascalParts -join '')
}

function Unrarall-RemoveFileOrFolder {
    param(
        [string]$Path,
        [string]$HookName
    )

    if (Test-Path $Path) {
        if ($ShowProgress) {
            Write-Message "nnl" ("Hook " + $HookName + ": Found " + $Path + ". Attempting to remove... ")
        }
        if (-not $Dry) {
            Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($ShowProgress) {
            Write-Message "ok" "Success"
        }
    } elseif ($ShowProgress) {
        Write-Message "info" ("Hook " + $HookName + ": No " + $Path + " file/folder found.")
    }
}

function Unrarall-Clean-Nfo {
    param(
        [string]$Mode,
        [string]$SFilename,
        [string]$RarFileDir
    )
    switch ($Mode) {
        "help"  { "Removes .nfo files with the same name as the .rar file" }
        "clean" {
            $nfoPath = Join-Path $RarFileDir ($SFilename + ".nfo")
            Unrarall-RemoveFileOrFolder $nfoPath "nfo"
        }
    }
}

function Unrarall-Clean-Rar {
    param(
        [string]$Mode,
        [string]$SFilename,
        [string]$RarFileDir
    )

    switch ($Mode) {
        "help"  { "Removes rar files and sfv files" }
        "clean" {
            if ($ShowProgress) {
                Write-Message "info" ("Deleting " + $SFilename + " rar files (in '" + $RarFileDir + "')...")
            }

            if (-not (Test-Path $RarFileDir -PathType Container)) {
                Write-Message "error" ("RARFILE_DIR (" + $RarFileDir + ") is not a directory")
                return
            }

            # ^<sfilename>\.(sfv|[0-9]+|[r-z][0-9]+|rar|part[0-9]+\.rar)$
            $escaped = [regex]::Escape($SFilename)
            $pattern = '^' + $escaped + '\.(sfv|[0-9]+|[r-z][0-9]+|rar|part[0-9]+\.rar)$'

            Get-ChildItem -Path $RarFileDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $pattern } |
                ForEach-Object {
                    Unrarall-RemoveFileOrFolder $_.FullName "rar"
                }
        }
    }
}

function Unrarall-Clean-OsxJunk {
    param(
        [string]$Mode,
        [string]$SFilename,
        [string]$RarFileDir
    )
    switch ($Mode) {
        "help"  { "Removes junk OSX files" }
        "clean" {
            $dsStorePath = Join-Path $RarFileDir ".DS_Store"
            Unrarall-RemoveFileOrFolder $dsStorePath "osx_junk"
        }
    }
}

function Unrarall-Clean-WindowsJunk {
    param(
        [string]$Mode,
        [string]$SFilename,
        [string]$RarFileDir
    )
    switch ($Mode) {
        "help"  { "Removes junk Windows files" }
        "clean" {
            $thumbsPath = Join-Path $RarFileDir "Thumbs.db"
            Unrarall-RemoveFileOrFolder $thumbsPath "windows_junk"
        }
    }
}

function Unrarall-Clean-CoversFolders {
    param(
        [string]$Mode,
        [string]$SFilename,
        [string]$RarFileDir
    )
    switch ($Mode) {
        "help"  { "Removes junk Covers folders" }
        "clean" {
            if ($ShowProgress) {
                Write-Message "info" "Removing all Covers/ folders"
            }
            Get-ChildItem -Path $RarFileDir -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq "Covers" -or $_.Name -eq "covers" } |
                ForEach-Object {
                    Unrarall-RemoveFileOrFolder $_.FullName "covers_folders"
                }
        }
    }
}

function Unrarall-Clean-ProofFolders {
    param(
        [string]$Mode,
        [string]$SFilename,
        [string]$RarFileDir
    )
    switch ($Mode) {
        "help"  { "Removes junk Proof folders" }
        "clean" {
            if ($ShowProgress) {
                Write-Message "info" "Removing all Proof/ folders"
            }
            Get-ChildItem -Path $RarFileDir -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq "Proof" -or $_.Name -eq "proof" } |
                ForEach-Object {
                    Unrarall-RemoveFileOrFolder $_.FullName "proof_folders"
                }
        }
    }
}

function Unrarall-Clean-SampleFolders {
    param(
        [string]$Mode,
        [string]$SFilename,
        [string]$RarFileDir
    )
    switch ($Mode) {
        "help"  { "Removes Sample folders" }
        "clean" {
            if ($ShowProgress) {
                Write-Message "info" "Removing all Sample/ folders"
            }
            Get-ChildItem -Path $RarFileDir -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq "Sample" -or $_.Name -eq "sample" } |
                ForEach-Object {
                    Unrarall-RemoveFileOrFolder $_.FullName "sample_folders"
                }
        }
    }
}

function Unrarall-Clean-SampleVideos {
    param(
        [string]$Mode,
        [string]$SFilename,
        [string]$RarFileDir
    )
    switch ($Mode) {
        "help"  { "Removes sample video files matching the release" }
        "clean" {
            if ($ShowProgress) {
                Write-Message "info" ("Removing sample video files for " + $SFilename)
            }
            $videoExtensions = 'asf','avi','mkv','mp4','m4v','mov','mpg','mpeg','ogg','webm','wmv'
            Get-ChildItem -Path $RarFileDir -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Name -like "sample*" -and
                    $videoExtensions -contains $_.Extension.TrimStart('.').ToLower()
                } |
                ForEach-Object {
                    Unrarall-RemoveFileOrFolder $_.FullName "sample_videos"
                }
        }
    }
}

function Unrarall-Clean-EmptyFolders {
    param(
        [string]$Mode,
        [string]$SFilename,
        [string]$RarFileDir
    )
    switch ($Mode) {
        "help"  { "Removes empty folders" }
        "clean" {
            if ($ShowProgress) {
                Write-Message "info" "Removing empty folders"
            }
            Get-ChildItem -Path $RarFileDir -Directory -Recurse -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                ForEach-Object {
                    $hasContent = Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue |
                                  Where-Object { $_.Name -notin @('.','..') }
                    if (-not $hasContent) {
                        if (-not $Dry) {
                            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
        }
    }
}

function Safe-Move {
    param(
        [string]$Source,
        [string]$Destination
    )

    if ($Dry) {
        Write-Message "info" ("[DRY] Move '" + $Source + "' -> '" + $Destination + "'")
        return
    }

    if ($MV_BACKUP) {
        if (Test-Path $Destination) {
            $counter = 1
            while (Test-Path ($Destination + "." + $counter)) {
                $counter++
            }
            Move-Item $Source ($Destination + "." + $counter) -Force -ErrorAction SilentlyContinue
        } else {
            Move-Item $Source $Destination -Force -ErrorAction SilentlyContinue
        }
    } else {
        Move-Item $Source $Destination -Force -ErrorAction SilentlyContinue
    }
}

function Extract-WithProgress {
    param(
        [string]$Binary,
        [string]$ArchivePath,
        [string]$OutputDir,
        [string]$Password = $null
    )

    $binaryName = [System.IO.Path]::GetFileNameWithoutExtension($Binary)
    $success = $false
    $exitCode = 0

    if ($Binary -eq "echo") {
        Write-Host ("[DRY] " + $Binary + " " + $ArchivePath + " -> " + $OutputDir)
        return @{ Success = $true; ExitCode = 0 }
    }

    if ($binaryName -in @("unrar", "rar")) {
        $args = @($UNRAR_METHOD, "-y", "-o+")
        if ($Password) {
            $args += "-p$Password"
        } else {
            $args += "-p-"
        }
        if (-not $ShowProgress) {
            $args += "-idq"
        }
        $args += "`"$ArchivePath`""
        $args += "`"$OutputDir`""

        # VERBOSE DEBUG OUTPUT
        Write-Host "DEBUG: Binary = $Binary" -ForegroundColor Yellow
        Write-Host "DEBUG: Arguments = $($args -join ' ')" -ForegroundColor Yellow
        Write-Host "DEBUG: Archive = $ArchivePath" -ForegroundColor Yellow
        Write-Host "DEBUG: Output = $OutputDir" -ForegroundColor Yellow

        $process = Start-Process -FilePath $Binary -ArgumentList $args -NoNewWindow -Wait -PassThru
        $exitCode = $process.ExitCode
        if ($exitCode -eq 0) { $success = $true }
    }
    elseif ($binaryName -eq "7z") {
        $args = @("x")
        
        if ($Password) {
            $args += "-p$Password"
        }
        
        $args += "-o$OutputDir"
        $args += "-y"
        
        if (-not $ShowProgress) {
            $args += "-bd"
            $args += "-bso0"
            $args += "-bsp0"
        }
        
        # Quote the archive path to handle spaces and special characters
        $args += "`"$ArchivePath`""

        # VERBOSE DEBUG OUTPUT
        Write-Host "DEBUG: Binary = $Binary" -ForegroundColor Yellow
        Write-Host "DEBUG: Full command line = $Binary $($args -join ' ')" -ForegroundColor Yellow
        Write-Host "DEBUG: Archive = $ArchivePath" -ForegroundColor Yellow
        Write-Host "DEBUG: Output = $OutputDir" -ForegroundColor Yellow
        Write-Host "DEBUG: Arguments array:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $args.Count; $i++) {
            Write-Host "  [$i] = '$($args[$i])'" -ForegroundColor Cyan
        }

        $process = Start-Process -FilePath $Binary -ArgumentList $args -NoNewWindow -Wait -PassThru
        $exitCode = $process.ExitCode
        if ($exitCode -eq 0) { $success = $true }
    }

    return @{ Success = $success; ExitCode = $exitCode }
}

function Process-Directory {
    param(
        [string]$Path,
        [int]$CurrentDepth
    )

    if ($ShowProgress) {
        Write-Message "info" ("Processing directory: " + $Path)
    }

    $rarFiles = Get-ChildItem -Path $Path -Recurse -Include @("*.rar", "*.001") -File -ErrorAction SilentlyContinue
    $totalFiles = $rarFiles.Count
    $currentFile = 0

    foreach ($file in $rarFiles) {
        $currentFile++

        if ($file.Name -match '\.part(\d+)\.rar$') {
            if ([int]$matches[1] -ne 1) { continue }
            $sfilename = $file.BaseName -replace '\.part\d+$', ''
        } elseif ($file.Name -match '\.(\d{3})$') {
            if ($matches[1] -ne "001") { continue }
            $sfilename = $file.BaseName
        } else {
            $sfilename = $file.BaseName
        }

        $success = $true

        if ($CKSFV -and -not $DisableCksfv) {
            $sfvFile = Join-Path $file.DirectoryName ($sfilename + ".sfv")
            if (Test-Path $sfvFile) {
                if ($ShowProgress) {
                    Write-Message "info" ("Checking CRC for " + $sfilename + " (not implemented)")
                }
            }
        }

        if ($SkipIfExists -and -not $Force) {
            if (Is-AlreadyExtracted $script:UNRARALL_BIN $file.FullName) {
                Write-Message "ok" ("Already extracted: " + $file.Name)
                continue
            }
        }

        # Determine target directory BEFORE extraction
        if ($Output) {
            $targetDir = $Output
        } else {
            # Extract to subdirectory named after the RAR file
            $targetDir = Join-Path $file.DirectoryName $sfilename
        }

        # Create target directory if it doesn't exist
        if (-not (Test-Path $targetDir)) {
            if (-not $Dry) {
                New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            }
        }

        try {
            if ($ShowProgress) {
                Write-Message "nnl" ("[{0}/{1}] Extracting {2}... " -f $currentFile, $totalFiles, $file.Name)
            } else {
                Write-Message "nnl" ("Extracting {0}... " -f $file.Name)
            }

            if ($script:UNRARALL_BIN -eq "echo") {
                Write-Message "ok" "(dry run)"
                continue
            }

            $encrypted = Is-RarEncrypted $script:UNRARALL_BIN $file.FullName

            if ($encrypted) {
                # Check if we have a cached password for this directory
                $archiveDir = $file.DirectoryName
                $cachedPassword = $script:PASSWORD_CACHE[$archiveDir]
                
                if ($cachedPassword) {
                    # Use cached password
                    if ($ShowProgress) {
                        Write-Message "info" ("Using cached password (file $currentFile/$totalFiles)")
                    }
                    $result = Extract-WithProgress $script:UNRARALL_BIN $file.FullName $targetDir $cachedPassword
                    if (-not $result.Success) {
                        throw "Cached password failed - archive might have different password"
                    }
                    $extracted = $true
                } elseif ($script:PASSWORD_TEST_COUNT -lt $script:MAX_PASSWORD_TESTS) {
                    # Test passwords on first 3 files only
                    $script:PASSWORD_TEST_COUNT++
                    
                    if (Test-Path $script:UNRARALL_PASSWORD_FILE) {
                        $passwords = Get-Content $script:UNRARALL_PASSWORD_FILE | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") }
                        $extracted = $false

                        if ($ShowProgress) {
                            Write-Message "warn" ("Password protected - testing $($passwords.Count) passwords (file $script:PASSWORD_TEST_COUNT/$script:MAX_PASSWORD_TESTS)...")
                        }

                        foreach ($password in $passwords) {
                            try {
                                $result = Extract-WithProgress $script:UNRARALL_BIN $file.FullName $targetDir $password
                                if ($result.Success) {
                                    # Cache the working password
                                    $script:PASSWORD_CACHE[$archiveDir] = $password
                                    if ($ShowProgress) {
                                        Write-Message "ok" ("✓ Found working password: $password (cached for remaining files)")
                                    }
                                    $extracted = $true
                                    break
                                }
                            } catch {}
                        }

                        if (-not $extracted) {
                            throw "Could not extract with any password"
                        }
                    } else {
                        throw "Archive is encrypted but password file not found: $script:UNRARALL_PASSWORD_FILE"
                    }
                } else {
                    # Already tested 3 files but no password found - this shouldn't happen if cache works
                    throw "Password testing limit reached (tested $script:MAX_PASSWORD_TESTS files) - no working password found"
                }
            } else {
                $result = Extract-WithProgress $script:UNRARALL_BIN $file.FullName $targetDir
                if (-not $result.Success) {
                    switch ($result.ExitCode) {
                        2    { throw "Fatal error in archive" }
                        3    { throw "CRC error - archive might be corrupted" }
                        4    { throw "Attempt to modify a locked archive" }
                        5    { throw "Write error" }
                        6    { throw "Open error" }
                        7    { throw "User error (wrong command)" }
                        8    { throw "Not enough memory" }
                        9    { throw "File create error" }
                        10   { throw "No files matching pattern" }
                        255  { throw "User break" }
                        default { throw ("Extraction failed with error code: " + $result.ExitCode) }
                    }
                }
            }

            Write-Message "ok" "OK"
            $script:COUNT++

            # Handle nested archives if depth allows
            if ($CurrentDepth -gt 0) {
                $nestedRars = Get-ChildItem -Path $targetDir -Recurse -Include @("*.rar", "*.001") -File -ErrorAction SilentlyContinue
                if ($nestedRars.Count -gt 0) {
                    if ($ShowProgress) {
                        Write-Message "info" ("Detected rar archives inside of " + $file.FullName + ", recursively extracting")
                    }
                    Process-Directory $targetDir ($CurrentDepth - 1)
                }
            }

            if ($script:UNRARALL_CLEAN_UP_HOOKS_TO_RUN[0] -ne "none") {
                if ($ShowProgress) {
                    Write-Message "nnl" "Running hooks..."
                }

                foreach ($hook in $script:UNRARALL_CLEAN_UP_HOOKS_TO_RUN) {
                    if ($hook -eq "all") {
                        foreach ($detectedHook in $script:UNRARALL_DETECTED_CLEAN_UP_HOOKS) {
                            if ($ShowProgress) {
                                Write-Message "nnl" ($detectedHook + " ")
                            }
                            # FIXED: Convert hook name to PascalCase
                            $functionName = "Unrarall-Clean-" + (ConvertTo-PascalCase $detectedHook)
                            & $functionName "clean" $sfilename $file.DirectoryName
                        }
                    } else {
                        if ($ShowProgress) {
                            Write-Message "nnl" ($hook + " ")
                        }
                        # FIXED: Convert hook name to PascalCase
                        $functionName = "Unrarall-Clean-" + (ConvertTo-PascalCase $hook)
                        & $functionName "clean" $sfilename $file.DirectoryName
                    }
                }

                if ($ShowProgress) {
                    Write-Message "ok" "Finished running hooks"
                }
            }

        } catch {
            Write-Message "error" ("Failed: " + $_.Exception.Message)
            $script:FAIL_COUNT++
            $script:COUNT--
        }

        if ($ShowProgress -and $totalFiles -gt 0) {
            $percent = [math]::Round(($currentFile / $totalFiles) * 100, 1)
            Write-Message "info" ("Overall progress: {0}% ({1}/{2})" -f $percent, $currentFile, $totalFiles)
        }
    }
}

# Main script execution
if ($Help)    { Show-Usage; exit 0 }
if ($Version) { Write-Host $UNRARALL_VERSION; exit 0 }

# Backend selection
if ($SevenZip) {
    $script:UNRARALL_BIN = Find-WindowsBinary "7z.exe"
    if (-not $script:UNRARALL_BIN) { $script:UNRARALL_BIN = "7z.exe" }
} elseif ($Backend) {
    $script:UNRARALL_BIN = Find-WindowsBinary ($Backend + ".exe")
    if (-not $script:UNRARALL_BIN) { $script:UNRARALL_BIN = ($Backend + ".exe") }
} elseif ($Dry) {
    $script:UNRARALL_BIN = "echo"
}

if (-not $script:UNRARALL_BIN -or $script:UNRARALL_BIN -ne "echo") {
    foreach ($binary in $UNRAR_BINARIES) {
        $foundBinary = Find-WindowsBinary $binary
        if ($foundBinary) {
            $script:UNRARALL_BIN = $foundBinary
            break
        }
    }

    if (-not $script:UNRARALL_BIN) {
        Write-Message "error" "No extraction binary found. Please install one of:"
        Write-Message "error" "  - WinRAR (unrar.exe / rar.exe)"
        Write-Message "error" "  - 7-Zip (7z.exe)"
        Write-Message "error" "or specify backend via -Backend"
        exit 1
    }
}

if ($Clean) {
    $script:UNRARALL_CLEAN_UP_HOOKS_TO_RUN = $Clean
} else {
    $script:UNRARALL_CLEAN_UP_HOOKS_TO_RUN = @("none")
}

Detect-CleanUpHooks

if ($script:UNRARALL_CLEAN_UP_HOOKS_TO_RUN[0] -ne "none") {
    foreach ($hook in $script:UNRARALL_CLEAN_UP_HOOKS_TO_RUN) {
        if ($hook -eq "all" -or $hook -eq "none") { continue }
        if ($script:UNRARALL_DETECTED_CLEAN_UP_HOOKS -notcontains $hook) {
            Write-Message "error" ("Invalid clean-up hook: " + $hook)
            exit 1
        }
    }
}

if (-not (Test-Path $Directory -PathType Container)) {
    Write-Message "error" ("Directory not found: " + $Directory)
    exit 1
}

$Directory = (Resolve-Path $Directory).Path

if ($ShowProgress) {
    Write-Message "info" ("Using " + $script:UNRARALL_BIN + " for extraction")
}

Process-Directory $Directory $Depth

if ($script:COUNT -gt 0) {
    $exitPhrase = "found and extracted"
    if ($script:UNRARALL_CLEAN_UP_HOOKS_TO_RUN[0] -ne "none") {
        $exitPhrase = "found, extracted and then cleaned using the following hooks: " +
            ($script:UNRARALL_CLEAN_UP_HOOKS_TO_RUN -join ", ")
    }
    Write-Message "info" ("{0} rar files {1}" -f $script:COUNT, $exitPhrase)
} else {
    Write-Message "error" "no rar files extracted"
}

if ($script:FAIL_COUNT -gt 0) {
    if (-not $Quiet) {
        Write-Message "error" ("{0} failure(s)" -f $script:FAIL_COUNT)
    }
    if (-not $AllowFailures) {
        exit 1
    } else {
        if ($script:COUNT -eq 0) {
            exit 1
        } else {
            Write-Message "info" ("{0} success(es)" -f $script:COUNT)
        }
    }
}
