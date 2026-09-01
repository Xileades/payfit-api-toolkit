# pf-api.ps1 - minimal PowerShell client for the PayFit API (partner-api)
# Customer API-key authentication. No external dependency. See README.md.

$script:PFBase   = 'https://partner-api.payfit.com'
$script:PFIntro  = 'https://oauth.payfit.com/introspect'
$script:PFTokens = $null
$script:PFCoIds  = @{}
$script:PFLast   = [datetime]::MinValue

function PFTokensLoad {
    if ($script:PFTokens) { return $script:PFTokens }
    $p = Join-Path $env:USERPROFILE '.payfit\tokens.json'
    if (-not (Test-Path $p)) {
        throw "tokens.json not found ($p). See README.md"
    }
    $script:PFTokens = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
    return $script:PFTokens
}

function PFEntites {
    # Les cles commencant par _ sont des commentaires du fichier, pas des entites.
    (PFTokensLoad).PSObject.Properties.Name | Where-Object { $_ -notlike '_*' }
}

function PFToken {
    param([Parameter(Mandatory)][string]$e)
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

