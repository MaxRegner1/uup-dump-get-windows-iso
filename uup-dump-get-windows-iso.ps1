#!/usr/bin/pwsh
param(
    [string]$windowsTargetName,
    [string]$destinationDirectory = 'output'
)

Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
trap {
    Write-Host "ERROR: $_"
    @(($_.ScriptStackTrace -split '\r?\n') -replace '^(.*)$','ERROR: $1') | Write-Host
    @(($_.Exception.ToString() -split '\r?\n') -replace '^(.*)$','ERROR EXCEPTION: $1') | Write-Host
    Exit 1
}

$TARGETS = @{
    # see https://en.wikipedia.org/wiki/Windows_11
    # see https://en.wikipedia.org/wiki/Windows_11_version_history
    "windows-11" = @{
        search = "windows 11 22631 amd64" # aka 23H2. Enterprise EOL: November 10, 2026.
        edition = "Professional"
        virtualEdition = "Enterprise"
    }
    # see https://en.wikipedia.org/wiki/Windows_Server_2022
    "windows-2022" = @{
        search = "feature update server operating system 20348 amd64" # aka 21H2. Mainstream EOL: October 13, 2026.
        edition = "ServerStandard"
        virtualEdition = $null
    }
    # see https://en.wikipedia.org/wiki/Windows_10
    "windows-10" = @{
        search = "windows 10 22H2 amd64"
        edition = "Professional"
        virtualEdition = "Enterprise"
    }
    # see https://en.wikipedia.org/wiki/Windows_2025
    "windows-2025" = @{
        search = "windows 2025 22631 amd64" # aka 23H2. Enterprise EOL: TBD.
        edition = "Professional"
        virtualEdition = "Enterprise"
    }
}

function New-QueryString {
    param ([hashtable]$parameters)
    @($parameters.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([System.Web.HttpUtility]::UrlEncode($_.Value))"
    }) -join '&'
}

