# Test-Prompts

**A PowerShell benchmarking suite for evaluating the performance and response quality of locally hosted large language models (LLMs) on resource-constrained Windows hardware.**

## Overview

Test-Prompts contains six standalone PowerShell scripts that evaluate local LLMs across distinct task categories. Each script runs **five predefined prompts** against **five configured Ollama models**, recording inference performance, total-system resource utilization, and complete model responses for subsequent quality assessment.

The project was developed to support a hardware feasibility assessment: determining whether a business-class laptop without a dedicated high-memory GPU can deliver acceptable performance and answer quality when running small LLMs locally. The tools can also be reused on other Windows machines to compare hardware configurations or model selections.

The scripts **collect evidence; they do not automatically grade response correctness or decide hardware viability**. Response quality must be evaluated separately against a consistent rubric and the intended use case.

## Evaluation categories

| Script | Category | What it evaluates |
|---|---|---|
| `Test-FactualKnowledge.ps1` | Factual Knowledge | Accuracy, completeness, and clarity when explaining established technical facts and concepts. |
| `Test-LogicalReasoning.ps1` | Logical Reasoning | Deduction, multi-step reasoning, constraint handling, and consistency of conclusions. |
| `Test-Summarization.ps1` | Summarization | Ability to condense longer source material while preserving key facts and meaning. |
| `Test-InformationExtraction.ps1` | Information Extraction | Accurate identification and structuring of specified fields from supplied text. |
| `Test-Coding.ps1` | Coding | Code generation, adherence to requirements, correctness, and handling of edge cases. |
| `Test-TechnicalAnalysis.ps1` | Technical Analysis | Interpretation of technical evidence, identification of likely issues, and well-supported conclusions. |

**Default workload:** 6 categories × 5 prompts × 5 models = **150 prompt/model evaluations** (25 per script), assuming all tests run to completion.

## Default models

The scripts are configured to test the following Ollama model identifiers:

- `gemma4:e4b`
- `gemma4:e2b`
- `llama3.2:3b`
- `llama3.2:1b`
- `phi4-mini:3.8b`

Model identifiers must match the names installed in the local Ollama instance. Use the `-Models` argument to test another selection. Models are tested sequentially, not concurrently.

## Reference test environment

The initial assessment targets a **Dell Latitude 5420** with:

| Component | Configuration |
|---|---|
| Processor | Intel Core i7-1185G7 (11th generation) |
| System memory | 16 GB RAM |
| Graphics | Integrated Intel graphics; 128 MB reported dedicated video memory |
| Operating system | Windows |
| Model runtime | Ollama, running locally |
| Test execution | Windows PowerShell 5.1 or PowerShell 7 on Windows |

These are the reference system specifications, **not minimum requirements** for running the scripts. Benchmark results are machine- and configuration-dependent.

## Requirements

