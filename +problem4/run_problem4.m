function result=run_problem4(config)
%RUN_PROBLEM4 固定问题三折中方案的分区及资源配置标准入口。
if nargin<1, config=struct(); end
result=problem4.solveProblem4(config);
fprintf('问题四：%d 个不可拆任务块，%d 个两组候选，%d 个三组候选。\n', ...
    numel(result.Blocks),nnz(result.Summary.K==2),nnz(result.Summary.K==3));
disp(result.Summary);
end
