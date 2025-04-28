#!/usr/bin/env pwsh
# code: language=powershell tabSize=2

Import-Module AWSPowerShell -ErrorAction Stop

$s3_profile = 'nix-cache'
$endpoint = 'https://s3.eu-central-1.wasabisys.com'
$region = 'eu-central-1'
$bucket = 'nzbr-nix-cache'

$tempfile = New-TemporaryFile

Write-Output @"
StoreDir: /nix/store
WantMassQuery: 1
Priority: 10
"@ > $tempfile.FullName
Write-S3Object -BucketName $bucket -Region $region -ProfileName $s3_profile -EndpointUrl $endpoint -Key "nix-cache-info" -File $tempfile.FullName | Out-Null

Write-Host "Wrote nix-cache-info with the following content:"
Get-Content $tempfile.FullName | Out-Host

Remove-Item $tempfile.FullName | Out-Null
