# Windows activation: read the status and, when Windows is not activated,
# install the MAK key from config.json ("WindowsProductKey") and activate
# online. The key is never printed, logged or uploaded.

function Get-WindowsActivationStatus {
    # ApplicationID is the fixed "Windows" ID; it leaves out Office etc.
    $names = @{ 0 = 'Unlicensed'; 1 = 'Licensed'; 2 = 'OOB Grace'; 3 = 'OOT Grace'; 4 = 'Non-Genuine Grace'; 5 = 'Notification'; 6 = 'Extended Grace' }
    try {
        $product = Get-CimInstance SoftwareLicensingProduct -ErrorAction Stop `
            -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
            Select-Object -First 1
        if ($product -and $names[[int]$product.LicenseStatus]) { return $names[[int]$product.LicenseStatus] }
    } catch {}
    return 'Unknown - verify manually (run slmgr /xpr)'
}

function Invoke-Slmgr {
    param([string[]]$Arguments)
    return (& cscript.exe //NoLogo (Join-Path $env:windir 'System32\slmgr.vbs') @Arguments 2>&1 | Out-String)
}

# slmgr's text is translated on non-English Windows; its error code is not.
function Get-SlmgrErrorCode {
    param([string]$Output)
    $m = [regex]::Match($Output, '0x[0-9A-Fa-f]{8}')
    if ($m.Success) { return '0x' + $m.Value.Substring(2).ToUpper() }
    return ''
}

# Returns @{ status = <license status after>; action = <what was done> }.
function Invoke-WindowsActivation {
    param([string]$CurrentStatus, [string]$ProductKey)

    if ($CurrentStatus -eq 'Licensed') { return @{ status = $CurrentStatus; action = 'Already activated' } }
    if (-not $ProductKey) { return @{ status = $CurrentStatus; action = 'Not activated - no WindowsProductKey in config.json' } }

    Write-Host "  Activating Windows ..." -ForegroundColor Cyan
    $ipk = Invoke-Slmgr @('/ipk', $ProductKey)
    if (Get-Command Write-DetailLog -ErrorAction SilentlyContinue) { Write-DetailLog ("slmgr /ipk: " + $ipk.Replace($ProductKey, '*****').Trim()) }
    $ipkError = Get-SlmgrErrorCode $ipk
    if ($ipkError) {
        return @{ status = (Get-WindowsActivationStatus); action = "Activation failed - key not accepted ($ipkError)" }
    }

    $ato = Invoke-Slmgr @('/ato')
    if (Get-Command Write-DetailLog -ErrorAction SilentlyContinue) { Write-DetailLog ("slmgr /ato: " + $ato.Trim()) }
    $after = Get-WindowsActivationStatus
    if ($after -eq 'Licensed') { return @{ status = $after; action = 'Activated now' } }

    $code = Get-SlmgrErrorCode $ato
    return @{ status = $after; action = 'Activation failed' + $(if ($code) { " ($code)" } else { '' }) }
}
