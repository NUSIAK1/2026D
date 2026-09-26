function result = run_optimization(config)
%RUN_OPTIMIZATION 输入快照、独立输出及限时联合优化；不覆盖任何既有问题三解。
if nargin<1, config=struct(); end
p=common.projectPaths();
assert(isfield(config,'SeedResultDir') && isfolder(config.SeedResultDir), ...
    '必须通过 SeedResultDir 明确指定本次问题二结果文件夹。');
d=struct('TimeLimit_s',6600,'NumRuns',8,'MaxIterations',100000, ...
    'StagnationLimit',100000,'ArchiveSize',inf,'RandomSeed',20260926, ...
    'GapSampleStep_s',1,'CommMinInterval_s',0.001,'CommMaxDepth',30, ...
    'RelayBeamWidth',48,'MaxCoverageRepairs',4,'ExportFiles',true, ...
    'ExportFigures',true,'ProgressEvery',10, ...
    'FlightBaseFile',p.FlightBaseFile,'SeedQ3ArchiveFile', ...
    fullfile(p.ResultDir,'问题三_Pareto完整档案.mat'));
for f=string(fieldnames(d)).'
    if ~isfield(config,f), config.(f)=d.(f); end
end
assert(config.TimeLimit_s>0 && config.TimeLimit_s<=6600,'搜索预算应在 (0,6600] 秒内。');
if ~isfield(config,'ExperimentDir')
    [~,tag]=fileparts(tempname);
    config.ExperimentDir=fullfile(p.ResultDir,'问题三_优化实验', ...
        [char(datetime('now','Format','yyyyMMdd_HHmmss')),'_',tag]);
    assert(~isfolder(config.ExperimentDir),'输出目录已存在。');
    mkdir(config.ExperimentDir);
end
config.ResultDir=config.ExperimentDir;
inputDir=fullfile(config.ResultDir,'输入快照');
assert(~isfolder(inputDir),'本次目录已有输入快照，拒绝重复运行或覆盖。');
mkdir(inputDir);
q2=dir(fullfile(config.SeedResultDir,'问题二_结果提交_*.xlsx'));
assert(numel(q2)>=1,'指定目录缺少问题二提交簿。');
provenance=struct('SeedResultDir',config.SeedResultDir, ...
    'FlightBaseFile',config.FlightBaseFile,'SeedQ3ArchiveFile',config.SeedQ3ArchiveFile, ...
    'Created',char(datetime('now')));
for k=1:numel(q2)
    copyfile(fullfile(q2(k).folder,q2(k).name),fullfile(inputDir,q2(k).name));
end
copyfile(config.FlightBaseFile,fullfile(inputDir,'flightBase.mat'));
config.FlightBaseFile=fullfile(inputDir,'flightBase.mat');
if strlength(string(config.SeedQ3ArchiveFile))>0 && isfile(config.SeedQ3ArchiveFile)
    copyfile(config.SeedQ3ArchiveFile,fullfile(inputDir,'问题三_旧档案.mat'));
    config.SeedQ3ArchiveFile=fullfile(inputDir,'问题三_旧档案.mat');
else
    config.SeedQ3ArchiveFile="";
end
config.SeedResultDir=inputDir;
config.CheckpointDir=fullfile(config.ResultDir,'检查点');
save(fullfile(inputDir,'输入来源.mat'),'provenance','config');
diary(fullfile(config.ResultDir,'运行日志.txt'));
cleanup=onCleanup(@()diary('off')); %#ok<NASGU>
fprintf('[Q3] 独立输出：%s\n[Q3] 问题二输入：%s\n',config.ResultDir,provenance.SeedResultDir);
fprintf('[Q3] 搜索采样 1 秒；连续区间认证；未能证明可用的区间拒绝入档。\n');
audit=auditSeeds(config);
fid=fopen(fullfile(config.ResultDir,'问题二方案重新核算.json'),'w','n','UTF-8');
assert(fid>=0,'无法记录问题二重新核算结果。');
fprintf(fid,'%s',jsonencode(audit,'PrettyPrint',true)); fclose(fid);
result=problem3.solveProblem3(config);
save(fullfile(config.ResultDir,'优化实验完整记录.mat'),'result','-v7.3');
if isempty(result.ParetoFront)
    error('problem3:NoCertifiedSolution','本轮没有已认证可行解，详见日志及实验记录。');
