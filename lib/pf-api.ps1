# pf-api.ps1 - minimal PowerShell client for the PayFit API (partner-api)
# Customer API-key authentication. No external dependency. See README.md.

$script:PFBase   = 'https://partner-api.payfit.com'
$script:PFIntro  = 'https://oauth.payfit.com/introspect'
$script:PFTokens = $null
$script:PFCoIds  = @{}
$script:PFLast   = [datetime]::MinValue

# --- Paths and key source ---------------------------------------------------

function PFHome {
    if ($env:PAYFIT_HOME) { return $env:PAYFIT_HOME }
    return (Join-Path $env:USERPROFILE '.payfit')
}

# Two key sources, chosen per user in %USERPROFILE%\.payfit\config.json:
#   "file"     (default, also when config.json is absent): tokens.json, as before.
#   "keyvault" : keys are read at run time from an Azure Key Vault with the
#                user's own Windows sign-in (WAM, silent). Nothing secret on disk.
#                A failure throws: there is NO fallback to tokens.json.
# See config/config.example.json and docs/PITFALLS.md.

function PFConfig {
    if ($script:PFCFG) { return $script:PFCFG }
    $p = Join-Path (PFHome) 'config.json'
    if (Test-Path -LiteralPath $p) {
        $script:PFCFG = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
        $script:PFCFG = [pscustomobject]@{ source = 'file' }
    }
    return $script:PFCFG
}

# Access token for Key Vault, obtained SILENTLY from the Windows account broker
# (WAM) with the signed-in Entra ID account. No password, no client secret.
# Requires an Entra-joined (or registered) Windows device and an app registration
# with the redirect URI ms-appx-web://microsoft.aad.brokerplugin/<clientId>.
# PITFALL: asking by scope returns Success with an EMPTY token; the v1 "resource"
# property is required, and in PowerShell 5.1 it can only be added by reflection.
function PFVaultToken {
    if ($script:PFKVJ -and $script:PFKVJ.Expires -gt (Get-Date).AddMinutes(5)) { return $script:PFKVJ.Token }
    $kv = (PFConfig).keyvault
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTaskG = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $await = { param($op, [type]$t)
        $tk = $asTaskG.MakeGenericMethod($t).Invoke($null, @($op)); $tk.Wait(-1) | Out-Null; $tk.Result }
    $null = [Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager, Windows.Security.Authentication.Web.Core, ContentType = WindowsRuntime]
    $null = [Windows.Security.Authentication.Web.Core.WebTokenRequestResult, Windows.Security.Authentication.Web.Core, ContentType = WindowsRuntime]
    $null = [Windows.Security.Credentials.WebAccountProvider, Windows.Security.Credentials, ContentType = WindowsRuntime]
    $mgr  = [Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager]
    $prov = & $await ($mgr::FindAccountProviderAsync('https://login.microsoft.com', 'organizations')) ([Windows.Security.Credentials.WebAccountProvider])
    $req  = New-Object Windows.Security.Authentication.Web.Core.WebTokenRequest($prov, '', $kv.clientId)
    [void][System.Collections.Generic.IDictionary[string, string]].GetMethod('Add').Invoke($req.Properties, @('resource', 'https://vault.azure.net'))
    $res  = & $await ($mgr::GetTokenSilentlyAsync($req)) ([Windows.Security.Authentication.Web.Core.WebTokenRequestResult])
    if ($res.ResponseStatus -ne 'Success') {
        throw "Key Vault: Windows sign-in refused ($($res.ResponseStatus) $($res.ResponseError.ErrorCode)). Is Windows signed in with your work account?"
    }
    $d = @($res.ResponseData)[0]
    if ([string]::IsNullOrEmpty($d.Token)) { throw 'Key Vault: empty access token (see PITFALLS.md, Key Vault mode).' }
    $script:PFKVJ = @{ Token = $d.Token; Account = $d.WebAccount.UserName; Expires = (Get-Date).AddMinutes(50) }
    return $d.Token
}