function Invoke-UupDumpApi {
    param (
        [string]$name,
        [hashtable]$body
    )
    # see https://git.uupdump.net/uup-dump/json-api
    for ($n = 0; $n -lt 15; ++$n) {
        if ($n) {
            Write-Host "Waiting a bit before retrying the uup-dump api ${name} request #$n"
            Start-Sleep -Seconds 10
            Write-Host "Retrying the uup-dump api ${name} request #$n"
        }
        try {
            $response = Invoke-RestMethod `
                -Method Get `
                -Uri "https://api.uupdump.net/$name.php" `
                -Body $body
            if ($response.response.error -eq "SEARCH_NO_RESULTS") {
                throw "SEARCH_NO_RESULTS: No results found for the search query."
            }
            return $response
        } catch {
            Write-Host "WARN: failed the uup-dump api $name request: $_"
            if ($_.Exception.Message -match "SEARCH_NO_RESULTS") {
                Exit 1
            }
        }
    }
    throw "timeout making the uup-dump api $name request"
}

function Get-UupDumpIso {
    param (
        [string]$name,
        [hashtable]$target
    )
    Write-Host "Getting the $name metadata"
    $result = Invoke-UupDumpApi listid @{
        search = $target.search
    }
    $result.response.builds.PSObject.Properties `
        | ForEach-Object {
            $id = $_.Value.uuid
            $uupDumpUrl = 'https://uupdump.net/selectlang.php?' + (New-QueryString @{
                id = $id
            })
            Write-Host "Processing $name $id ($uupDumpUrl)"
            $_
        } `
        | Where-Object {
            $result = $target.search -like '*preview*' -or $_.Value.title -notlike '*preview*'
            if (!$result) {
                Write-Host "Skipping. Expected preview=false. Got preview=true."
            }
            $result
        } `
        | ForEach-Object {
            $id = $_.Value.uuid
            Write-Host "Getting the $name $id langs metadata"
            $result = Invoke-UupDumpApi listlangs @{
                id = $id
            }
            if ($result.response.updateInfo.build -ne $_.Value.build) {
                throw 'for some reason listlangs returned an unexpected build'
            }
            $_.Value | Add-Member -NotePropertyMembers @{
                langs = $result.response.langFancyNames
                info = $result.response.updateInfo
            }
            $langs = $_.Value.langs.PSObject.Properties.Name
            $editions = if ($langs -contains 'en-us') {
                Write-Host "Getting the $name $id editions metadata"
                $result = Invoke-UupDumpApi listeditions @{
                    id = $id
                    lang = 'en-us'
                }
                $result.response.editionFancyNames
            } else {
                Write-Host "Skipping. Expected langs=en-us. Got langs=$($langs -join ',')."
                [PSCustomObject]@{}
            }
            $_.Value | Add-Member -NotePropertyMembers @{
                editions = $editions
            }
            $_
        } `
        | Where-Object {
            $ring = $_.Value.info.ring
            $langs = $_.Value.langs.PSObject.Properties.Name
            $editions = $_.Value.editions.PSObject.Properties.Name
            $result = $true
            $expectedRing = if ($target.PSObject.Properties.Name -contains 'ring') {
                $target.ring
            } else {
                'RETAIL'
            }
            if ($ring -ne $expectedRing) {
                Write-Host "Skipping. Expected ring=$expectedRing. Got ring=$ring."
                $result = $false
            }
            if ($langs -notcontains 'en-us') {
                Write-Host "Skipping. Expected langs=en-us. Got langs=$($langs -join ',')."
                $result = $false
            }
            if ($editions -notcontains $target.edition) {
                Write-Host "Skipping. Expected editions=$($target.edition). Got editions=$($editions -join ',')."
                $result = $false
            }
            $result
        } `
        | Select-Object -First 1 `
        | ForEach-Object {
            $id = $_.Value.uuid
            [PSCustomObject]@{
                name = $name
                title = $_.Value.title
                build = $_.Value.build
                id = $id
                edition = $target.edition
                virtualEdition = $target.virtualEdition
                apiUrl = 'https://api.uupdump.net/get.php?' + (New-QueryString @{
                    id = $id
                    lang = 'en-us'
                    edition = $target.edition
                })
                downloadUrl = 'https://uupdump.net/download.php?' + (New-QueryString @{
                    id = $id
                    pack = 'en-us'
                    edition = $target.edition
                })
                downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{
                    id = $id
                    pack = 'en-us'
                    edition = $target.edition
                })
            }
        }
}

function Get-IsoWindowsImages {
    param ([string]$isoPath)
    $isoPath = Resolve-Path $isoPath
    Write-Host "Mounting $isoPath"
    $isoImage = Mount-DiskImage $isoPath -PassThru
    try {
        $isoVolume = $isoImage | Get-Volume
        $installPath = "$($isoVolume.DriveLetter):\sources\install.wim"
        Write-Host "Getting Windows images from $installPath"
        Get-WindowsImage -ImagePath $installPath `
            | ForEach-Object {
                $image = Get-WindowsImage `
                    -ImagePath $installPath `
                    -Index $_.ImageIndex
                $imageVersion = $image.Version
                [PSCustomObject]@{
                    index = $image.ImageIndex
                    name = $image.ImageName
                    version = $imageVersion
                }
            }
    } finally {
        Write-Host "Dismounting $isoPath"
        Dismount-DiskImage $isoPath | Out-Null
    }
}

function Get-WindowsIso {
    param (
        [string]$name,
        [string]$destinationDirectory
    )
    $iso = Get-UupDumpIso $name $TARGETS.$name

    if ($iso.build -notmatch '^\d+\.\d+$') {
        throw "unexpected $name build: $($iso.build)"
    }

    $buildDirectory = "$destinationDirectory/$name"
    $destinationIsoPath = "$buildDirectory.iso"
    $destinationIsoChecksumPath = "$destinationIsoPath.sha256"
    $destinationIsoMetadataPath = "$destinationIsoPath.json"
    if (Test-Path $destinationIsoPath `
            -and Test-Path $destinationIsoChecksumPath `
            -and Test-Path $destinationIsoMetadataPath) {
        Write-Host "$destinationIsoPath already exists"
        return
    }

    if (Test-Path $buildDirectory) {
        Remove-Item -Recurse -Force $buildDirectory
    }
    $null = New-Item -Directory $buildDirectory

    $edition = if ($iso.virtualEdition) {
        $iso.virtualEdition
    } else {
        $iso.edition
    }
    $title = "$name $edition $($iso.build)"

    Write-Host "Downloading the UUP dump download package for $title from $($iso.downloadPackageUrl)"
    $downloadPackageBody = if ($iso.virtualEdition) {
        @{
            autodl = 3
            updates = 1
            cleanup = 1
            'virtualEditions[]' = $iso.virtualEdition
        }
    } else {
        @{
            autodl = 2
            updates = 1
            cleanup = 1
        }
    }
    Invoke-WebRequest `
        -Method Post `
        -Uri $iso.downloadPackageUrl `
        -Body $downloadPackageBody `
        -OutFile "$buildDirectory.zip" `
        | Out-Null
    Expand-Archive "$buildDirectory.zip" $buildDirectory

    $convertConfig = (Get-Content $buildDirectory/ConvertConfig.ini) `
        -replace '^(AutoExit\s*)=.*','$1=1' `
        -replace '^(ResetBase\s*)=.*','$1=1' `
        -replace '^(SkipWinRE\s*)=.*','$1=1'
    if ($iso.virtualEdition) {
        $convertConfig = $convertConfig `
            -replace '^(StartVirtual\s*)=.*','$1=1' `
            -replace '^(vDeleteSource\s*)=.*','$1=1' `
            -replace '^(vAutoEditions\s*)=.*',"`$1=$($iso.virtualEdition)"
    }
    Set-Content `
        -Encoding ascii `
        -Path $buildDirectory/ConvertConfig.ini `
        -Value $convertConfig

    Write-Host "Creating the $title iso file inside the $buildDirectory directory"
    Push-Location $buildDirectory
    powershell cmd /c uup_download_windows.cmd | Out-String -Stream
    if ($LASTEXITCODE) {
        throw "uup_download_windows.cmd failed with exit code $LASTEXITCODE"
    }
    Pop-Location

    $sourceIsoPath = Resolve-Path $buildDirectory/*.iso

    Write-Host "Getting the $sourceIsoPath checksum"
    $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
    Set-Content -Encoding ascii -NoNewline `
        -Path $destinationIsoChecksumPath `
        -Value $isoChecksum

    $windowsImages = Get-IsoWindowsImages $sourceIsoPath

    Set-Content `
        -Path $destinationIsoMetadataPath `
        -Value (
            ([PSCustomObject]@{
                name = $name
                title = $iso.title
                build = $iso.build
                checksum = $isoChecksum
                images = @($windowsImages)
                uupDump = @{
                    id = $iso.id
                    apiUrl = $iso.apiUrl
                    downloadUrl = $iso.downloadUrl
                    downloadPackageUrl = $iso.downloadPackageUrl
                }
            } | ConvertTo-Json -Depth 99) -replace '\\u0026','&'
        )

    Write-Host "Moving the created $sourceIsoPath to $destinationIsoPath"
    Move-Item -Force $sourceIsoPath $destinationIsoPath

    Write-Host 'All Done.'
}

Get-WindowsIso $windowsTargetName $destinationDirectory
