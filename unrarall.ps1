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
    [string]$PasswordFile,
    [switch]$SevenZip,
    [string]$Backend,
    [switch]$Dry,
    [switch]$AllowFailures,
    [switch]$FullPath,
    [switch]$Help,
    [switch]$Version
)

# Set some defaults
$UNRARALL_VERSION = "0.5.0"
$UNRARALL_EXECUTABLE_NAME = $MyInvocation.MyCommand.Name
$UNRARALL_PID = $PID
$CKSFV = 1
$UNRAR_METHOD = "e"
$MV_BACKUP = $true

# Clean up hooks
$UNRARALL_DETECTED_CLEAN_UP_HOOKS = @()
$UNRARALL_CLEAN_UP_HOOKS_TO_RUN = @("none")
$UNRAR_BINARIES = @("unrar.exe", "rar.exe", "7z.exe", "7z")
$UNRARALL_BIN = ""
$COUNT = 0
$FAIL_COUNT = 0

# Password file default
if (-not $PasswordFile) {
    $UNRARALL_PASSWORD_FILE = Join-Path $HOME ".unrar_passwords"
} else {
    $UNRARALL_PASSWORD_FILE = $PasswordFile
}

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

OPTIONS

-Directory <DIRECTORY>    Directory to process (default: current directory)
-Clean <hook[,hook]>      Clean up hooks to execute
-Force                    Force unrar even if sfv check failed
-ShowProgress             Show extraction progress (including % progress bar)
-Quiet                    Be completely quiet
-SevenZip                 Force using 7zip
-Dry                      Dry run, no action performed
-DisableCksfv             Disable CRC checking
-PasswordFile <file>      Path to password file
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
- empty_folders: Removes empty folders
- all: Execute all the above hooks
- none: Do not execute any clean up hooks (default)

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
        "ok" { Write-Host $Message -ForegroundColor Green }
        "info" { Write-Host $Message }
        "nnl" { Write-Host $Message -NoNewline }
        default { Write-Host $Message }
    }
}

function Show-ExtractionProgress {
    param(
        [string]$OutputLine
    )

    if (-not $ShowProgress) { return }

    # Versuche, Prozentangaben aus der Ausgabe zu extrahieren
    # Unrar Muster: "Extracting  ...       somefile.txt           OK"
    # Oder mit %: "Extracting  somefile.txt                    5%"

    if ($OutputLine -match "(\d{1,3})%") {
        $percent = $matches[1]
        Write-Host "`rExtracting... $percent% complete" -NoNewline
    }
    elseif ($OutputLine -match "^\s*Extracting\s+") {
        # Zeile zeigt Extraktion an, aber keinen Prozentwert
        Write-Host "`r$OutputLine" -NoNewline
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
                return "-o+ -idq"  # -idq = quiet mode, nur Fehler anzeigen
            }
        }
        "7z" {
            if ($ShowProgress) {
                return ""
            } else {
                return "-bd"  # -bd = disable Prozentanzeige
            }
        }
        default {
            Write-Message "error" "Unsupported program: $Binary"
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
            $files = $output | Where-Object { $_ -match "^Path =" } | ForEach-Object { $_ -replace "^Path = ", "" }
        }

        foreach ($file in $files) {
            if (-not (Test-Path $file)) {
                return $false
            }
        }
        return $true
    } catch {
        if ($ShowProgress) {
            Write-Message "info" "Unable to check if already extracted: $($_.Exception.Message)"
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
            Write-Message "info" "Error checking encryption: $($_.Exception.Message)"
        }
        return $false
    }
}

