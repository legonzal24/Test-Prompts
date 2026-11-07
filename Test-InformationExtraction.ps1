#requires -Version 5.1
<#
.SYNOPSIS
Benchmarks five information extraction prompts against five local Ollama models.
.DESCRIPTION
Windows PowerShell 5.1 or PowerShell 7 on Windows. No administrator rights,
external modules, Python, or Ollama CLI parsing are required. Ollama must be
running and all requested models must already be downloaded.

Requests run sequentially. An independent PowerShell runspace performs HTTP
requests while the main thread samples total system CPU and physical RAM.
HTTP timing is measured inside that worker, independently of sampling delays.

Each prompt is a fresh request: previous answers/context are never passed back.
Preloading is timed separately; prompt results therefore describe warm loads,
not cold starts. There is no additional unscored generation warm-up.

CPU percentages use deltas of Windows raw processor counters (all logical CPUs,
normalized 0-100). RAM is (visible physical RAM - free physical RAM) / total.
Both include Windows, other apps, Ollama, and this measurement script. They do
not represent Ollama-only usage. Peaks are sampled peaks, not continuous maxima.

Default output cap is 2048 tokens; answers hitting it are marked Truncated.
Use -NumPredict -1 for no explicit output token cap (timeout still applies).
The complete returned text and JSON are saved, including any thinking field.
No thinking override is sent: installed model defaults apply and are captured
in model-info.json. Check these before interpreting cross-model comparisons.

Output: one new timestamped directory, measurements.csv (one row per prompt),
resource-samples.csv, run-info.json, model metadata, requests, text and JSON.
CSV rows are appended after each prompt, so earlier results survive later errors.
Do not run other inference clients during this benchmark.
.EXAMPLE
.\Test-InformationExtraction.ps1
.EXAMPLE
.\Test-InformationExtraction.ps1 -OutputDirectory C:\LLM-Benchmark -NumPredict -1
#>
[CmdletBinding()]
param(
    [string[]]$Models = @('gemma4:e4b', 'gemma4:e2b', 'llama3.2:3b', 'llama3.2:1b', 'phi4-mini:3.8b'),
    [ValidateRange(1024, 131072)][int]$ContextWindow = 4096,
    [ValidateScript({ $_ -eq -1 -or $_ -gt 0 })][int]$NumPredict = 2048,
    [ValidateRange(250, 10000)][int]$SampleIntervalMs = 1000,
    [ValidateRange(30, 86400)][int]$RequestTimeoutSeconds = 1800,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'BenchmarkResults')
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Run this script on the Windows test laptop.' }
if ($Models.Count -eq 0) { throw 'At least one model is required.' }
$BaseUrl = 'http://127.0.0.1:11434'
$Utf8 = New-Object System.Text.UTF8Encoding($false)

