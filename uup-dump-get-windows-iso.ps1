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