# Short user id used in secret names: jane.doe@contoso.com -> janedoe
function PFVaultUser {
    if (-not $script:PFKVJ) { [void](PFVaultToken) }
    return (($script:PFKVJ.Account -split '@')[0] -replace '[^a-zA-Z0-9]', '').ToLower()
}

# Reads ONE secret value. Never log the value it returns.
function PFVaultSecret {
    param([Parameter(Mandatory)][string]$VaultUrl, [Parameter(Mandatory)][string]$Name)
    $h = @{ Authorization = 'Bearer ' + (PFVaultToken) }
    try { return (Invoke-RestMethod -Uri "$($VaultUrl.TrimEnd('/'))/secrets/$($Name)?api-version=7.4" -Headers $h).value }
    catch { throw "Key Vault: secret '$Name' not readable ($($_.Exception.Response.StatusCode)). Missing 'Key Vault Secrets User' role on it?" }
}

# Declared companies in keyvault mode (config.json), without any network call.
function PFConfigEntites {
    $cfg = PFConfig
    if (-not $cfg.entites) { throw "Key Vault: no 'entites' in $(Join-Path (PFHome) 'config.json')." }
    @($cfg.entites.PSObject.Properties | Where-Object { $_.Name -notlike '_*' })
}

# Same shape in both modes: a flat object {<slug>: "<key>"}, so PFToken, PFHdr and
# the skills do not care where the keys came from. Vault keys stay in memory.
function PFTokensLoad {
    if ($script:PFTokens) { return $script:PFTokens }
    $cfg = PFConfig
    if ($cfg.source -eq 'keyvault') {
        $kv = $cfg.keyvault
        if (-not $kv -or -not $kv.vaultUrl -or -not $kv.clientId) {
            throw "Key Vault: 'keyvault.vaultUrl' and 'keyvault.clientId' are required in config.json."
        }
        $pat = if ($kv.secretName) { $kv.secretName } else { 'payfit-token-{company}-{user}' }
        $usr = PFVaultUser
        $o = [ordered]@{}
        foreach ($p in (PFConfigEntites)) {
            if ($p.Value.api -eq $false) { continue }
            $n = $pat.Replace('{company}', $p.Name).Replace('{user}', $usr)
            $o[$p.Name] = PFVaultSecret -VaultUrl $kv.vaultUrl -Name $n
        }
        $script:PFTokens = [pscustomobject]$o
        return $script:PFTokens
    }
    $p = Join-Path (PFHome) 'tokens.json'
    if (-not (Test-Path $p)) {
        throw "tokens.json not found ($p). See README.md"
    }
    $script:PFTokens = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    return $script:PFTokens
}

function PFEntites {
    if ((PFConfig).source -eq 'keyvault') { return @((PFConfigEntites).Name) }
    # Les cles commencant par _ sont des commentaires du fichier, pas des entites.
    (PFTokensLoad).PSObject.Properties.Name | Where-Object { $_ -notlike '_*' }
}

function PFToken {
    param([Parameter(Mandatory)][string]$e)
    $cfg = PFConfig
    if ($cfg.source -eq 'keyvault' -and $cfg.entites -and $cfg.entites.PSObject.Properties[$e] -and $cfg.entites.$e.api -eq $false) {
        throw "Entity '$e' is declared with api=false in config.json: no key to use."
    }
    $t = PFTokensLoad
    if (-not $t.PSObject.Properties.Name.Contains($e)) {
        throw "Entite inconnue : '$e'. Connues : $((PFEntites) -join ', ')"
    }
    $t.$e
}

function PFHdr {
    param([Parameter(Mandatory)][string]$e)
    @{ 'Authorization' = 'Bearer ' + (PFToken $e); 'Accept' = 'application/json' }
}

# Lectures 50 req/s, ecritures 20 req/s. On se tient volontairement bas.
function PFThrottle {
    param([int]$ms = 120)
    $d = (Get-Date) - $script:PFLast
    if ($d.TotalMilliseconds -lt $ms) {
        Start-Sleep -Milliseconds ([int]($ms - $d.TotalMilliseconds))
    }
    $script:PFLast = Get-Date
}

