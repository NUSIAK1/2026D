function resultQ2 = run_problem2(config)
%RUN_PROBLEM2 问题二：异构无人机多点多架次运输调度标准入口。

if nargin < 1
    config = struct();
end

resultQ2 = problem2.solveProblem2(config);

fprintf('\n问题二求解完成，已生成五类代表方案。\n');
names = fieldnames(resultQ2.Representatives);
for k = 1:numel(names)
    x = resultQ2.Representatives.(names{k}).Objectives;
    fprintf('%s：及时性 %.9f | 完成时间 %.3f s | 能耗 %.6f kWh | 架次 %d\n', ...
        names{k},x.Timeliness,x.Makespan_s,x.Energy_kWh,x.TripCount);
end
fprintf('Pareto 方案数：%d\n', height(resultQ2.ParetoFront));

for k = 1:numel(names)
    if ~all(resultQ2.Representatives.(names{k}).Validation.Passed)
        warning('问题二代表方案 %s 存在未通过校核。',names{k});
    end
end
end
