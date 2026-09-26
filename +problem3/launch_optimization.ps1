param(
    [Parameter(Mandatory=$true)][string]$SeedResultDir,
    [int]$SearchSeconds = 6600,
    [string]$FlightBaseFile = '',
    [switch]$Worker,
    [string]$ExperimentDir = ''
)
$ErrorActionPreference = 'Stop'
$codeDir = Split-Path -Parent $PSScriptRoot
$projectDir = Split-Path -Parent $codeDir
if ($SearchSeconds -le 0 -or $SearchSeconds -gt 6600) { throw '搜索时间须在 1 至 6600 秒之间。' }
if (-not (Test-Path -LiteralPath $SeedResultDir -PathType Container)) { throw '指定问题二结果目录不存在。' }
if (-not $FlightBaseFile) { $FlightBaseFile = Join-Path $codeDir 'cache/flightBase.mat' }
if (-not (Test-Path -LiteralPath $FlightBaseFile -PathType Leaf)) { throw '基础矩阵不存在。' }
if (-not $Worker) {
    $tag = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $ExperimentDir = Join-Path (Join-Path $projectDir '结果/问题三_优化实验') $tag
    New-Item -ItemType Directory -Path $ExperimentDir | Out-Null
    $shellPath = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile','-File',('"' + $PSCommandPath + '"'),'-Worker',
        '-SeedResultDir',('"' + $SeedResultDir + '"'),'-FlightBaseFile',('"' + $FlightBaseFile + '"'),
        '-SearchSeconds',$SearchSeconds,'-ExperimentDir',('"' + $ExperimentDir + '"'))
    $job = Start-Process -FilePath $shellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $ExperimentDir '守护进程输出.txt') `
        -RedirectStandardError (Join-Path $ExperimentDir '守护进程错误.txt')
    @{ MonitorPID=$job.Id; ExperimentDir=$ExperimentDir; SeedResultDir=$SeedResultDir } | ConvertTo-Json
    return
}
try {
    $snapshot = Join-Path $ExperimentDir '源码快照'
    New-Item -ItemType Directory -Path $snapshot | Out-Null
    Copy-Item -LiteralPath (Join-Path $codeDir '+common'),(Join-Path $codeDir '+problem3') -Destination $snapshot -Recurse
    # 仅修改快照的根路径定位，使后台源码与用户随后编辑的源码完全隔离。
    $pathFunction = Join-Path $snapshot '+common/projectPaths.m'
    $source = Get-Content -LiteralPath $pathFunction -Raw -Encoding UTF8
    $literalRoot = $projectDir.Replace("'","''")
    $source.Replace('projectRoot = fileparts(codeDir);',("projectRoot = '" + $literalRoot + "';")) |
        Set-Content -LiteralPath $pathFunction -Encoding UTF8
    $protected = @(
        Get-ChildItem -LiteralPath (Join-Path $projectDir '结果') -File -Filter '问题三_*'
        Get-ChildItem -LiteralPath $SeedResultDir -File | Where-Object { $_.Name -notlike '~$*' }
    )
    $before = @($protected | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash)
    $before | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ExperimentDir '原结果SHA256.json') -Encoding UTF8
    Get-ChildItem -LiteralPath $snapshot -File -Recurse | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ExperimentDir '源码SHA256.json') -Encoding UTF8
    $env:Q3_SEED_DIR = (Resolve-Path -LiteralPath $SeedResultDir).Path
    $env:Q3_FLIGHT_BASE = (Resolve-Path -LiteralPath $FlightBaseFile).Path
    $env:Q3_OUTPUT_DIR = $ExperimentDir
    $env:Q3_SEARCH_SECONDS = [string]$SearchSeconds
    $env:MATLAB_PREFDIR = Join-Path $ExperimentDir 'MATLAB偏好'
    New-Item -ItemType Directory -Path $env:MATLAB_PREFDIR | Out-Null
    $command = "r=problem3.run_optimization(struct('SeedResultDir',getenv('Q3_SEED_DIR'),'FlightBaseFile',getenv('Q3_FLIGHT_BASE'),'ExperimentDir',getenv('Q3_OUTPUT_DIR'),'TimeLimit_s',str2double(getenv('Q3_SEARCH_SECONDS'))));"
    $arguments = '-wait -singleCompThread -batch "{0}" -logfile "{1}"' -f $command,(Join-Path $ExperimentDir 'MATLAB运行日志.txt')
    $matlab = (Get-Command matlab -ErrorAction Stop).Source
    $process = Start-Process -FilePath $matlab -ArgumentList $arguments -WorkingDirectory $snapshot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $ExperimentDir '启动标准输出.txt') `
        -RedirectStandardError (Join-Path $ExperimentDir '启动错误输出.txt')
    try { $process.PriorityClass = 'BelowNormal' } catch { }
    @{ PID=$process.Id; Started=(Get-Date).ToString('o'); SearchSeconds=$SearchSeconds; WallLimitSeconds=7200;
        SeedResultDir=$SeedResultDir; FlightBaseFile=$FlightBaseFile; ExperimentDir=$ExperimentDir } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ExperimentDir '启动信息.json') -Encoding UTF8
    $timedOut = -not $process.WaitForExit(7200000)
    if ($timedOut) {
        # 仅终止本脚本创建且仍存活的进程树，不匹配或终止其他 MATLAB 进程。
        & taskkill.exe /PID $process.Id /T /F | Out-File -LiteralPath (Join-Path $ExperimentDir '超时终止日志.txt') -Encoding UTF8
        $process.WaitForExit()
    }
    $process.Refresh()
    $changed = @($before | Where-Object {
        -not (Test-Path -LiteralPath $_.Path) -or (Get-FileHash -LiteralPath $_.Path -Algorithm SHA256).Hash -ne $_.Hash
    } | ForEach-Object Path)
    @{ Completed=(Get-Date).ToString('o'); ExitCode=$process.ExitCode; TimedOut=$timedOut;
        ProtectedFilesUnchanged=($changed.Count -eq 0); ChangedFiles=$changed } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ExperimentDir '后台完成状态.json') -Encoding UTF8
} catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $ExperimentDir '后台失败.txt') -Encoding UTF8
    exit 1
}
