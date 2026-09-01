# Absence timeline, sorted, with a gap check.
# Useful to spot a missing renewal in a chain of sick-leave certificates:
# an uncovered working day between two absences is easy to create and hard
# to notice, and it can undo a waiting-period calculation.
#
#   .\examples\absence-timeline.ps1 -Company my-company

param([Parameter(Mandatory)][string]$Company)

. (Join-Path $PSScriptRoot '..\lib\pf-api.ps1')

$abs = PFGetAll $Company 'absences' |
    ForEach-Object {
        [pscustomobject]@{
            Start  = [datetime]$_.startDate.date
            End    = [datetime]$_.endDate.date
            Type   = $_.type
            Status = $_.status
        }
    } | Sort-Object Start

$abs | Format-Table -AutoSize

$prev = $null
foreach ($a in $abs) {
    if ($prev -and $a.Start -gt $prev.End.AddDays(1)) {
        $gapStart = $prev.End.AddDays(1)
        $gapEnd   = $a.Start.AddDays(-1)
        $days     = ($gapEnd - $gapStart).Days + 1
        Write-Warning ('Gap of {0} day(s): {1:yyyy-MM-dd} to {2:yyyy-MM-dd}' -f $days, $gapStart, $gapEnd)
    }
    if (-not $prev -or $a.End -gt $prev.End) { $prev = $a }
}
