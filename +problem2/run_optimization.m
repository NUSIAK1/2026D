function result = run_optimization(config)
%RUN_OPTIMIZATION 从旧 Pareto 档案继续优化；每次创建全新目录，不覆盖旧解。
if nargin < 1, config = struct(); end
paths = common.projectPaths();
defaults = struct('TimeLimit_s',3600,'NumRuns',10,'MaxIterations',100000, ...
    'StagnationLimit',100000,'RestartEvery',100,'ArchiveSize',inf, ...
    'InitialTemperature',0.02,'FinalTemperature',0.0003,'WorseAcceptanceCap',0.10, ...
    'SeedArchiveFile',fullfile(paths.ResultDir,'问题二_Pareto完整档案.mat'), ...
    'RandomSeed',20260925,'SaveRunArchive',true,'ExportFiles',true, ...
    'ProgressEvery',25,'ExportParetoArchive',true);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(config,names{k}), config.(names{k}) = defaults.(names{k}); end
end
assert(isfinite(config.TimeLimit_s) && config.TimeLimit_s > 0 && ...
    config.TimeLimit_s <= 7200,'优化搜索预算必须在 (0,7200] 秒内。');
assert(isfile(config.SeedArchiveFile),'未找到初始 Pareto 档案。');
% 完整继承档案需要不截断；否则拥挤度剪枝可能遗失旧解的权衡区域。
config.ArchiveSize = inf;
parent = fullfile(paths.ResultDir,'问题二_优化实验');
if ~isfolder(parent), mkdir(parent); end
[~,suffix] = fileparts(tempname);
config.ResultDir = fullfile(parent,[char(datetime('now','Format','yyyyMMdd_HHmmss')),'_',suffix]);
assert(~isfolder(config.ResultDir),'实验目录已存在，拒绝覆盖。');
mkdir(config.ResultDir);
config.CheckpointDir = fullfile(config.ResultDir,'检查点');
diary(fullfile(config.ResultDir,'运行日志.txt'));
cleanDiary = onCleanup(@()diary('off')); %#ok<NASGU>
fprintf('独立优化输出：%s\n初始档案（只读）：%s\n',config.ResultDir,config.SeedArchiveFile);
source = load(config.SeedArchiveFile,'paretoArchive');
old = vertcat(source.paretoArchive.ParetoOutcomes{:});
oldObjectives = vertcat(old.Objectives);
result = problem2.run_problem2(config);
new = vertcat(result.ParetoOutcomes{:});
newObjectives = vertcat(new.Objectives);
covered = false(size(oldObjectives,1),1);
improved = covered;
for k = 1:size(oldObjectives,1)
    noWorse = all(newObjectives <= oldObjectives(k,:)+1e-9,2);
    covered(k) = any(noWorse);
    improved(k) = any(noWorse & any(newObjectives < oldObjectives(k,:)-1e-9,2));
end
assert(all(covered),'新档案未覆盖旧档案的全部权衡区域。');
for k = 1:size(newObjectives,1)
    other = [1:k-1,k+1:size(newObjectives,1)];
    assert(~any(all(abs(newObjectives(other,:)-newObjectives(k,:)) <= 1e-9,2)), ...
        '新档案含重复目标点。');
    assert(~any(all(newObjectives(other,:) <= newObjectives(k,:)+1e-9,2) & ...
        any(newObjectives(other,:) < newObjectives(k,:)-1e-9,2)), '新档案含被支配点。');
    sol = result.ParetoSolutions{k};
    assert(isequal(sort([sol.Trips.BoxIdx]),1:80) && new(k).Feasible, ...
        '档案货箱覆盖或可行性校核失败。');
end
names = fieldnames(result.Representatives);
for k = 1:numel(names)
    rep = result.Representatives.(names{k});
    assert(all(rep.Validation.Passed),'代表方案校核未通过。');
    if config.ExportFiles
        file = result.OutputFiles.Submissions.(names{k});
        trips = sortrows(rep.Trips,{'Start_s','TripID'});
        delivery = sortrows(rep.Deliveries,'BoxID');
        verifySheet(file,'Q2_运输架次',table2cell(trips(:, ...
            {'TripID','DroneID','Model','BatteryID','Start_s','Route','Return_s','Energy_kWh'})));
        verifySheet(file,'Q2_逐箱交付',table2cell(delivery(:, ...
            {'BoxID','TripID','ServiceID','Delivery_s'})));
    end
end
result.BaselineComparison = table((1:numel(covered)).',covered,improved, ...
    'VariableNames',{'OldSolutionIndex','Covered','StrictlyDominated'});
result.ExtremeComparison = table(["及时性";"完成时间_s";"能耗_kWh";"架次数"], ...
    min(oldObjectives,[],1).',min(newObjectives,[],1).', ...
    'VariableNames',{'Objective','Before','After'});
disp(result.ExtremeComparison);
fprintf('旧档案 %d 个方案全部被覆盖，其中 %d 个被新方案严格支配。\n',numel(covered),nnz(improved));
% 保存完整实验记录，包含算子耗时、旧方案比较和验证状态。
save(fullfile(config.ResultDir,'优化实验完整记录.mat'),'result','-v7.3');
writetable(result.ExtremeComparison,fullfile(config.ResultDir,'新旧方案对比.xlsx'),'Sheet','目标极值');
writetable(result.BaselineComparison,fullfile(config.ResultDir,'新旧方案对比.xlsx'),'Sheet','旧解覆盖');
summary = struct('Passed',true,'SeedCount',size(oldObjectives,1), ...
    'ArchiveCount',size(newObjectives,1),'Covered',nnz(covered), ...
    'StrictlyDominated',nnz(improved),'RepresentativeCount',numel(names), ...
    'SubmissionReadbackPassed',logical(config.ExportFiles), ...
    'SearchElapsed_s',result.SearchElapsed_s);
fid = fopen(fullfile(config.ResultDir,'最终验收摘要.json'),'w','n','UTF-8');
assert(fid >= 0,'无法写入验收摘要。');
cleanup = onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s',jsonencode(summary,PrettyPrint=true));
end

function verifySheet(file,sheet,expected)
actual = readcell(file,'Sheet',sheet,'Range',sprintf('A2:%s%d', ...
    char('A'+size(expected,2)-1),size(expected,1)+1));
assert(isequal(size(actual),size(expected)),'提交表回读维度不一致。');
for k = 1:numel(expected)
    if isnumeric(expected{k})
        assert(isnumeric(actual{k}) && abs(actual{k}-expected{k}) < 1e-7, ...
            '提交表数值回读不一致。');
    else
        assert(string(actual{k}) == string(expected{k}),'提交表文本回读不一致。');
    end
end
end
