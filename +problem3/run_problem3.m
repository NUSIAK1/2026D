function resultQ3 = run_problem3(config)
%RUN_PROBLEM3 问题三运输与中继联合调度标准入口。
if nargin<1, config=struct(); end
resultQ3=problem3.solveProblem3(config);
if ~isempty(resultQ3.ParetoFront)
    fprintf('问题三：%d 个已认证可行的非支配方案。\n',height(resultQ3.ParetoFront));
end
end
