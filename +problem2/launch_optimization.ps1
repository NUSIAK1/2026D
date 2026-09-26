param(
    [string]$SeedDirectory = '20260925_232556_tp5e5096d5_b077_4d47_ba6f_20e003fcc2c6',
    [int]$SearchSeconds = 6600,
    [ValidateSet('strict','recompute')][string]$SeedEvaluationMode = 'strict'
)
$ErrorActionPreference = 'Stop'
if ($SearchSeconds -le 0 -or $SearchSeconds -gt 6600) { throw '搜索预算须在 1 至 6600 秒之间。' }
$codeDir = Split-Path -Parent $PSScriptRoot
$projectDir = Split-Path -Parent $codeDir
$resultsDir = Join-Path $projectDir '结果'
$seedDir = Join-Path (Join-Path $resultsDir '问题二_优化实验') $SeedDirectory
$seedFile = Join-Path $seedDir '问题二_Pareto完整档案.mat'
if (-not (Test-Path -LiteralPath $seedFile)) { throw '未找到指定热启动档案。' }
$recordDir = Join-Path (Join-Path $codeDir 'cache') ('q2_background_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $recordDir | Out-Null
$env:Q2_RUN_RECORD = $recordDir
$env:Q2_SEED_FILE = $seedFile
$env:Q2_SEARCH_SECONDS = [string]$SearchSeconds
$env:Q2_SEED_MODE = $SeedEvaluationMode
$frozenBase = Join-Path $recordDir 'flightBase.mat'
Copy-Item -LiteralPath (Join-Path $codeDir 'cache/flightBase.mat') -Destination $frozenBase
$env:Q2_FLIGHT_BASE = $frozenBase
$protectedFiles = @(
    Get-ChildItem -LiteralPath $resultsDir -File -Filter '问题二_*' | Where-Object { $_.Name -notlike '~$*' }
    Get-ChildItem -LiteralPath $seedDir -File -Recurse | Where-Object { $_.Name -notlike '~$*' }
)
$before = @($protectedFiles | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash)
$before | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $recordDir '原结果SHA256.json') -Encoding UTF8
Get-ChildItem -LiteralPath (Join-Path $codeDir '+problem2') -File -Recurse |
    Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $recordDir '源码SHA256.json') -Encoding UTF8
$matlab = (Get-Command matlab -ErrorAction Stop).Source
@(
    Get-ChildItem -LiteralPath (Join-Path $codeDir '+common') -File -Recurse
    Get-Item -LiteralPath (Join-Path $codeDir 'cache/flightBase.mat')
) | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $recordDir '公共依赖SHA256.json') -Encoding UTF8
$command = "fprintf('Q2 v4: regression tests before optimization\n'); problem2.tests.test_problem2(getenv('Q2_FLIGHT_BASE')); fprintf('Q2 v4: regression passed, starting optimization\n'); r=problem2.run_optimization(struct('SeedArchiveFile',getenv('Q2_SEED_FILE'),'FlightBaseFile',getenv('Q2_FLIGHT_BASE'),'SeedEvaluationMode',getenv('Q2_SEED_MODE'),'TimeLimit_s',str2double(getenv('Q2_SEARCH_SECONDS')),'NumRuns',15,'RandomSeed',20260927,'ProgressEvery',100));"
$arguments = '-wait -batch "{0}" -logfile "{1}"' -f $command,(Join-Path $recordDir 'MATLAB运行日志.txt')
$started = Get-Date
$process = Start-Process -FilePath $matlab -ArgumentList $arguments -WorkingDirectory $codeDir -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $recordDir '启动标准输出.txt') -RedirectStandardError (Join-Path $recordDir '启动错误输出.txt')
@{ PID=$process.Id; Started=$started.ToString('o'); SearchSeconds=$SearchSeconds; WallLimitSeconds=7200; SeedFile=$seedFile; SeedEvaluationMode=$SeedEvaluationMode; FlightBaseFile=$frozenBase; RecordDirectory=$recordDir } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $recordDir '启动信息.json') -Encoding UTF8
$timedOut = -not $process.WaitForExit(7200000)
if ($timedOut) {
    # 只终止本次启动的进程树，已有检查点保留在独立目录。
    & taskkill.exe /PID $process.Id /T /F | Out-File -LiteralPath (Join-Path $recordDir '超时终止日志.txt') -Encoding UTF8
    $process.WaitForExit()
}
$process.Refresh()
$changed = @()
foreach ($entry in $before) {
    if (-not (Test-Path -LiteralPath $entry.Path) -or (Get-FileHash -LiteralPath $entry.Path -Algorithm SHA256).Hash -ne $entry.Hash) {
        $changed += $entry.Path
    }
}
$status = @{ Completed=(Get-Date).ToString('o'); ExitCode=$process.ExitCode; TimedOut=$timedOut; ProtectedFileCount=$before.Count; HashesUnchanged=($changed.Count -eq 0); ChangedFiles=$changed }
$status | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $recordDir '后台完成状态.json') -Encoding UTF8
$pathFile = Join-Path $recordDir 'result_path.txt'
if (Test-Path -LiteralPath $pathFile) {
    $outputDir = Get-Content -LiteralPath $pathFile -Raw -Encoding UTF8
    Copy-Item -LiteralPath (Join-Path $recordDir '原结果SHA256.json'),(Join-Path $recordDir '源码SHA256.json'),(Join-Path $recordDir '后台完成状态.json') -Destination $outputDir
}
if ($timedOut -or $process.ExitCode -ne 0 -or $changed.Count -gt 0) { exit 1 }
