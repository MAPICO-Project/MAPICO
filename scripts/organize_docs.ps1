$ErrorActionPreference = 'Stop'
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$docsRoot = Join-Path $workspaceRoot 'docs'
$historyRoot = Join-Path $workspaceRoot 'references\history'
$worklogRoot = Join-Path $workspaceRoot 'worklogs\history'
$decisionRoot = Join-Path $workspaceRoot 'records\decisions'
foreach ($targetRoot in @($historyRoot,$worklogRoot,$decisionRoot)) {
  if (-not ([IO.Path]::GetFullPath($targetRoot)).StartsWith($workspaceRoot + '\')) { throw 'Unsafe destination' }
  New-Item -ItemType Directory -Force -Path $targetRoot | Out-Null
}
foreach ($file in Get-ChildItem -LiteralPath $docsRoot -File -Filter '*.md') {
  if ($file.Name -eq 'README.md') { continue }
  $destinationRoot = $historyRoot
  if ($file.Name -eq 'DECISIONS.md') { $destinationRoot = $decisionRoot }
  elseif ($file.Name -match 'REVIEW|FEEDBACK|WORK_SUMMARY|CLAUDE_REVIEW|PRD_DELTA|PARALLEL_EXECUTION') { $destinationRoot = $worklogRoot }
  $destination = Join-Path $destinationRoot $file.Name
  if (Test-Path -LiteralPath $destination) { throw "Destination exists: $destination" }
  Move-Item -LiteralPath $file.FullName -Destination $destination
  Write-Output ('Moved ' + $file.Name + ' -> ' + $destinationRoot)
}
