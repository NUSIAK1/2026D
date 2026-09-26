function test_problem2()
%TEST_PROBLEM2 问题二的充电模型、热启动和全数据快速回归测试。

assert(abs(common.chargeTime(0,100)-100) < 1e-10);
assert(abs(common.chargeTime(0.9,100)-35) < 1e-10);
assert(abs(common.chargeTime(1,100)) < 1e-10);
assert(abs(common.chargeTime(0.9-1e-9,100)-35) < 1e-6);
testParetoArchive();

paths = common.projectPaths();
assert(isfile(paths.DemandFile),'未定位到问题二需求文件。');
assert(isfile(paths.FlightBaseFile),'未定位到飞行基础缓存。');

config = struct('ExportFiles',false,'SaveRunArchive',false, ...
    'ProgressEnabled',false,'NumRuns',5,'MaxIterations',8, ...
    'TimeLimit_s',120,'StagnationLimit',8,'ArchiveSize',20,'Verbose',false);
result = problem2.solveProblem2(config);
names = {'TimelinessFirst','MakespanFirst','EnergyFirst','TripCountFirst','Balanced'};
for k = 1:numel(names)
    rep = result.Representatives.(names{k});
    assert(height(rep.Deliveries)==80,'必须输出 80 个货箱。');
    assert(numel(unique(rep.Deliveries.BoxID))==80,'每个货箱必须恰好一次。');
    assert(all(rep.Validation.Passed),'问题二代表方案校核未通过。');
end
assert(result.Representatives.MakespanFirst.Objectives.Makespan_s <= ...
    result.Representatives.Balanced.Objectives.Makespan_s+1e-7, ...
    '完成时间优先方案不应慢于折中方案。');
assert(all(result.ParetoFront.TripCount <= 45), ...
    '快速回归 Pareto 档案不应退化为单箱架次区域。');
assert(~isempty(result.ConvergenceLog),'必须记录逐迭代收敛信息。');
assert(all(diff(result.ConvergenceLog.BestMakespan_s) <= 1e-7), ...
    '档案中的最快完成时间不应随迭代变差。');
assert(numel(unique(result.ConvergenceLog.Profile)) == 5, ...
    '五种目标偏好均应获得搜索时间。');
assert(sum(result.OperatorDiagnostics.Candidates) == height(result.ConvergenceLog), ...
    '算子候选统计须覆盖全部迭代。');
assert(height(result.OperatorDiagnostics)==8,'问题二应使用八类职责明确的算子。');
assert(all(result.OperatorDiagnostics.Accepted <= ...
    result.OperatorDiagnostics.Candidates-result.OperatorDiagnostics.Unchanged), ...
    '无变化候选不能计入接受次数。');
assert(all(result.OperatorDiagnostics.Elapsed_s >= 0),'算子耗时不能为负。');
assert(all(abs(result.OperatorDiagnostics.AcceptanceRate- ...
    result.OperatorDiagnostics.Accepted./max(result.OperatorDiagnostics.Candidates,1)) < 1e-12), ...
    '算子接受率必须与候选数、接受数一致。');
for k = 1:numel(result.ParetoSolutions)
    sol = result.ParetoSolutions{k};
    assert(isequal(sort(sol.Order),1:numel(sol.Trips)), ...
        '架次派发顺序必须是完整排列。');
    boxes = [sol.Trips.BoxIdx];
    assert(numel(boxes)==80 && isequal(sort(boxes),1:80), ...
        '解结构必须恰好覆盖 80 个不可拆货箱。');
end
objectives = [result.ParetoFront.Timeliness,result.ParetoFront.Makespan_s, ...
    result.ParetoFront.Energy_kWh,result.ParetoFront.TripCount];
for k = 1:size(objectives,1)
    for j = k+1:size(objectives,1)
        a = objectives(k,:); b = objectives(j,:);
        assert(~(all(a <= b+1e-9) && any(a < b-1e-9)) && ...
            ~(all(b <= a+1e-9) && any(b < a-1e-9)), ...
            'Pareto 档案不能包含互相支配的点。');
    end