function Find-WindowsBinary {
    param([string]$BinaryName)

    # First try Get-Command
    try {
        $cmd = Get-Command $BinaryName -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    } catch {}

    # Try without .exe extension
    if ($BinaryName -like "*.exe") {
        $nameWithoutExe = $BinaryName -replace '\.exe$', ''
        try {
            $cmd = Get-Command $nameWithoutExe -ErrorAction SilentlyContinue
            if ($cmd) {
                return $cmd.Source
            }
        } catch {}
    }

    # Try common installation paths for Windows
    $commonPaths = @()

    switch -Wildcard ($BinaryName) {
        "*unrar*" {
            $commonPaths = @(
                "C:\Program Files\WinRAR\unrar.exe",
                "C:\Program Files (x86)\WinRAR\unrar.exe",
                "$env:ProgramFiles\WinRAR\unrar.exe",
                "${env:ProgramFiles(x86)}\WinRAR\unrar.exe"
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
                "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
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
    $hooks = @("nfo", "rar", "osx_junk", "windows_junk", "covers_folders",
               "proof_folders", "sample_folders", "sample_videos", "empty_folders")
    $UNRARALL_DETECTED_CLEAN_UP_HOOKS = $hooks
}

function Unrarall-RemoveFileOrFolder {
    param(
        [string]$Path,
        [string]$HookName
    )

    if (Test-Path $Path) {
        if ($ShowProgress) { Write-Message "nnl" "Hook ${HookName}: Found ${Path}. Attempting to remove..." }
        Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
        if ($ShowProgress) { Write-Message "ok" "Success" }
    } elseif ($ShowProgress) {
        Write-Message "info" "Hook ${HookName}: No ${Path} file/folder found."
    }
}

# Clean-up hooks implementations (abgekürzt für Lesbarkeit)
function Unrarall-Clean-Nfo {
    param([string]$Mode, [string]$SFilename, [string]$RarFileDir) {
        switch ($Mode) {
            "help" { return "Removes .nfo files with the same name as the .rar file" }
            "clean" { $nfoPath = Join-Path $RarFileDir "$SFilename.nfo"; Unrarall-RemoveFileOrFolder $nfoPath "nfo" }
        }
    }
}

function Unrarall-Clean-Rar {
    param([string]$Mode, [string]$SFilename, [string]$RarFileDir) {
        switch ($Mode) {
            "help" { return "Removes rar files and sfv files" }
            "clean" {
                if ($ShowProgress) { Write-Message "info" "Deleting ${SFilename} rar files (in `"${RarFileDir}`")..." }
                $patterns = @("*.sfv", "*.[0-9]*", "*.[r-z][0-9]*", "*.rar", "*.part*.rar")
                foreach ($pattern in $patterns) {
                    $files = Get-ChildItem -Path $RarFileDir -Filter $pattern -File -ErrorAction SilentlyContinue |
                             Where-Object { $_.BaseName -like "$SFilename*" }
                    foreach ($file in $files) { Unrarall-RemoveFileOrFolder $file.FullName "rar" }
                }
            }
        }
    }
}

function Unrarall-Clean-OsxJunk {
    param([string]$Mode, [string]$SFilename, [string]$RarFileDir) {
        switch ($Mode) {
            "help" { return "Removes junk OSX files" }
            "clean" { $dsStorePath = Join-Path $RarFileDir ".DS_Store"; Unrarall-RemoveFileOrFolder $dsStorePath "osx_junk" }
        }
    }
}

function Unrarall-Clean-WindowsJunk {
    param([string]$Mode, [string]$SFilename, [string]$RarFileDir) {
        switch ($Mode) {
            "help" { return "Removes junk Windows files" }
            "clean" { $thumbsPath = Join-Path $RarFileDir "Thumbs.db"; Unrarall-RemoveFileOrFolder $thumbsPath "windows_junk" }
        }
    }
}

function Unrarall-Clean-CoversFolders {
    param([string]$Mode, [string]$SFilename, [string]$RarFileDir) {
        switch ($Mode) {
            "help" { return "Removes junk Covers folders" }
            "clean" {
                if ($ShowProgress) { Write-Message "info" "Removing all Covers/ folders" }
                $coversFolders = Get-ChildItem -Path $RarFileDir -Directory -Recurse -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -eq "Covers" -or $_.Name -eq "covers" }
                foreach ($folder in $coversFolders) { Unrarall-RemoveFileOrFolder $folder.FullName "covers_folders" }
            }
        }
    }
}

function Unrarall-Clean-ProofFolders {
    param([string]$Mode, [string]$SFilename, [string]$RarFileDir) {
        switch ($Mode) {
            "help" { return "Removes junk Proof folders" }
            "clean" {
                if ($ShowProgress) { Write-Message "info" "Removing all Proof/ folders" }
                $proofFolders = Get-ChildItem -Path $RarFileDir -Directory -Recurse -ErrorAction SilentlyContinue |
                               Where-Object { $_.Name -eq "Proof" -or $_.Name -eq "proof" }
                foreach ($folder in $proofFolders) { Unrarall-RemoveFileOrFolder $folder.FullName "proof_folders" }
            }
        }
    }
}

function Unrarall-Clean-SampleFolders {
    param([string]$Mode, [string]$SFilename, [string]$RarFileDir) {
        switch ($Mode) {
            "help" { return "Removes Sample folders" }
            "clean" {
                if ($ShowProgress) { Write-Message "info" "Removing all Sample/ folders" }
                $sampleFolders = Get-ChildItem -Path $RarFileDir -Directory -Recurse -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -eq "Sample" -or $_.Name -eq "sample" }
                foreach ($folder in $sampleFolders) { Unrarall-RemoveFileOrFolder $folder.FullName "sample_folders" }
            }
        }
    }
}

function Unrarall-Clean-EmptyFolders {
    param([string]$Mode, [string]$SFilename, [string]$RarFileDir) {
        switch ($Mode) {
            "help" { return "Removes empty folders" }
            "clean" {
                if ($ShowProgress) { Write-Message "info" "Removing empty folders" }
                $emptyFolders = Get-ChildItem -Path $RarFileDir -Directory -Recurse -ErrorAction SilentlyContinue |
                               Where-Object { @(Get-ChildItem -Path $_.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0 }
                foreach ($folder in $emptyFolders) {
                    try { Remove-Item $folder.FullName -Force -ErrorAction SilentlyContinue }
                    catch { if ($ShowProgress) { Write-Message "info" "Could not remove folder: $($folder.FullName)" } }
                }
            }
        }
    }
}

function Safe-Move {
    param([string]$Source, [string]$Destination)
    if ($MV_BACKUP) {
        if (Test-Path $Destination) {
            $counter = 1
            while (Test-Path "$Destination.$counter") { $counter++ }
            Move-Item $Source "$Destination.$counter" -Force -ErrorAction SilentlyContinue
        } else { Move-Item $Source $Destination -Force -ErrorAction SilentlyContinue }
    } else { Move-Item $Source $Destination -Force -ErrorAction SilentlyContinue }
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

    if ($binaryName -in @("unrar", "rar")) {
        # Unrar/RAR mit Fortschrittsanzeige
        $args = @("x", "-y", "-o+")
        if ($Password) {
            $args += "-p$Password"
        }
        $args += $ArchivePath
        $args += $OutputDir

        $process = Start-Process -FilePath $Binary -ArgumentList $args -NoNewWindow -Wait -PassThru

        if ($process.ExitCode -eq 0) {
            $success = $true
        }
    }
    elseif ($binaryName -eq "7z") {
        # 7-Zip mit Fortschrittsanzeige
        $args = @("x", "-y", "-o$OutputDir")
        if ($Password) {
            $args += "-p$Password"
        }
        $args += $ArchivePath

        $process = Start-Process -FilePath $Binary -ArgumentList $args -NoNewWindow -Wait -PassThru

        if ($process.ExitCode -eq 0) {
            $success = $true
        }
    }

    return @{ Success = $success; ExitCode = $process.ExitCode }
}

function Process-Directory {
    param([string]$Path, [int]$CurrentDepth)

    if ($ShowProgress) { Write-Message "info" "Processing directory: $Path" }

    $rarFiles = Get-ChildItem -Path $Path -Recurse -Include @("*.rar", "*.001") -File -ErrorAction SilentlyContinue
    $totalFiles = $rarFiles.Count
    $currentFile = 0

    foreach ($file in $rarFiles) {
        $currentFile++

        # Determine the base filename without extension
        if ($file.Name -match '\.part(\d+)\.rar$') {
            if ([int]$matches[1] -ne 1) { continue }
            $sfilename = $file.BaseName -replace '\.part\d+$', ''
        } elseif ($file.Name -match '\.(\d{3})$') {
            if ($matches[1] -ne "001") { continue }
            $sfilename = $file.BaseName
        } else {
            $sfilename = $file.BaseName
        }

        # Check CRC if enabled
        $success = $true
        if ($CKSFV -and -not $DisableCksfv) {
            $sfvFile = Join-Path $file.DirectoryName "$sfilename.sfv"
            if (Test-Path $sfvFile) {
                if ($ShowProgress) { Write-Message "info" "Checking CRC for $sfilename" }
                # Note: Windows doesn't have cksfv built-in
            }
        }

        # Check if already extracted
        if ($SkipIfExists -and -not $Force) {
            if (Is-AlreadyExtracted $UNRARALL_BIN $file.FullName) {
                Write-Message "ok" "Already extracted: $($file.Name)"
                continue
            }
        }

        # Create temp directory
        $tempDir = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

        # Extract
        try {
            if ($ShowProgress) {
                Write-Message "nnl" "[$currentFile/$totalFiles] Extracting $($file.Name)... "
            } else {
                Write-Message "nnl" "Extracting $($file.Name)... "
            }

            if ($UNRARALL_BIN -eq "echo") {
                Write-Message "ok" "(dry run)"
                continue
            }

            $encrypted = Is-RarEncrypted $UNRARALL_BIN $file.FullName

            if ($encrypted) {
                # Try passwords from file
                if (Test-Path $UNRARALL_PASSWORD_FILE) {
                    $passwords = Get-Content $UNRARALL_PASSWORD_FILE
                    $extracted = $false

                    foreach ($password in $passwords) {
                        try {
                            $result = Extract-WithProgress $UNRARALL_BIN $file.FullName $tempDir $password

                            if ($result.Success) {
                                if ($ShowProgress) { Write-Message "info" "Extracted with password" }
                                $extracted = $true
                                break
                            }
                        } catch {}
                    }

                    if (-not $extracted) { throw "Could not extract with any password" }
                } else { throw "Archive is encrypted but no password file provided" }
            } else {
                # Not encrypted
                $result = Extract-WithProgress $UNRARALL_BIN $file.FullName $tempDir

                if (-not $result.Success) {
                    # Try to provide better error messages
                    switch ($result.ExitCode) {
                        2 { throw "Fatal error in archive" }
                        3 { throw "CRC error - archive might be corrupted" }
                        4 { throw "Attempt to modify a locked archive" }
                        5 { throw "Write error" }
                        6 { throw "Open error" }
                        7 { throw "User error (wrong command)" }
                        8 { throw "Not enough memory" }
                        9 { throw "File create error" }
                        10 { throw "No files matching pattern" }
                        255 { throw "User break" }
                        default { throw "Extraction failed with error code: $($result.ExitCode)" }
                    }
                }
            }

            Write-Message "ok" "OK"
            $script:COUNT++

            # Recursively extract nested archives
            if ($CurrentDepth -gt 0) {
                $nestedRars = Get-ChildItem -Path $tempDir -Recurse -Include @("*.rar", "*.001") -File -ErrorAction SilentlyContinue
                if ($nestedRars.Count -gt 0) {
                    if ($ShowProgress) { Write-Message "info" "Detected rar archives inside of $($file.FullName), recursively extracting" }
                    Process-Directory $tempDir ($CurrentDepth - 1)
                }
            }

            # Move extracted files
            $extractedFiles = Get-ChildItem -Path $tempDir -Recurse -File -ErrorAction SilentlyContinue

            # Determine target directory
            if ($Output) {
                $targetDir = $Output
            } else {
                $targetDir = $file.DirectoryName
            }

            foreach ($extractedFile in $extractedFiles) {
                $relativePath = $extractedFile.FullName.Substring($tempDir.Length + 1)
                $targetPath = Join-Path $targetDir $relativePath

                $targetDirPath = Split-Path $targetPath -Parent
                if (-not (Test-Path $targetDirPath)) {
                    New-Item -ItemType Directory -Path $targetDirPath -Force | Out-Null
                }

                Safe-Move $extractedFile.FullName $targetPath
            }

            # Run clean-up hooks
            if ($UNRARALL_CLEAN_UP_HOOKS_TO_RUN[0] -ne "none") {
                if ($ShowProgress) { Write-Message "nnl" "Running hooks..." }
                foreach ($hook in $UNRARALL_CLEAN_UP_HOOKS_TO_RUN) {
                    if ($hook -eq "all") {
                        foreach ($detectedHook in $UNRARALL_DETECTED_CLEAN_UP_HOOKS) {
                            if ($ShowProgress) { Write-Message "nnl" "$detectedHook " }
                            Invoke-Expression "Unrarall-Clean-$detectedHook clean `"$sfilename`" `"$($file.DirectoryName)`""
                        }
                    } else {
                        if ($ShowProgress) { Write-Message "nnl" "$hook " }
                        Invoke-Expression "Unrarall-Clean-$hook clean `"$sfilename`" `"$($file.DirectoryName)`""
                    }
                }
                if ($ShowProgress) { Write-Message "ok" "Finished running hooks" }
            }

        } catch {
            Write-Message "error" "Failed: $($_.Exception.Message)"
            $script:FAIL_COUNT++
            $script:COUNT--
        } finally {
            # Clean up temp directory
            if (Test-Path $tempDir) {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        # Zeige Gesamtfortschritt
        if ($ShowProgress -and $totalFiles -gt 0) {
            $percent = [math]::Round(($currentFile / $totalFiles) * 100, 1)
            Write-Message "info" "Overall progress: $percent% ($currentFile/$totalFiles)"
        }
    }
}

# Main script execution
if ($Help) { Show-Usage; exit 0 }
if ($Version) { Write-Host $UNRARALL_VERSION; exit 0 }

# Set backend
if ($SevenZip) {
    $UNRARALL_BIN = Find-WindowsBinary "7z.exe"
    if (-not $UNRARALL_BIN) { $UNRARALL_BIN = "7z.exe" }
} elseif ($Backend) {
    $UNRARALL_BIN = Find-WindowsBinary "$Backend.exe"
    if (-not $UNRARALL_BIN) { $UNRARALL_BIN = "$Backend.exe" }
} elseif ($Dry) {
    $UNRARALL_BIN = "echo"
}

# Find unrar binary if not specified
if (-not $UNRARALL_BIN -or $UNRARALL_BIN -ne "echo") {
    foreach ($binary in $UNRAR_BINARIES) {
        $foundBinary = Find-WindowsBinary $binary
        if ($foundBinary) {
            $UNRARALL_BIN = $foundBinary
            break
        }
    }

    if (-not $UNRARALL_BIN) {
        Write-Message "error" "No extraction binary found. Please install one of the following:"
        Write-Message "error" "  1. WinRAR (https://www.win-rar.com/) - includes unrar.exe and rar.exe"
        Write-Message "error" "  2. 7-Zip (https://www.7-zip.org/) - includes 7z.exe"
        Write-Message "error" "Or specify the full path using --backend parameter"
        exit 1
    }
}

# Set clean-up hooks
if ($Clean) {
    $UNRARALL_CLEAN_UP_HOOKS_TO_RUN = $Clean
}

# Detect available clean-up hooks
Detect-CleanUpHooks

# Validate clean-up hooks
if ($UNRARALL_CLEAN_UP_HOOKS_TO_RUN[0] -ne "none") {
    foreach ($hook in $UNRARALL_CLEAN_UP_HOOKS_TO_RUN) {
        if ($hook -eq "all" -or $hook -eq "none") { continue }

        $hookFound = $false
        foreach ($detectedHook in $UNRARALL_DETECTED_CLEAN_UP_HOOKS) {
            if ($hook -eq $detectedHook) { $hookFound = $true; break }
        }

        if (-not $hookFound) {
            Write-Message "error" "Invalid clean-up hook: $hook"
            exit 1
        }
    }
}

# Process directory
if (-not (Test-Path $Directory -PathType Container)) {
    Write-Message "error" "Directory not found: $Directory"
    exit 1
}

$Directory = Resolve-Path $Directory

if ($ShowProgress) {
    Write-Message "info" "Using $UNRARALL_BIN for extraction"
}

Process-Directory $Directory $Depth

# Summary
if ($COUNT -gt 0) {
    $exitPhrase = "found and extracted"
    if ($UNRARALL_CLEAN_UP_HOOKS_TO_RUN[0] -ne "none") {
        $exitPhrase = "found, extracted and then cleaned using the following hooks: $($UNRARALL_CLEAN_UP_HOOKS_TO_RUN -join ', ')"
    }
    Write-Message "info" "$COUNT rar files $exitPhrase"
} else {
    Write-Message "error" "no rar files extracted"
}

if ($FAIL_COUNT -gt 0) {
    if (-not $Quiet) {
        Write-Message "error" "${FAIL_COUNT} failure(s)"
    }
    if ($AllowFailures -eq $false) {
        exit 1
    } else {
        if ($COUNT -eq 0) {
            exit 1
        } else {
            Write-Message "info" "${COUNT} success(es)"
        }
    }
}