function test_problem2()
%TEST_PROBLEM2 问题二的充电模型、热启动和全数据快速回归测试。

assert(abs(problem2.chargeTime(0,100)-100) < 1e-10);
assert(abs(problem2.chargeTime(0.9,100)-35) < 1e-10);
assert(abs(problem2.chargeTime(1,100)) < 1e-10);
assert(abs(problem2.chargeTime(0.9-1e-9,100)-35) < 1e-6);

paths = common.projectPaths();
assert(isfile(paths.DemandFile),'未定位到问题二需求文件。');
assert(isfile(paths.FlightBaseFile),'未定位到飞行基础缓存。');

config = struct('ExportFiles',false,'SaveRunArchive',false, ...
    'ProgressEnabled',false,'NumRuns',1,'MaxIterations',3, ...
    'TimeLimit_s',120,'StagnationLimit',3,'ArchiveSize',20,'Verbose',false);
result = problem2.solveProblem2(config);
assert(height(result.Selected.Deliveries)==80,'必须输出 80 个货箱。');
assert(numel(unique(result.Selected.Deliveries.BoxID))==80,'每个货箱必须恰好一次。');
assert(all(result.Validation.Passed),'问题二冒烟测试校核未通过。');
assert(result.Selected.Objectives.TripCount <= 25, ...
    '问题一热启动与硬时限修复后，快速回归方案应不超过 25 趟。');
assert(all(result.ParetoFront.TripCount <= 25), ...
    '快速回归 Pareto 档案不应退化回 60--70 趟单箱架次区域。');
fprintf('问题二测试全部通过。\n');
end