end

% 外部热启动路径为可选配置；仅提供其中一个文件时必须明确报错，
% 防止求解器静默回退到问题一热启动而用户误以为已导入外部方案。
failed = false;
try
    problem2.solveProblem2(struct('ExportFiles',false,'SaveRunArchive',false, ...
        'ProgressEnabled',false,'WarmStartTripFile',"missing.xlsx"));
catch ME
    failed = contains(string(ME.message),"必须同时提供");
end
assert(failed,'外部热启动缺少逐箱文件时必须报错。');

% 已有档案作为只读回归样本：逐架次/逐箱数值完全一致，且所有旧权衡均保留。
archiveFile = fullfile(paths.ResultDir,'问题二_Pareto完整档案.mat');
if isfile(archiveFile)
    seededConfig = config;
    seededConfig.SeedArchiveFile = archiveFile;
    seededConfig.ArchiveSize = inf;
    seededConfig.NumRuns = 1;
    seededConfig.MaxIterations = 2;
    seeded = problem2.solveProblem2(seededConfig);
    old = load(archiveFile,'paretoArchive');
    assert(height(seeded.SeedDiagnostics)==numel(old.paretoArchive.ParetoSolutions));
    assert(abs(seeded.Config.BaselineMakespan_s-min(seeded.SeedDiagnostics.Makespan_s))<1e-7, ...
        '档案热启动的对照时间必须来自实际档案。');
    diagnosticFile = [tempname,'.xlsx'];
    cleanupDiagnostic = onCleanup(@()delete(diagnosticFile));
    problem2.writeDiagnostics(seeded,diagnosticFile);
    diagnostic = readcell(diagnosticFile,'Sheet','求解诊断');
    assert(string(diagnostic{5,1})=="初始档案最快完成时间（s）");
    assert(abs(diagnostic{5,2}-min(seeded.SeedDiagnostics.Makespan_s))<1e-7);
    clear cleanupDiagnostic;
    newObjectives = [seeded.ParetoFront.Timeliness,seeded.ParetoFront.Makespan_s, ...
        seeded.ParetoFront.Energy_kWh,seeded.ParetoFront.TripCount];
    for k = 1:numel(old.paretoArchive.ParetoOutcomes)
        objective = old.paretoArchive.ParetoOutcomes{k}.Objectives;
        assert(any(all(newObjectives <= objective+1e-9,2)), ...
            '继承档案时不能丢失旧解权衡区域。');
    end
end
fprintf('问题二测试全部通过。\n');
end

function testParetoArchive()
solutions = {};
outcomes = {};
first = struct('Feasible',true,'Objectives',[0,8,70,22]);
[solutions,outcomes,status] = problem2.updateParetoArchive( ...
    solutions,outcomes,1,first,10);
assert(status == "added" && numel(outcomes)==1);
dominated = struct('Feasible',true,'Objectives',[0.1,9,71,23]);
[solutions,outcomes,status] = problem2.updateParetoArchive( ...
    solutions,outcomes,2,dominated,10);
assert(status == "dominated" && numel(outcomes)==1);
[solutions,outcomes,status] = problem2.updateParetoArchive( ...
    solutions,outcomes,2,first,10);
assert(status == "duplicate" && numel(outcomes)==1);
tradeoff = struct('Feasible',true,'Objectives',[0.05,7,75,23]);
[solutions,outcomes,status] = problem2.updateParetoArchive( ...
    solutions,outcomes,2,tradeoff,10);
assert(status == "added" && numel(outcomes)==2);
improved = struct('Feasible',true,'Objectives',[0,7.5,69,21]);
[solutions,outcomes,status] = problem2.updateParetoArchive( ...
    solutions,outcomes,3,improved,10);
assert(status == "added" && numel(outcomes)==2 && ...
    isequal(sort(cell2mat(solutions)),[2,3]));
end
