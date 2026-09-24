function resultQ1 = run_problem1(config)
%RUN_PROBLEM1 问题一动态规划 + Pareto 前沿完整求解入口。

if nargin < 1
    config = struct();
end

resultQ1 = problem1.solveProblem1Pareto(config);

fprintf('\n问题一求解完成。\n');
fprintf('基准安全余量：%.0f%%\n',100*resultQ1.Config.BaselineRatio);
fprintf('主方案架次数：%d\n',resultQ1.Selected.Objectives.N);
fprintf('主方案总能耗：%.9f kWh\n',resultQ1.Selected.Objectives.E_kWh);
fprintf('主方案累计作业时间：%.3f s\n',resultQ1.Selected.Objectives.T_s);
fprintf('全局 Pareto 方案数：%d\n',height(resultQ1.GlobalFront));
fprintf('结果提交文件：%s\n',resultQ1.OutputFiles.Submission);
fprintf('分析结果文件：%s\n',resultQ1.OutputFiles.Analysis);

if ~all(resultQ1.Validation.Passed)
    warning('部分校核未通过，请查看 resultQ1.Validation。');
end
end
