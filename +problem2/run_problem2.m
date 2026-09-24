function resultQ2 = run_problem2(config)
%RUN_PROBLEM2 问题二：异构无人机多点多架次运输调度标准入口。

if nargin < 1
    config = struct();
end

resultQ2 = problem2.solveProblem2(config);

fprintf('\n问题二求解完成。\n');
fprintf('主方案及时性目标：%.9f\n', resultQ2.Selected.Objectives.Timeliness);
fprintf('主方案完成时间：%.3f s\n', resultQ2.Selected.Objectives.Makespan_s);
fprintf('主方案总能耗：%.6f kWh\n', resultQ2.Selected.Objectives.Energy_kWh);
fprintf('主方案架次数：%d\n', resultQ2.Selected.Objectives.TripCount);
fprintf('Pareto 方案数：%d\n', numel(resultQ2.ParetoFront));

if ~all(resultQ2.Validation.Passed)
    warning('问题二存在未通过的校核，请查看 resultQ2.Validation。');
end
end