# These are the five information extraction prompts. Expected answers are not sent.
$Prompts = @(
    [pscustomobject]@{
        Id = 'IE01'
        Title = 'Employee Information Extraction'
        Text = @'
Extract the following information from the employee record below:

- Full name
- Employee ID
- Department
- Job title
- Hire date
- Email address
- Employment status

Employee Record:

Sarah Mitchell joined Northstar Technologies on March 15, 2021, as a Junior Systems Analyst. Her employee identification number is EMP-20458. After receiving a promotion in August 2023, she became a Senior Systems Analyst in the Information Technology department. Her company email address is sarah.mitchell@northstar.example. As of October 2026, Sarah remains an active full-time employee.

Return the extracted information as a JSON object with the following keys:

{
  "full_name": "",
  "employee_id": "",
  "department": "",
  "job_title": "",
  "hire_date": "",
  "email": "",
  "employment_status": ""
}

Requirements:
1. Return only valid JSON.
2. Use YYYY-MM-DD format for dates.
3. Use the employee's current job title.
4. Do not include explanations or additional text.
5. Do not invent information.
'@
    },
    [pscustomobject]@{
        Id = 'IE02'
        Title = 'IT Incident Report Extraction'
        Text = @'
Analyze the following IT incident report and extract the requested information.

Incident Report:

On October 12, 2026, at approximately 09:42 EST, the IT Operations team detected abnormal authentication activity on application server APP-SRV-03 (192.168.10.45).

The monitoring system identified 147 unsuccessful login attempts originating from IP address 203.0.113.87 between 09:38 and 09:42 EST.

At 09:46 EST, security analyst David Chen classified the event as a suspected brute-force authentication attack.

The affected application was the company's internal employee portal.

The source IP address was temporarily blocked at the firewall at 09:51 EST.

A subsequent review confirmed that no unauthorized authentication attempts were successful.

The incident was assigned ticket number INC-2026-1042 and marked as resolved at 10:25 EST.

Extract the following fields:

{
  "incident_id": "",
  "incident_date": "",
  "detection_time": "",
  "affected_server": "",
  "server_ip": "",
  "source_ip": "",
  "attack_type": "",
  "failed_login_attempts": 0,
  "affected_application": "",
  "assigned_analyst": "",
  "mitigation_action": "",
  "resolution_time": "",
  "successful_compromise": false
}

Requirements:
1. Return only valid JSON.
2. Preserve IP addresses exactly.
3. Use YYYY-MM-DD for dates and HH:MM for times.
4. Use numeric values for counts.
5. Use a Boolean value for successful_compromise.
6. Do not infer information that is not explicitly provided.
'@
    },
    [pscustomobject]@{
        Id = 'IE03'
        Title = 'HTTP API Log Analysis and Extraction'
        Text = @'
Analyze the following HTTP access logs.

2026-10-15 10:15:22 GET /api/v1/users 200 145ms
2026-10-15 10:15:24 POST /api/v1/login 401 89ms
2026-10-15 10:15:25 POST /api/v1/login 200 112ms
2026-10-15 10:15:27 GET /api/v1/users/104 200 76ms
2026-10-15 10:15:30 DELETE /api/v1/users/104 403 91ms
2026-10-15 10:15:33 GET /api/v1/products 500 312ms
2026-10-15 10:15:35 GET /api/v1/products 200 128ms
2026-10-15 10:15:38 PUT /api/v1/users/104 200 184ms
2026-10-15 10:15:41 POST /api/v1/orders 201 221ms
2026-10-15 10:15:43 GET /api/v1/orders/582 404 67ms

Extract the following information:

1. Total number of HTTP requests.
2. Number of unique endpoint paths.
3. Number of requests for each HTTP method.
4. Number of responses for each HTTP status code.
5. Average response time across all requests, rounded to two decimal places.
6. Endpoint paths that returned at least one 4xx or 5xx response.

Return the results using this JSON structure:

{
  "total_requests": 0,
  "unique_endpoints": 0,
  "http_methods": {
    "GET": 0,
    "POST": 0,
    "PUT": 0,
    "DELETE": 0
  },
  "status_codes": {
    "200": 0,
    "201": 0,
    "401": 0,
    "403": 0,
    "404": 0,
    "500": 0
  },
  "average_response_time_ms": 0,
  "error_endpoints": []
}

Requirements:
1. Return only valid JSON.
2. Count identical endpoint paths as one unique endpoint regardless of HTTP method.
3. Preserve distinct resource identifiers in endpoint paths.
4. Include each error endpoint only once.
5. Sort error_endpoints alphabetically.
6. Do not include additional commentary.
'@
    },
    [pscustomobject]@{
        Id = 'IE04'
        Title = 'Vulnerability Assessment Findings Extraction'
        Text = @'
Review the following application security assessment summary.

Assessment Summary:

The security assessment of the Customer Management Portal identified several weaknesses.

Finding F-001: The application does not implement the Strict-Transport-Security HTTP response header. This issue affects https://portal.example.com and was assigned a Medium severity rating. The recommended remediation is to configure an appropriate HSTS policy after confirming that all required resources support HTTPS.

Finding F-002: The authentication endpoint at /api/auth/login does not consistently enforce account lockout or rate limiting. Testing demonstrated that more than 500 unsuccessful authentication attempts could be submitted without restriction. The finding was assigned High severity. The recommended remediation is to implement effective authentication rate limiting.

Finding F-003: The session cookie named SESSIONID does not include the HttpOnly attribute. The issue was identified on /dashboard and assigned Medium severity. The recommended remediation is to configure the session cookie with the HttpOnly attribute.

Finding F-004: The endpoint /api/users/105 returns another user's profile information when the numeric user identifier is changed. Authorization checks were not consistently enforced. This issue was classified as an Insecure Direct Object Reference vulnerability with Critical severity. The recommended remediation is to implement server-side object-level authorization checks.

Finding F-005: The application discloses its backend framework through the Server response header, which contains the value uvicorn. The finding was assigned Informational severity. The recommended remediation is to suppress unnecessary technology-identifying response headers.

Extract every finding and return a JSON object using the following structure:

{
  "total_findings": 0,
  "findings": [
    {
      "finding_id": "",
      "vulnerability": "",
      "severity": "",
      "affected_component": "",
      "recommended_remediation": ""
    }
  ],
  "severity_summary": {
    "Critical": 0,
    "High": 0,
    "Medium": 0,
    "Low": 0,
    "Informational": 0
  }
}

Requirements:
1. Return only valid JSON.
2. Include all identified findings.
3. Preserve finding IDs and severity ratings exactly.
4. Associate each finding with its correct affected component.
5. Summarize remediation actions accurately and concisely.
6. Count findings by severity.
7. Do not introduce vulnerabilities that were not explicitly identified.
8. Do not include explanations outside the JSON.
'@
    },
    [pscustomobject]@{
        Id = 'IE05'
        Title = 'Multi-Document Information Extraction and Reconciliation'
        Text = @'
You are reviewing three internal records related to an IT infrastructure upgrade.

Your task is to extract the requested information, reconcile conflicting records, and identify missing information.

Document A — Project Proposal
Date: September 1, 2026

Project Name: Infrastructure Modernization Initiative
Project ID: PRJ-2026-087
Project Manager: Michael Torres
Initial Budget: $125,000
Planned Start Date: October 1, 2026
Planned Completion Date: December 15, 2026

The project includes replacing 25 aging application servers and upgrading network switches across two data centers.

Document B — Budget Revision
Date: September 18, 2026

Project ID: PRJ-2026-087
Approved Revised Budget: $148,500
Reason for Revision: Additional network equipment and increased hardware procurement costs.

The revised budget was approved by Finance Director Jennifer Adams.

The project schedule remains unchanged.

Document C — Project Status Report
Date: October 20, 2026

Project ID: PRJ-2026-087

Project Status: In Progress
Actual Start Date: October 3, 2026
Application Servers Replaced: 11
Network Switches Upgraded: 8
Total Expenditure to Date: $67,250

The project manager reported a possible two-week delay due to equipment delivery issues. No revised completion date has been formally approved.

The project remains within the revised approved budget.

Extract and reconcile the information into this JSON structure:

{
  "project_id": "",
  "project_name": "",
  "project_manager": "",
  "original_budget": 0,
  "revised_budget": 0,
  "budget_increase": 0,
  "budget_approver": "",
  "planned_start_date": "",
  "actual_start_date": "",
  "approved_completion_date": "",
  "revised_completion_date": null,
  "project_status": "",
  "servers_planned": 0,
  "servers_replaced": 0,
  "switches_upgraded": 0,
  "expenditure_to_date": 0,
  "remaining_budget": 0,
  "potential_delay": "",
  "budget_status": ""
}

Requirements:
1. Return only valid JSON.
2. Use the most recently approved budget.
3. Do not confuse proposed dates with actual dates.
4. Use YYYY-MM-DD for dates.
5. Represent monetary values as numbers without currency symbols or commas.
6. Calculate the budget increase and remaining budget.
7. Use null when an explicitly requested date is unavailable.
8. Do not invent a revised completion date.
9. Preserve the distinction between a possible delay and an approved schedule change.
10. Do not include explanations outside the JSON.
'@
    }
)