end
    names=fieldnames(result.Representatives);
    verification=table();
    for k=1:numel(names)
        name=names{k};
        if config.ExportFiles
            report=problem3.verifySubmission(result.Representatives.(name), ...
                result.OutputFiles.Submissions.(name),p.TemplateFile);
            assert(report.Feasible && all(report.Checks.Passed), ...
                sprintf('正式提交簿 %s 回读校核失败。',name));
            check=report.Checks;
            check.Workbook=repmat(string(name),height(check),1);
            verification=[verification;check]; %#ok<AGROW>
        end
    end
    summary=struct('CertifiedSolutionCount',height(result.ParetoFront), ...
        'GapSampleStep_s',config.GapSampleStep_s,'CommMinInterval_s',config.CommMinInterval_s, ...
        'ContinuousCertification',true,'SeedResultDir',provenance.SeedResultDir, ...
        'FlightBaseSource',provenance.FlightBaseFile,'BaselineCount',size(result.BaselineObjectives,1), ...
        'VerificationPassed',true);
    if height(verification)>0
        summary.Verification=table2struct(verification);
    end
fid=fopen(fullfile(config.ResultDir,'最终验收摘要.json'),'w','n','UTF-8');
assert(fid>=0,'无法写入验收摘要。');
fprintf(fid,'%s',jsonencode(summary,'PrettyPrint',true)); fclose(fid);
fprintf('[Q3] 完成：%d 个已认证的非支配方案。\n',height(result.ParetoFront));
disp(result.ParetoFront);
end

function rows=auditSeeds(config)
data=problem3.loadData(config);
seeds=problem3.loadSeeds(config,data);
rows=struct([]);
for k=1:numel(seeds)
    seed=seeds{k};
    file=fullfile(config.SeedResultDir,"问题二_结果提交_"+seed.Source+".xlsx");
    if ~isfile(file), continue; end
    raw=readcell(file,'Sheet','Q2_运输架次'); raw=raw(2:end,:);
    raw=raw(~ismissing(string(raw(:,1))) & string(raw(:,1))~="",:);
    tr=problem3.decodeTransport(seed,data);
    row=struct('Source',seed.Source,'Feasible',tr.Feasible,'Failure',tr.Failure, ...
        'OldEnergy_kWh',sum(cell2mat(raw(:,8))), ...
        'RecomputedEnergy_kWh',NaN,'OldMakespan_s',max(cell2mat(raw(:,7))), ...
        'RecomputedMakespan_s',NaN,'MaxStartShift_s',NaN);
    if tr.Feasible
        row.RecomputedEnergy_kWh=sum(tr.Trips.Energy_kWh);
        row.RecomputedMakespan_s=max(tr.Trips.Return_s);
        [found,order]=ismember(string(raw(:,1)),tr.Trips.TripID);
        assert(all(found),'重新解码后的架次编号不一致。');
        row.MaxStartShift_s=max(abs(tr.Trips.Start_s(order)-cell2mat(raw(:,5))));
    end
    if isempty(rows), rows=row; else, rows(end+1)=row; end %#ok<AGROW>
    fprintf('[Q3] 问题二 %s 重新核算：可行=%d，能耗 %.6f -> %.6f kWh，完成时间 %.3f -> %.3f s。\n', ...
        row.Source,row.Feasible,row.OldEnergy_kWh,row.RecomputedEnergy_kWh, ...
        row.OldMakespan_s,row.RecomputedMakespan_s);
end
end
