function ConvertTo-ItoHtmlText {
    <#
    .SYNOPSIS
        HTML-encodes any value. Every value that reaches the report goes through here, because
        event messages and service names are not trusted input.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($null -eq $Value) {
        return ''
    }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-ItoHealthHtml {
    <#
    .SYNOPSIS
        Renders a health report object as a self-contained HTML page (no scripts, no external files).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [object] $Report
    )

    $css = @'
body { font-family: "Segoe UI", system-ui, sans-serif; margin: 2rem; color: #1f2328; background: #ffffff; }
h1 { font-size: 1.5rem; margin-bottom: 0.25rem; }
h2 { font-size: 1.15rem; margin-top: 2rem; }
p.meta { color: #57606a; margin-top: 0; }
table { border-collapse: collapse; width: 100%; margin-top: 0.75rem; }
th, td { border: 1px solid #d0d7de; padding: 0.45rem 0.6rem; text-align: left; vertical-align: top; font-size: 0.92rem; }
th { background: #f6f8fa; }
.status { display: inline-block; min-width: 5.5rem; padding: 0.1rem 0.5rem; border-radius: 0.3rem; font-weight: 600; text-align: center; }
.status-OK { background: #dafbe1; color: #116329; }
.status-Warning { background: #fff8c5; color: #7d4e00; }
.status-Critical { background: #ffebe9; color: #a40e26; }
.status-Unknown { background: #eaeef2; color: #424a53; }
.overall { font-size: 1.05rem; }
footer { margin-top: 2rem; color: #57606a; font-size: 0.85rem; }
'@

    $builder = New-Object -TypeName System.Text.StringBuilder
    $computer = ConvertTo-ItoHtmlText $Report.ComputerName
    [void]$builder.AppendLine('<!DOCTYPE html>')
    [void]$builder.AppendLine('<html lang="en">')
    [void]$builder.AppendLine('<head>')
    [void]$builder.AppendLine('<meta charset="utf-8">')
    [void]$builder.AppendLine('<meta name="viewport" content="width=device-width, initial-scale=1">')
    [void]$builder.AppendLine(('<title>Health report: {0}</title>' -f $computer))
    [void]$builder.AppendLine('<style>')
    [void]$builder.Append($css)
    [void]$builder.AppendLine('</style>')
    [void]$builder.AppendLine('</head>')
    [void]$builder.AppendLine('<body>')
    [void]$builder.AppendLine(('<h1>Health report: {0}</h1>' -f $computer))
    [void]$builder.AppendLine(('<p class="meta">Generated {0} (UTC) by ItOpsToolkit {1}. Events window: last {2} hours.</p>' -f (ConvertTo-ItoHtmlText $Report.GeneratedAtUtc), (ConvertTo-ItoHtmlText $Report.ToolkitVersion), (ConvertTo-ItoHtmlText $Report.EventWindowHours)))
    [void]$builder.AppendLine(('<p class="overall">Overall status: <span class="status status-{0}">{0}</span></p>' -f (ConvertTo-ItoHtmlText $Report.OverallStatus)))

    [void]$builder.AppendLine('<table>')
    [void]$builder.AppendLine('<thead><tr><th scope="col">Check</th><th scope="col">Status</th><th scope="col">Value</th><th scope="col">Threshold</th><th scope="col">What to do</th></tr></thead>')
    [void]$builder.AppendLine('<tbody>')
    foreach ($check in $Report.Checks) {
        [void]$builder.AppendLine(('<tr><td>{0}</td><td><span class="status status-{1}">{1}</span></td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f
                (ConvertTo-ItoHtmlText $check.Name), (ConvertTo-ItoHtmlText $check.Status), (ConvertTo-ItoHtmlText $check.Value),
                (ConvertTo-ItoHtmlText $check.Threshold), (ConvertTo-ItoHtmlText $check.Detail)))
    }
    [void]$builder.AppendLine('</tbody>')
    [void]$builder.AppendLine('</table>')

    $eventCheck = @($Report.Checks | Where-Object { $_.Name -eq 'Critical events' })
    if ($eventCheck.Count -gt 0 -and $null -ne $eventCheck[0].Data -and @($eventCheck[0].Data).Count -gt 0) {
        [void]$builder.AppendLine('<h2>Critical events</h2>')
        [void]$builder.AppendLine('<table>')
        [void]$builder.AppendLine('<thead><tr><th scope="col">Time</th><th scope="col">Log</th><th scope="col">Source</th><th scope="col">Event ID</th><th scope="col">Message</th></tr></thead>')
        [void]$builder.AppendLine('<tbody>')
        foreach ($entry in @($eventCheck[0].Data)) {
            [void]$builder.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f
                    (ConvertTo-ItoHtmlText $entry.TimeCreated), (ConvertTo-ItoHtmlText $entry.LogName), (ConvertTo-ItoHtmlText $entry.ProviderName),
                    (ConvertTo-ItoHtmlText $entry.Id), (ConvertTo-ItoHtmlText $entry.Message)))
        }
        [void]$builder.AppendLine('</tbody>')
        [void]$builder.AppendLine('</table>')
    }

    $serviceCheck = @($Report.Checks | Where-Object { $_.Name -eq 'Automatic services' })
    if ($serviceCheck.Count -gt 0 -and $null -ne $serviceCheck[0].Data -and @($serviceCheck[0].Data).Count -gt 0) {
        [void]$builder.AppendLine('<h2>Stopped automatic services</h2>')
        [void]$builder.AppendLine('<table>')
        [void]$builder.AppendLine('<thead><tr><th scope="col">Name</th><th scope="col">Display name</th><th scope="col">State</th><th scope="col">Exit code</th><th scope="col">Counted</th></tr></thead>')
        [void]$builder.AppendLine('<tbody>')
        $counted = @{
            Failed              = 'Yes: stopped with an error or never started'
            StoppedCleanly      = 'No: stopped cleanly, for information'
            DelayedStartPending = 'Not yet: delayed start, soon after boot'
        }
        foreach ($service in @($serviceCheck[0].Data)) {
            [void]$builder.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f
                    (ConvertTo-ItoHtmlText $service.Name), (ConvertTo-ItoHtmlText $service.DisplayName), (ConvertTo-ItoHtmlText $service.State),
                    (ConvertTo-ItoHtmlText $service.ExitCode), (ConvertTo-ItoHtmlText $counted[[string]$service.Reason])))
        }
        [void]$builder.AppendLine('</tbody>')
        [void]$builder.AppendLine('</table>')
    }

    [void]$builder.AppendLine('<h2>How to read this report</h2>')
    [void]$builder.AppendLine('<p>OK means within the threshold. Warning means someone should look at it this week. Critical means act now. Unknown means the check could not run; the reason is in the last column.</p>')
    [void]$builder.AppendLine('<footer>Thresholds can be changed with a JSON file passed to Get-ItoHealthReport -ThresholdPath.</footer>')
    [void]$builder.AppendLine('</body>')
    [void]$builder.AppendLine('</html>')
    $builder.ToString()
}
