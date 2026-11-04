# Offline tests for the key sources of lib/pf-api.ps1 (file and Key Vault).
# No network, no Windows broker: the vault reads are replaced by fakes.
# Run:  pwsh -NoProfile -File tests/keyvault-source.tests.ps1   (exit code 1 on failure)
$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot '..\lib\pf-api.ps1'
. $lib

$script:fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "PASS  $name" } else { Write-Host "FAIL  $name"; $script:fail++ }
}
function Reset { $script:PFTokens = $null; $script:PFCFG = $null; $script:PFKVJ = $null; $script:calls = @() }

# Obviously fictitious values only.
$work = Join-Path ([IO.Path]::GetTempPath()) ('pf-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $work | Out-Null
$env:PAYFIT_HOME = $work

try {
    # --- 1. File mode, no config.json: behaviour unchanged ----------------------
    Reset
    '{ "_comment": "x", "company-a": "FAKE-KEY-A-NOT-A-SECRET", "company-b": "FAKE-KEY-B-NOT-A-SECRET" }' |
        Set-Content -LiteralPath (Join-Path $work 'tokens.json') -Encoding UTF8
    function PFVaultUser { throw 'vault must not be touched in file mode' }
    function PFVaultSecret { throw 'vault must not be touched in file mode' }
    Check 'file: entities skip _comment keys' ((PFEntites) -join ',' -eq 'company-a,company-b')
    Check 'file: PFToken returns the key' ((PFToken 'company-b') -eq 'FAKE-KEY-B-NOT-A-SECRET')
    Check 'file: PFHdr is a Bearer header' ((PFHdr 'company-a').Authorization -eq 'Bearer FAKE-KEY-A-NOT-A-SECRET')
    $threw = $false; try { PFToken 'nope' } catch { $threw = $true }
    Check 'file: unknown entity throws' $threw

    # --- 2. Key Vault mode: flat object rebuilt, entities from config.json ------
    Reset
    @'
{ "source": "keyvault",
  "keyvault": { "vaultUrl": "https://example-vault.invalid/", "clientId": "00000000-0000-0000-0000-000000000000" },
  "entites": { "_comment": "ignored", "company-a": { "label": "A" }, "company-b": { "label": "B" },
               "no-api": { "label": "N", "api": false } } }
'@ | Set-Content -LiteralPath (Join-Path $work 'config.json') -Encoding UTF8
    function PFVaultUser { 'janedoe' }
    function PFVaultSecret {
        param($VaultUrl, $Name)
        $script:calls += "$VaultUrl|$Name"
        return 'FAKE-KV-' + $Name
    }
    Check 'vault: entities come from config.json, no secret read' (((PFEntites) -join ',' -eq 'company-a,company-b,no-api') -and $script:calls.Count -eq 0)
    $t = PFTokensLoad
    Check 'vault: flat object {slug: key}' ($t.'company-a' -eq 'FAKE-KV-payfit-token-company-a-janedoe' -and $t.'company-b' -eq 'FAKE-KV-payfit-token-company-b-janedoe')
    Check 'vault: api=false entity is not fetched' ($script:calls.Count -eq 2 -and -not ($t.PSObject.Properties.Name -contains 'no-api'))
    Check 'vault: PFToken / PFHdr unchanged' ((PFHdr 'company-b').Authorization -eq 'Bearer FAKE-KV-payfit-token-company-b-janedoe')
    $threw = $false; try { PFToken 'no-api' } catch { $threw = $_.Exception.Message -like '*api=false*' }
    Check 'vault: api=false entity gives an explicit error' $threw

    # --- 3. Failure in vault mode throws, no fallback to tokens.json ------------
    Reset
    function PFVaultSecret { param($VaultUrl, $Name) throw "Key Vault: secret '$Name' not readable (Forbidden)." }
    $msg = $null; try { [void](PFToken 'company-a') } catch { $msg = $_.Exception.Message }
    Check 'vault failure: throws a "Key Vault:" error' ($msg -like 'Key Vault:*')
    Check 'vault failure: tokens.json (present) is NOT used as fallback' ($null -eq $script:PFTokens)
}
finally {
    Remove-Item Env:PAYFIT_HOME -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($script:fail) { Write-Host "$script:fail check(s) failed"; exit 1 }
Write-Host 'All checks passed'
