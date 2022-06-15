#!/usr/bin/pwsh
param(
    [string]$windowsTargetName,
    [string]$destinationDirectory='output'
)

$TARGETS = @{
    }
    # see https://en.wikipedia.org/wiki/Windows_11
    # see https://en.wikipedia.org/wiki/Windows_11_version_history
    "windows-11" = @{
        search = "cumulative update windows 11 22621.1 amd64" # aka 22H2. Cloud EOL: October 8, 2024.
        editions = @("Cloud")

        } `
        | ForEach-Object {
            # get more information about the build. eg:
            #   "langs": {
            #     "en-us": "English (United States)",
            #     "pt-pt": "Portuguese (Portugal)",
            #     ...
            #   },
            #   "info": {
            #     "title": "Feature update to Microsoft server operating system, version 21H2 (20348.643)",
            #     "ring": "Core",
            #     "flight": "Active",
            #     "arch": "amd64",
            #     "build": "22621.1",
            #     "checkBuild": "10.0.22621.1",
            #     "sku": 8,
            #     "created": 1649783041,
            #     "sha256ready": true
            #   }
            $id = $_.Value.uuid
            Write-Host "Getting the $name $id langs metadata"
            $result = Invoke-RestMethod `
                -Method Get `
                -Uri 'https://api.uupdump.net/listlangs.php' `
                -Body @{
                    id = $id
                }
            if ($result.response.updateInfo.build -ne $_.Value.build) {
                throw 'for some reason listlangs returned an unexpected build'
            }
            $_.Value | Add-Member -NotePropertyMembers @{
                langs = $result.response.langFancyNames
                info = $result.response.updateInfo
            }
            $editions = if ($_.Value.langs.PSObject.Properties.Name -eq 'en-us') {
                Write-Host "Getting the $name $id editions metadata"
                $result = Invoke-RestMethod `
                    -Method Get `
                    -Uri 'https://api.uupdump.net/listeditions.php' `
                    -Body @{
                        id = $id
                        lang = 'en-us'
                    }
                $result.response.editionFancyNames
            } else {
                [PSCustomObject]@{}
            }
            $_.Value | Add-Member -NotePropertyMembers @{
                editions = $editions
            }
            $_
        } `
        | Where-Object {
            # only return builds that:
            #   1. are from the retail channel
            #   2. have the english language
            #   3. match all the requested editions
            $_.Value.info.ring -eq 'RETAIL' `
                -and $_.Value.langs.PSObject.Properties.Name -eq 'en-us' `
                -and (Compare-object -ExcludeDifferent $target.editions $_.Value.editions.PSObject.Properties.Name).Length -eq $target.editions.Length
        } `
        | Select-Object -First 1 `
        | ForEach-Object {
            $id = $_.Value.uuid
            [PSCustomObject]@{
                name = $name
                title = $_.Value.title
                build = $_.Value.build
                id = $id
                apiUrl = 'https://api.uupdump.net/get.php?' + (New-QueryString @{
                    id = $id
                    lang = 'en-us'
                    edition = $target.editions -join ';'
                    #noLinks = '1' # do not return the files download urls.
                })
                downloadUrl = 'https://uupdump.net/download.php?' + (New-QueryString @{
                    id = $id
                    pack = 'en-us'
                    edition = $target.editions -join ';'
                })
                # NB you must use the HTTP POST method to invoke this packageUrl
                #    AND in the body you must include autodl=2 updates=1 cleanup=1.
                downloadPackageUrl = 'https://uupdump.net/get.php?' + (New-QueryString @{
                    id = $id
                    pack = 'en-us'
                    edition = $target.editions -join ';'
                })
            }
        }
}

function Get-IsoWindowsImages($isoPath) {
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

function Get-WindowsIso($name, $destinationDirectory) {
    $iso = Get-UupDumpIso $name $TARGETS.$name

    # ensure the build is a version number.
    if ($iso.build -notmatch '^\d+\.\d+$') {
        throw "unexpected $name build: $($iso.build)"
    }

    $buildDirectory = "$destinationDirectory/$name-$($iso.build)"
    $destinationBuildMetadataPath = "*.json"
    $destinationIsoPath = "$*.iso"
    $destinationIsoChecksumPath = "$destinationIsoPath.sha256.txt"

    # create the build directory.
    if (Test-Path $buildDirectory) {
        Remove-Item -Force -Recurse $buildDirectory | Out-Null
    }
    New-Item -ItemType Directory -Force $buildDirectory | Out-Null

    Write-Host "Downloading the UUP dump download package"
    Invoke-WebRequest `
        -Method Post `
        -Uri $iso.downloadPackageUrl `
        -Body @{
            autodl = 2
            updates = 1
            cleanup = 1
            #'virtualEditions[0]' = 'Enterprise' # TODO this seems to be the default, so maybe we do not really need it.
        } `
        -OutFile "$buildDirectory.zip" `
        | Out-Null
    Expand-Archive "$buildDirectory.zip" $buildDirectory
    Set-Content `
        -Encoding ascii `
        -Path $buildDirectory/ConvertConfig.ini `
        -Value (
            (Get-Content $buildDirectory/ConvertConfig.ini) `
                -replace '^(AutoExit\s*)=.*','$1=1' `
                -replace '^(ResetBase\s*)=.*','$1=1' `
                -replace '^(SkipWinRE\s*)=.*','$1=1'
        )

    Write-Host "Creating the $name iso file"
    Push-Location $buildDirectory
    cmd /c uup_download_windows.cmd
    Pop-Location

    $sourceIsoPath = Resolve-Path $buildDirectory/*.iso

    Write-Host "Getting the $sourceIsoPath checksum"
    $isoChecksum = (Get-FileHash -Algorithm SHA256 $sourceIsoPath).Hash.ToLowerInvariant()
    Set-Content -Encoding ascii -NoNewline `
        -Path $destinationIsoChecksumPath `
        -Value $isoChecksum

    $windowsImages = Get-IsoWindowsImages $sourceIsoPath

    # create the iso metadata file.
    Set-Content `
        -Path $destinationBuildMetadataPath `
        -Value (
            [PSCustomObject]@{
                name = $name
                title = $iso.title
                build = $iso.build
                checksum = $isoChecksum
                images = $windowsImages
                uupDump = @{
                    id = $iso.id
                    apiUrl = $iso.apiUrl
                    downloadUrl = $iso.downloadUrl
                    downloadPackageUrl = $iso.downloadPackageUrl
                }
            } | ConvertTo-Json -Depth 99
        )

    Write-Host "Moving the created $sourceIsoPath to $destinationIsoPath"
    Move-Item $sourceIsoPath $destinationIsoPath

    Write-Host 'Destination directory contents:'
    Get-ChildItem $destinationDirectory `
        | Where-Object { -not $_.PsIsContainer } `
        | Sort-Object FullName `
        | Select-Object FullName,Size

    Write-Host 'All Done.'
}