function PFIntrospect {
    param([Parameter(Mandatory)][string]$e)
    PFThrottle
    # /introspect exige la cle DEUX fois : en en-tete Bearer ET dans le corps
    # (parametre `token`, RFC 7662). Le Bearer seul renvoie 400, le corps seul 401.
    # La doc PayFit ne le precise pas.
    $k = PFToken $e
    Invoke-RestMethod -Uri $script:PFIntro -Method Post `
        -Headers @{ 'Authorization' = "Bearer $k" } `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ token = $k }
}

function PFCompanyId {
    param([Parameter(Mandatory)][string]$e)
    if ($script:PFCoIds.ContainsKey($e)) { return $script:PFCoIds[$e] }
    $r = PFIntrospect $e
    $id = $r.company_id
    if (-not $id) { throw "introspect n'a pas renvoye company_id pour '$e'" }
    $script:PFCoIds[$e] = $id
    return $id
}

function PFMe {
    param([Parameter(Mandatory)][string]$e)
    PFIntrospect $e
}

function PFUrl {
    param([string]$e, [string]$path)
    # $path peut contenir {companyId}, sinon il est prefixe par /companies/<id>
    $id = PFCompanyId $e
    if ($path -match '\{companyId\}') { $p = $path -replace '\{companyId\}', $id }
    elseif ($path -like '/companies/*') { $p = $path }
    else { $p = '/companies/' + $id + '/' + $path.TrimStart('/') }
    $script:PFBase + $p
}

function PFQS {
    param([hashtable]$q)
    if (-not $q -or $q.Count -eq 0) { return '' }
    $parts = @()
    foreach ($k in $q.Keys) {
        if ($null -eq $q[$k] -or $q[$k] -eq '') { continue }
        $parts += ('{0}={1}' -f [uri]::EscapeDataString($k), [uri]::EscapeDataString([string]$q[$k]))
    }
    if ($parts.Count -eq 0) { return '' }
    '?' + ($parts -join '&')
}

function PFGet {
    param(
        [Parameter(Mandatory)][string]$e,
        [Parameter(Mandatory)][string]$path,
        [hashtable]$query
    )
    $u = (PFUrl $e $path) + (PFQS $query)
    for ($try = 1; $try -le 5; $try++) {
        PFThrottle
        try { return Invoke-RestMethod -Uri $u -Headers (PFHdr $e) -Method Get }
        catch {
            $code = 0
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
            # 429/500/503 seuls sont reessayables. 400/401/403/404 : corriger la requete.
            if ($code -in 429,500,503 -and $try -lt 5) {
                Start-Sleep -Seconds ([math]::Pow(2, $try))
                continue
            }
            throw
        }
    }
}

# Pagination PayFit : ?maxResults=50&nextPageToken=... ; la reponse porte
# nextPageToken tant qu'il reste des pages. maxResults plafonne a 50.
function PFGetAll {
    param(
        [Parameter(Mandatory)][string]$e,
        [Parameter(Mandatory)][string]$path,
        [hashtable]$query,
        [int]$maxPages = 100
    )
    $out = @()
    $q = @{}
    if ($query) { foreach ($k in $query.Keys) { $q[$k] = $query[$k] } }
    if (-not $q.ContainsKey('maxResults')) { $q['maxResults'] = 50 }
    $page = 0
    do {
        $r = PFGet $e $path $q
        $items = $null
        foreach ($n in 'collaborators','contracts','absences','items','data','results','payslips') {
            if ($r.PSObject.Properties.Name -contains $n) { $items = $r.$n; break }
        }
        if ($null -eq $items) { $items = $r }
        $out += $items
        $tok = $null
        if ($r.PSObject.Properties.Name -contains 'nextPageToken') { $tok = $r.nextPageToken }
        $q['nextPageToken'] = $tok
        $page++
    } while ($tok -and $page -lt $maxPages)
    return $out
}

