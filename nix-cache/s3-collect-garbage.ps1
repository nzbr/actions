#!/usr/bin/env pwsh
# code: language=powershell tabSize=2

Import-Module AWSPowerShell -ErrorAction Stop

$s3_profile = 'nix-cache'
$endpoint = 'https://s3.eu-central-1.wasabisys.com'
$region = 'eu-central-1'
$bucket = 'nzbr-nix-cache'
$gcrootsDir = 'gcroots'

$hasTTY = ($null -ne $host.UI.RawUI) -and ($env:GITHUB_ACTIONS -ne "true")

$tempfile = New-TemporaryFile

function Get-S3ObjectContent {
  param(
    [string]$Key
  )

  Read-S3Object -BucketName $bucket -Region $region -ProfileName $s3_profile -EndpointUrl $endpoint -Key $Key -File $tempfile.FullName | Out-Null
  return Get-Content $tempfile.FullName
}

function Progress {
  param(
    [string]$Activity,
    [string]$Status,
    [double]$PercentComplete
  )

  if ($hasTTY) {
    Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
  }
  else {
    Write-Host "$Activity [$("{0:0.00}" -f $([math]::round($PercentComplete, 2)))% ($Status)]"
  }
}

# Get all objects as the first step, so we don't delete files that are uploaded while the GC runs
$allItems = @(Get-S3Object -BucketName $bucket -Region $region -ProfileName $s3_profile -EndpointUrl $endpoint | % { $_.Key })

$nars = New-Object System.Collections.Generic.HashSet[string]
$narinfos = New-Object System.Collections.Generic.HashSet[string]
$queue = New-Object System.Collections.Generic.Queue[string]

@(
  Get-S3Object -BucketName $bucket -Region $region -ProfileName $s3_profile -EndpointUrl $endpoint -Prefix $gcrootsDir
  | ? { $_.Size -gt 0 }
  | % { Get-S3ObjectContent $_.Key }
  | % { $_ }
) | ? {
  try {
    Get-S3ObjectMetadata -BucketName $bucket -Region $region -ProfileName $s3_profile -EndpointUrl $endpoint -Key "${_}.narinfo"
    return $true
  }
  catch {
    Write-Error "Could not get metadata for ${_}.narinfo"
    return $false
  }
} | % {
  if (! $narinfos.Contains("${_}.narinfo")) {
    $narinfos.Add("${_}.narinfo")
    $queue.Enqueue($_)
  }
} | Out-Null

Write-Host "> Found $($queue.Count) GC roots"
if (Test-Path env:GITHUB_STEP_SUMMARY) {
  Write-Output "- $($queue.Count) GC roots" >> $env:GITHUB_STEP_SUMMARY
}

$i = 0
while ($queue.Count -gt 0) {
  $i++
  $hash = $queue.Dequeue()

  Progress -Activity "Resolving references" -Status "$i/$($queue.Count)/$($i + $queue.Count)" -PercentComplete ($i / ($i + $queue.Count) * 100)

  try {
    $narinfo = Get-S3ObjectContent "${hash}.narinfo"

    $narinfo | ? { $_ -match '^URL: (.*)$' } | % { $nars.Add($Matches[1]) } | Out-Null

    @(
      $narinfo
      | ? { $_ -match '^References: (.*)$' }
      | % { $Matches[1] -split ' ' | ? { $_ -match '^([a-z0-9]+)-.*' } | % { $Matches[1] } }
      | % { $_ }
    ) | ? { ! $narinfos.Contains("${_}.narinfo") } | % {
      $narinfos.Add("${_}.narinfo")
      $queue.Enqueue($_)
    } | Out-Null
  }
  catch {
    Write-Error $_
    continue
  }

}

Write-Host "> Found $($narinfos.Count) referenced derivations ($(($nars.Count + $narinfos.Count)) objects)"
if (Test-Path env:GITHUB_STEP_SUMMARY) {
  Write-Output "- $($narinfos.Count) referenced derivations" >> $env:GITHUB_STEP_SUMMARY
}

# $allItems is fetched at the start of the script
$relevantItems = @($allItems | ? { $_ -match '^(nar/[a-z0-9]+\.nar.*|[a-z0-9]+\.narinfo)$' })

Write-Host "> Bucket contains $($relevantItems.Count) NARs and NAR infos ($($allItems.Count) total)"

$toDelete = @($relevantItems | ? { ! ($nars.Contains($_) -or $narinfos.Contains($_)) })

Write-Host "> Deleting $($toDelete.Length) objects"

$totalSize = 0
for ($i = 0; $i -lt $toDelete.Count; $i++) {
  Progress -Activity "Deleting objects" -Status "$($i + 1)/$($toDelete.Count)" -PercentComplete ($i / $toDelete.Count * 100)
  $obj = $(Get-S3Object -BucketName $bucket -Region $region -ProfileName $s3_profile -EndpointUrl $endpoint -Key $($toDelete[$i]))
  $totalSize += $obj.Size
  Remove-S3Object -BucketName $bucket -Region $region -ProfileName $s3_profile -EndpointUrl $endpoint -Key $($toDelete[$i]) -Force | Out-Null
}

Write-Host "> Deleted $($toDelete.Length) objects ($($totalSize / 1024d / 1024d) MB)"
if (Test-Path env:GITHUB_STEP_SUMMARY) {
  Write-Output "- Deleted $($toDelete.Length) objects" >> $env:GITHUB_STEP_SUMMARY
  Write-Output "    - $("{0:0.000}" -f ($totalSize / 1024d / 1024d)) MB" >> $env:GITHUB_STEP_SUMMARY
}
