$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'qlik_deploy_olh_gui.ps1'),
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count -eq 0) {
    Write-Host "OK: 0 parse errors"
} else {
    Write-Host "ERRORS: $($errors.Count)"
    foreach ($e in $errors) { Write-Host "  $($e.Extent.StartLineNumber): $($e.Message)" }
}