- Windows with Windows PowerShell 5.1 or PowerShell 7.
- [Ollama](https://ollama.com/) installed and running locally on `http://127.0.0.1:11434`.
- All model identifiers selected for a run already downloaded into Ollama.
- Windows CIM/WMI performance counters accessible to the account executing the scripts.
- Sufficient disk space for captured responses, request/response JSON, CSV data, and model metadata.

No PowerShell modules, Python dependencies, or administrator privileges are required by the scripts.

## Getting started

### 1. Clone the repository

```powershell
git clone <YOUR-REPOSITORY-URL>
cd Test-Prompts
```

Alternatively, download the six `.ps1` files into the same working directory.

### 2. Install and start Ollama

Install Ollama, then ensure its local service is running. Verify connectivity and installed models:

```powershell
ollama list
```

Download any models you intend to test, for example:

```powershell
ollama pull llama3.2:3b
ollama pull llama3.2:1b
```

Repeat for the other configured model identifiers as needed. Verify the exact names using `ollama list`; availability may depend on the model registry and local installation.

**Important:** Before each benchmark, Ollama must be idle, with no models currently loaded. The scripts perform a preflight check and reject a run if models are already loaded. Unload a model with `ollama stop <model-name>`.

### 3. Run one evaluation category

From PowerShell in the repository directory:

```powershell
.\Test-FactualKnowledge.ps1
```

If script execution is blocked by your local execution policy, review your organization's policy before adjusting it. For a permitted, process-only override:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Test-FactualKnowledge.ps1
```

### 4. Run all six categories

Run the categories sequentially so they do not compete for the same machine resources:

```powershell
$Scripts = @(
    'Test-FactualKnowledge.ps1',
    'Test-LogicalReasoning.ps1',
    'Test-Summarization.ps1',
    'Test-InformationExtraction.ps1',
    'Test-Coding.ps1',
    'Test-TechnicalAnalysis.ps1'
)

foreach ($Script in $Scripts) {
    & (Join-Path $PWD $Script)
}
```

Each script creates a separate timestamped results directory. Review each run's status and errors before treating the resulting dataset as complete.

## Configuration options

The six scripts expose the same command-line parameters:

| Parameter | Default | Purpose |
|---|---|---|
| `-Models` | The five models listed above | Names of Ollama models to evaluate. |
| `-ContextWindow` | `4096` | Requested model context window, in tokens. |
| `-NumPredict` | `2048` | Maximum generated tokens per response. `-1` removes the explicit generation limit; request timeout still applies. |
| `-SampleIntervalMs` | `1000` | Resource sampling interval, in milliseconds. |
| `-RequestTimeoutSeconds` | `1800` | Timeout for an inference request, in seconds. |
| `-OutputDirectory` | `BenchmarkResults` beside the script | Parent directory for timestamped results. |

Examples:

```powershell
# Benchmark one model in one category
.\Test-Coding.ps1 -Models 'llama3.2:3b'

# Increase context and generated-output limits
.\Test-Summarization.ps1 -ContextWindow 8192 -NumPredict 4096

# Use a custom results directory and faster sampling
.\Test-TechnicalAnalysis.ps1 -OutputDirectory 'C:\LLM-Benchmark' -SampleIntervalMs 500

# Remove the explicit output-token cap
.\Test-LogicalReasoning.ps1 -NumPredict -1
```

For meaningful comparisons, keep sampling, prompt content, output limits, context settings, and relevant Ollama configuration consistent across models and machines wherever possible.

## Collected metrics

| Metric | Interpretation |
|---|---|
| **Generation speed (tokens/sec)** | Ollama-reported generated tokens divided by generation duration. Higher generally indicates faster text output. |
| **End-to-end response time (seconds)** | Client-observed duration of the HTTP inference request. Lower generally indicates a more responsive experience. |
| **CPU utilization (%)** | Sampled overall Windows CPU utilization during inference. |
| **System memory utilization (%)** | Sampled percentage of total physical RAM in use during inference. |
| **Response quality** | Assessed separately by reviewing saved model responses for correctness, relevance, completeness, and adherence to instructions. |

Resource sampling captures **system-wide CPU and physical RAM usage**, including the operating system, Ollama, and any other processes. These percentages are **not Ollama process-specific**. Sampled peak values are not guaranteed to capture instantaneous maxima.

The scripts also preserve the raw Ollama response and timing metadata so results can be audited. Model preloading is measured separately and is excluded from per-prompt end-to-end response timing; results therefore describe **preloaded/warm-model inference**, not cold-start experience.

No GPU utilization metric is collected by these scripts. The reported integrated graphics memory should not be interpreted as a measurement of GPU acceleration.

## Output files

Each execution creates a uniquely named subdirectory under `BenchmarkResults` (or the configured output directory):

```text
Test-Prompts/
├── Test-FactualKnowledge.ps1
├── Test-LogicalReasoning.ps1
├── Test-Summarization.ps1
├── Test-InformationExtraction.ps1
├── Test-Coding.ps1
├── Test-TechnicalAnalysis.ps1
├── README.md
└── BenchmarkResults/
    └── <timestamp-and-run-id>/
        ├── measurements.csv
        ├── resource-samples.csv
        ├── run-info.json
        └── <model-name>/
            ├── model-info.json
            └── ... per-prompt request, response, and supporting files
```

- **`measurements.csv`** — One summary row per model/prompt test, including performance measurements and execution status.
- **`resource-samples.csv`** — Time-series CPU and system RAM measurements taken while requests execute.
- **`run-info.json`** — Run configuration, complete prompt definitions, timestamps, hardware/OS information, and Ollama version details.
- **`model-info.json`** — Ollama model metadata useful for checking model settings and interpreting comparisons.
- **Per-prompt files** — The submitted request, full returned response data, readable answer text, and supporting error information where applicable.

The scripts append summary results as prompts finish so previously completed measurements remain available if a later test fails. Inspect `Status` and `Error` fields; do not assume that every row represents a successful, complete response. Responses that reach the configured output limit may be marked `Truncated`.

Because results can be large and may contain sensitive prompt or response content, consider adding `BenchmarkResults/` to `.gitignore` and review any generated files before sharing them.

## Benchmark methodology

1. **Preflight:** Verify Ollama connectivity, installed model availability, resource counters, and an idle Ollama instance.
2. **Model preparation:** Load one selected model and record its metadata and loading information.
3. **Prompt execution:** Submit each of the five category-specific prompts independently, without conversation history from earlier tests.
4. **Measurement:** Capture Ollama timing data and poll system-wide CPU/RAM usage while the HTTP request runs.
5. **Evidence preservation:** Save the full response, metadata, resource samples, and one summary row for each evaluation.
6. **Cleanup and continuation:** Unload the current model and proceed sequentially to the next model.
7. **Analysis:** Compare latency, throughput, resource utilization, and independently scored answer quality.

The scripts use a deterministic generation temperature of `0` and seed of `42`, but exact outputs can still vary across runtimes and hardware. Installed model defaults, including thinking behavior, are not forcibly overridden. Consult the captured model metadata before making direct comparisons.

For stronger experimental validity, repeat runs on an otherwise idle system, maintain a consistent thermal/power configuration, and report medians or distributions rather than relying on a single measurement. The scripts do not automatically perform statistical repetitions.

## Assessing response quality

**Response quality is not automatically scored.** For each saved response, use a documented rubric appropriate to the prompt category. A suggested five-point rubric is:

| Score | Description |
|---|---|
| 0 | Incorrect, unusable, or no substantive answer. |
| 1 | Mostly incorrect; major omissions or significant requirement violations. |
| 2 | Partially correct but missing important information or containing material errors. |
| 3 | Mostly correct with minor errors or omissions. |
| 4 | Correct, complete, and follows the prompt's requirements. |

To express this rubric as a percentage, calculate `score / 4 × 100` for each response, then average consistently across prompts. This is an **optional analysis convention**, not a metric computed by the repository scripts. For coding tasks, consider running generated code against separate validation tests instead of relying exclusively on subjective review.

Do not equate high generation speed with model suitability: a fast model that consistently produces incorrect answers may be less useful than a slower, accurate one. Conversely, a high-quality model may still be impractical if its latency or resource usage disrupts the intended workflow.

## Interpreting hardware viability

Evaluate findings against explicit, use-case-specific acceptance criteria, such as maximum acceptable response latency, minimum quality score, and available system headroom. Consider both interactive usability and the impact on other business applications.

The objective is **to test** the feasibility of local LLM inference on the reference laptop, not to assume infeasibility in advance. Final recommendations should reflect the collected results, observed limitations, and the requirements of the intended deployment.

## Limitations

- **Windows only:** Resource collection uses Windows system counters.
- **Local Ollama only:** The scripts target `http://127.0.0.1:11434`.
- **One request at a time:** No concurrency, multi-user load, or throughput-at-scale testing.
- **Preloaded-model measurements:** Cold-start latency is not included in per-prompt response time.
- **System-wide resource metrics:** CPU and RAM metrics cannot isolate Ollama's consumption.
- **Sampled usage:** Short-lived resource spikes may be missed.
- **No automatic answer scoring:** Human review or an additional scoring workflow is required.
- **No GPU telemetry:** The suite does not establish GPU utilization or acceleration effectiveness.
- **No automatic multi-run statistical analysis:** Repeated execution and aggregate analysis must be performed separately.
- **Potential output truncation:** Inspect the status and generated-text length before judging response quality.

## License

No license is specified in this README. Add a `LICENSE` file if you intend to grant others permission to reuse, modify, or redistribute the project.