function Write-JsonFile {
    param($Value, [string]$Path)
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 30), $Utf8)
}

function Get-SystemSnapshot {
    # CIM class/property names work independently of localized PerfMon names.
    $cpu = Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'"
    $os = Get-CimInstance Win32_OperatingSystem
    if (-not $cpu -or [double]$os.TotalVisibleMemorySize -le 0) {
        throw 'Windows CPU or memory counters are unavailable.'
    }
    [pscustomobject]@{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        IdleTicks = [decimal]$cpu.PercentProcessorTime
        ClockTicks = [decimal]$cpu.Timestamp_Sys100NS
        MemoryUsedPercent = 100.0 * (1.0 - [double]$os.FreePhysicalMemory / [double]$os.TotalVisibleMemorySize)
    }
}

function Invoke-ControlRequest {
    param([string]$Path, $Body)
    $requestArgs = @{ Uri = "$BaseUrl$Path"; TimeoutSec = $RequestTimeoutSeconds; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $requestArgs.Method = 'Post'
        $requestArgs.ContentType = 'application/json; charset=utf-8'
        $requestArgs.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10))
    }
    Invoke-RestMethod @requestArgs
}

function Stop-BenchmarkModel {
    param([string]$Model)
    $null = Invoke-ControlRequest '/api/generate' @{ model = $Model; keep_alive = 0; stream = $false }
    $wait = [Diagnostics.Stopwatch]::StartNew()
    do {
        $running = Invoke-ControlRequest '/api/ps' $null
        if (@($running.models).Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ($wait.Elapsed.TotalSeconds -lt 30)
    throw 'Models remain loaded after unloading. Benchmark stopped to avoid overlapping models.'
}

# The worker measures the actual HTTP round trip, including receiving the body.
# It returns errors as data so a failed request can still produce a CSV row.
$HttpWorker = {
    param([string]$Uri, [string]$Json, [int]$Timeout)
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds($Timeout)
    $content = New-Object System.Net.Http.StringContent($Json, [Text.Encoding]::UTF8, 'application/json')
    $response = $null
    $raw = $null
    $errorText = $null
    $httpStatus = $null
    $started = [DateTime]::UtcNow.ToString('o')
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $client.PostAsync($Uri, $content).GetAwaiter().GetResult()
        $raw = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $httpStatus = [int]$response.StatusCode
        if (-not $response.IsSuccessStatusCode) { $errorText = "HTTP $httpStatus : $raw" }
    }
    catch { $errorText = $_.Exception.ToString() }
    finally {
        $timer.Stop()
        if ($null -ne $response) { $response.Dispose() }
        $content.Dispose()
        $client.Dispose()
    }
    [pscustomobject]@{
        StartedUtc = $started; EndToEndSeconds = $timer.Elapsed.TotalSeconds
        RawBody = $raw; ErrorText = $errorText; HttpStatus = $httpStatus
    }
}

function Invoke-MeasuredPrompt {
    param($Body, [string]$Model, [string]$PromptId)
    $worker = [PowerShell]::Create()
    $samples = New-Object 'System.Collections.Generic.List[object]'
    $sampleErrors = New-Object 'System.Collections.Generic.List[string]'
    try {
        $null = $worker.AddScript($HttpWorker.ToString()).AddArgument("$BaseUrl/api/generate").AddArgument(($Body | ConvertTo-Json -Depth 10)).AddArgument($RequestTimeoutSeconds)
        $previous = Get-SystemSnapshot
        $handle = $worker.BeginInvoke()
        try {
            # WaitOne wakes immediately when HTTP finishes; timing never includes
            # an artificial one-second delay after a short response.
            do {
                $finished = $handle.AsyncWaitHandle.WaitOne($SampleIntervalMs)
                try {
                    $current = Get-SystemSnapshot
                    $ticks = $current.ClockTicks - $previous.ClockTicks
                    if ($ticks -gt 0) {
                        $cpuPercent = 100.0 * (1.0 - [double](($current.IdleTicks - $previous.IdleTicks) / $ticks))
                        $samples.Add([pscustomobject]@{
                            Model = $Model; PromptId = $PromptId; TimestampUtc = $current.TimestampUtc
                            IntervalSeconds = [double]$ticks / 1e7
                            CpuPercent = [Math]::Max(0, [Math]::Min(100, $cpuPercent))
                            SystemMemoryPercent = $current.MemoryUsedPercent
                        })
                    }
                    $previous = $current
                }
                catch { $sampleErrors.Add($_.Exception.Message) }
            } while (-not $finished)
            $reply = @($worker.EndInvoke($handle))
            if ($worker.HadErrors -or $reply.Count -ne 1) {
                throw "HTTP worker failed: $($worker.Streams.Error | Out-String)"
            }
            [pscustomobject]@{ Reply = $reply[0]; Samples = $samples.ToArray(); SampleErrors = $sampleErrors.ToArray() }
        }
        finally { if (-not $handle.IsCompleted) { $worker.Stop() } }
    }
    finally { $worker.Dispose() }
}

# Verify the API and resource counters before beginning a potentially long run.
try {
    $version = Invoke-ControlRequest '/api/version' $null
    $installed = Invoke-ControlRequest '/api/tags' $null
    $running = Invoke-ControlRequest '/api/ps' $null
    $baseline = Get-SystemSnapshot
}
catch { throw "Preflight failed. Start Ollama and check Windows CIM counters. $($_.Exception.Message)" }
if (@($running.models).Count -gt 0) {
    throw 'Stop currently loaded models with ollama stop <model>, then rerun. The benchmark requires an idle Ollama server.'
}

$runId = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
$runDirectory = Join-Path $OutputDirectory $runId
$null = New-Item -ItemType Directory -Path $runDirectory -Force
$runDirectory = (Resolve-Path -LiteralPath $runDirectory).Path
$csvPath = Join-Path $runDirectory 'measurements.csv'
$samplesPath = Join-Path $runDirectory 'resource-samples.csv'
Write-JsonFile ([ordered]@{
    StartedUtc = [DateTime]::UtcNow.ToString('o'); Models = $Models; Prompts = $Prompts
    OllamaVersion = $version; InstalledModels = $installed; PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    Computer = @(Get-CimInstance Win32_ComputerSystem | Select-Object -Property @('Manufacturer', 'Model', 'TotalPhysicalMemory'))
    Processor = @(Get-CimInstance Win32_Processor | Select-Object -Property @('Name', 'NumberOfCores', 'NumberOfLogicalProcessors'))
    OS = @(Get-CimInstance Win32_OperatingSystem | Select-Object -Property @('Caption', 'Version', 'BuildNumber'))
    Baseline = $baseline; ContextWindow = $ContextWindow; NumPredict = $NumPredict
    Temperature = 0; Seed = 42; ThinkingMode = 'ModelDefault'; SampleIntervalMs = $SampleIntervalMs
    RequestTimeoutSeconds = $RequestTimeoutSeconds; ApiUrl = $BaseUrl
    ResourceScope = 'Total system; sampled through the HTTP request, including prompt processing and generation'
    TimingScope = 'Client HTTP round trip; excludes explicit model preload and result file writes'
}) (Join-Path $runDirectory 'run-info.json')

foreach ($model in $Models) {
    Write-Host "`n=== $model ===" -ForegroundColor Cyan
    $safeModel = $model -replace '[^A-Za-z0-9._-]', '_'
    $modelDirectory = Join-Path $runDirectory $safeModel
    $null = New-Item -ItemType Directory -Path $modelDirectory -Force
    $modelError = $null
    $preloadSeconds = $null
    $mayBeLoaded = $false
    try {
        try {
            $match = @($installed.models | Where-Object { $_.name -eq $model -or $_.model -eq $model })
            if ($match.Count -eq 0) { throw "Model is not installed. Run: ollama pull $model" }
            $show = Invoke-ControlRequest '/api/show' @{ model = $model }
            Write-JsonFile $show (Join-Path $modelDirectory 'model-info.json')
            $mayBeLoaded = $true
            $loadTimer = [Diagnostics.Stopwatch]::StartNew()
            $load = Invoke-ControlRequest '/api/generate' @{
                model = $model; prompt = ''; stream = $false; keep_alive = -1
                options = @{ num_ctx = $ContextWindow }
            }
            $loadTimer.Stop()
            if ($load.error) { throw [string]$load.error }
            $preloadSeconds = $loadTimer.Elapsed.TotalSeconds
            Write-JsonFile $load (Join-Path $modelDirectory 'preload.json')
            Write-JsonFile (Invoke-ControlRequest '/api/ps' $null) (Join-Path $modelDirectory 'loaded-models.json')
            Write-Host ('Loaded in {0:N2} seconds.' -f $preloadSeconds)
        }
        catch {
            $modelError = $_.Exception.Message
            Write-Warning "$model : $modelError"
        }

        foreach ($prompt in $Prompts) {
            Write-Host "  $($prompt.Id): $($prompt.Title)"
            $prefix = Join-Path $modelDirectory $prompt.Id
            $row = [ordered]@{
                RunId = $runId; Model = $model; PromptId = $prompt.Id; PromptTitle = $prompt.Title
                Status = 'Skipped'; Error = $modelError; StartedUtc = $null
                GenerationTokensPerSecond = $null; EndToEndSeconds = $null
                AverageCpuPercent = $null; PeakCpuPercent = $null
                AverageSystemMemoryPercent = $null; PeakSystemMemoryPercent = $null
                ResourceSampleCount = 0; SamplingErrors = $null; PreloadSeconds = $preloadSeconds
                OutputTokens = $null; InputTokens = $null; GenerationSeconds = $null
                OllamaTotalSeconds = $null; RequestLoadSeconds = $null; DoneReason = $null
                ContextWindow = $ContextWindow; NumPredict = $NumPredict; ThinkingMode = 'ModelDefault'
                ResponseFile = $null; ApiResponseFile = $null
            }
            if ($null -eq $modelError) {
                $body = @{
                    model = $model; prompt = $prompt.Text; stream = $false; keep_alive = -1
                    options = @{ temperature = 0; seed = 42; num_ctx = $ContextWindow; num_predict = $NumPredict }
                }
                Write-JsonFile $body "$prefix.request.json"
                $measured = $null
                try {
                    $measured = Invoke-MeasuredPrompt $body $model $prompt.Id
                    $reply = $measured.Reply
                    $row.StartedUtc = $reply.StartedUtc
                    $row.EndToEndSeconds = [Math]::Round($reply.EndToEndSeconds, 6)
                    $row.ResourceSampleCount = @($measured.Samples).Count
                    $row.SamplingErrors = $measured.SampleErrors -join ' | '
                    if ($row.ResourceSampleCount -gt 0) {
                        $measured.Samples | Export-Csv -LiteralPath $samplesPath -NoTypeInformation -Append -Encoding UTF8
                        $cpuIntegral = 0.0; $intervalTotal = 0.0
                        foreach ($sample in $measured.Samples) {
                            $cpuIntegral += $sample.CpuPercent * $sample.IntervalSeconds
                            $intervalTotal += $sample.IntervalSeconds
                        }
                        $row.AverageCpuPercent = [Math]::Round($cpuIntegral / $intervalTotal, 3)
                        $row.PeakCpuPercent = [Math]::Round(($measured.Samples | Measure-Object CpuPercent -Maximum).Maximum, 3)
                        $row.AverageSystemMemoryPercent = [Math]::Round(($measured.Samples | Measure-Object SystemMemoryPercent -Average).Average, 3)
                        $row.PeakSystemMemoryPercent = [Math]::Round(($measured.Samples | Measure-Object SystemMemoryPercent -Maximum).Maximum, 3)
                    }
                    if ($null -ne $reply.RawBody) {
                        [IO.File]::WriteAllText("$prefix.api-response.json", $reply.RawBody, $Utf8)
                        $row.ApiResponseFile = "$prefix.api-response.json"
                    }
                    if ($reply.ErrorText) { throw $reply.ErrorText }
                    $result = $reply.RawBody | ConvertFrom-Json
                    if ($result.error) { throw [string]$result.error }
                    [IO.File]::WriteAllText("$prefix.response.txt", [string]$result.response, $Utf8)
                    $row.ResponseFile = "$prefix.response.txt"
                    if ($result.thinking) { [IO.File]::WriteAllText("$prefix.thinking.txt", [string]$result.thinking, $Utf8) }
                    $row.OutputTokens = $result.eval_count; $row.InputTokens = $result.prompt_eval_count
                    $row.DoneReason = $result.done_reason
                    if ($null -ne $result.total_duration) { $row.OllamaTotalSeconds = [double]$result.total_duration / 1e9 }
                    if ($null -ne $result.load_duration) { $row.RequestLoadSeconds = [double]$result.load_duration / 1e9 }
                    $row.Status = 'Completed'; $row.Error = $null
                    if ([double]$result.eval_duration -gt 0 -and $null -ne $result.eval_count) {
                        $row.GenerationSeconds = [double]$result.eval_duration / 1e9
                        $row.GenerationTokensPerSecond = [Math]::Round([double]$result.eval_count / $row.GenerationSeconds, 6)
                    }
                    else { $row.Status = 'MissingMetrics'; $row.Error = 'Ollama did not return valid generation timing/token counts.' }
                    if (-not $result.done) { $row.Status = 'Incomplete'; $row.Error = 'API did not confirm completed generation.' }
                    elseif ($result.done_reason -eq 'length') { $row.Status = 'Truncated'; $row.Error = 'Output reached a length limit; review or rerun with a higher NumPredict.' }
                    elseif ([string]::IsNullOrWhiteSpace([string]$result.response)) { $row.Status = 'EmptyResponse'; $row.Error = 'No answer text returned. Inspect thinking/API response.' }
                    if ($row.ResourceSampleCount -eq 0 -or $row.SamplingErrors) {
                        $row.Error = @($row.Error, 'Resource sampling was incomplete; inspect SamplingErrors.') -join ' '
                        if ($row.Status -eq 'Completed') { $row.Status = 'SamplingWarning' }
                    }
                    Write-Host ('    {0} | {1} tokens/sec | {2:N2} sec | CPU avg {3}% | RAM peak {4}%' -f $row.Status, $row.GenerationTokensPerSecond, $row.EndToEndSeconds, $row.AverageCpuPercent, $row.PeakSystemMemoryPercent)
                }
                catch {
                    $row.Status = 'Failed'; $row.Error = $_.Exception.Message
                    [IO.File]::WriteAllText("$prefix.error.txt", $row.Error, $Utf8)
                    Write-Warning "$model / $($prompt.Id): $($row.Error)"
                    # A timed-out server may still be cancelling generation. Skip
                    # this model's remaining requests and unload before advancing.
                    $modelError = "Skipped after request failure: $($row.Error)"
                }
            }
            [pscustomobject]$row | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Append -Encoding UTF8
        }
    }
    finally {
        if ($mayBeLoaded) { Stop-BenchmarkModel $model }
    }
}

Write-Host "`nFinished. Measurements: $csvPath" -ForegroundColor Green
Write-Host "Responses and supporting files: $runDirectory"
