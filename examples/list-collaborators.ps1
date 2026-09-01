# List every collaborator with their contract dates.
#   .\examples\list-collaborators.ps1 -Company my-company

param([Parameter(Mandatory)][string]$Company)

. (Join-Path $PSScriptRoot '..\lib\pf-api.ps1')

$people    = PFGetAll $Company 'collaborators'
$contracts = PFGetAll $Company 'contracts'

$byCollab = @{}
foreach ($c in $contracts) { $byCollab[$c.collaboratorId] = $c }

$people | ForEach-Object {
    $c = $byCollab[$_.id]
    [pscustomobject]@{
        Name      = '{0} {1}' -f $_.firstName, $_.lastName
        Id        = $_.id
        StartDate = if ($c) { $c.startDate } else { $null }
        EndDate   = if ($c) { $c.endDate }   else { $null }
    }
} | Sort-Object Name | Format-Table -AutoSize
