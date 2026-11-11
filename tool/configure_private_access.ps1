param(
    [ValidateRange(1, 65535)][int]$Port = 8090,
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$statusJson = & tailscale status --json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read Tailscale status.' }
$status = $statusJson | ConvertFrom-Json
if ($status.BackendState -ne 'Running') { throw 'Connect this host to Tailscale first.' }
$dnsName = $status.Self.DNSName.TrimEnd('.')
if ([string]::IsNullOrWhiteSpace($dnsName)) { throw 'Enable MagicDNS for this host first.' }
$target = "http://127.0.0.1:$Port"
$configJson = & tailscale serve status --json
if ($LASTEXITCODE -ne 0) { throw 'Unable to read the existing Serve configuration.' }
$config = $configJson | ConvertFrom-Json
if ($config.AllowFunnel) { throw 'Review and disable existing Funnel exposure before configuring private access.' }
if ($config.TCP -and $config.TCP.'443' -and -not $config.TCP.'443'.HTTPS) {
    throw 'Port 443 already has a different Serve configuration.'
}
if ($config.Web) {
    foreach ($web in $config.Web.PSObject.Properties) {
        foreach ($handler in $web.Value.Handlers.PSObject.Properties) {
            if ($web.Name -ne "${dnsName}:443" -or $handler.Name -ne '/' -or $handler.Value.Proxy -ne $target) {
                throw 'An existing Serve handler differs from this application. Review it before changing it.'
            }
        }
    }
}
try {
    $probe = Invoke-WebRequest "$target/health" -UseBasicParsing -TimeoutSec 3
    if ($probe.StatusCode -eq 200) { throw 'The running backend permits anonymous access. Update it before enabling Serve.' }
} catch {
    if ($_.Exception.Message -like '*permits anonymous*') { throw }
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -notin @(401, 503)) { throw }
}
Write-Output "Private URL: https://$dnsName/"
Write-Output "Backend: $target"
if ($Apply) {
    & tailscale serve --bg --https=443 --yes $target
    if ($LASTEXITCODE -ne 0) { throw 'Tailscale Serve configuration failed.' }
    & tailscale serve status
} else {
    Write-Output 'Run with -Apply to enable this private HTTPS endpoint.'
}
