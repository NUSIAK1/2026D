function result = solveProblem3(config)
%SOLVEPROBLEM3 五目标联合 ALNS、连续通信认证和正式结果生成。
if nargin<1, config=struct(); end
config=defaults(config);
clock=tic;
config.DeadlineClock=clock; config.DeadlineSeconds=config.TimeLimit_s;
data=problem3.loadData(config);
seeds=problem3.loadSeeds(config,data);
rng(config.RandomSeed,'twister');
archiveSolutions={}; archiveOutcomes={};
baselineObjectives=zeros(0,5);
runRows=cell(0,1);
operatorRows=cell(0,1);
try
    % 旧问题三只作为热启动；按本轮物理数据重新解码并重新认证，不能直接信任旧目标值。
    warmSeeds={};
    if strlength(string(config.SeedQ3ArchiveFile))>0 && isfile(config.SeedQ3ArchiveFile)
        old=load(config.SeedQ3ArchiveFile,'saved');
        if isfield(old,'saved') && isfield(old.saved,'ParetoSolutions')
        for k=1:numel(old.saved.ParetoSolutions)
            problem3.checkDeadline(config);
            prev=old.saved.ParetoSolutions{k};
            tr=problem3.decodeTransport(prev.Solution,data);
            if ~tr.Feasible, continue; end
                % 即使旧中继位置已不适用于新 DEM，其运输时序仍可供重新规划中继。
                warmSeed=prev.Solution;
                warmSeed.Source="旧问题三运输时序";
                warmSeeds{end+1}=warmSeed; %#ok<AGROW>
                refreshed=problem3.recomputeRelay(prev.Relay,data);
            [rp,oc]=certifiedCandidate(prev.Solution,tr,refreshed,data,config);
            if oc.Feasible
                [archiveSolutions,archiveOutcomes,~]=problem3.updateParetoArchive( ...
                    archiveSolutions,archiveOutcomes,rp,oc,config.ArchiveSize);
                saveCheckpoint(config,archiveSolutions,archiveOutcomes,runRows,operatorRows);
            end
        end
        for k=1:numel(archiveOutcomes)
            baselineObjectives(end+1,:)=archiveOutcomes{k}.Objectives; %#ok<AGROW>
        end
            fprintf('[Q3] 旧问题三经本轮数据重新认证，保留 %d 个非支配方案。\n',numel(archiveOutcomes));
        end
    end
    if ~isempty(warmSeeds)
        seeds=[warmSeeds(:);seeds(:)];
    end
for run=1:config.NumRuns
    if toc(clock)>=config.TimeLimit_s, break; end
    runClock=tic;
    runBudget_s=max(0,(config.TimeLimit_s-toc(clock))/(config.NumRuns-run+1));
    rng(config.RandomSeed+run-1,'twister');
    seed=seeds{mod(run-1,numel(seeds))+1};
    % 从已认证前沿重启，避免所有预算重复花在不可行的初始排程上。
    if mod(run,3)==0 && ~isempty(archiveSolutions)
        seed=archiveSolutions{randi(numel(archiveSolutions))}.Solution;
    end
    config.RelaySelectionProfile=mod(run-1,3)+1;
    if config.Verbose
        fprintf('[Q3] 运行 %d/%d，初始来源 %s。\n',run,config.NumRuns,seed.Source);
    end
    transport=problem3.decodeTransport(seed,data);
    if ~transport.Feasible
        runRows{end+1,1}=logRow(run,0,0,numel(archiveOutcomes),toc(clock), ...
            "运输初始解不可行："+transport.Failure); %#ok<AGROW>
        continue;
    end
    relay=problem3.planCertifiedRelay(transport,data,config);
    pre=relay.Precompute;
    [rep,outcome]=certifiedCandidate(seed,transport,relay,data,config);
    if outcome.Feasible
        [archiveSolutions,archiveOutcomes,~]=problem3.updateParetoArchive( ...
            archiveSolutions,archiveOutcomes,rep,outcome,config.ArchiveSize);
        saveCheckpoint(config,archiveSolutions,archiveOutcomes,runRows,operatorRows);
    else
        if config.Verbose, fprintf('[Q3] 初始联合方案待修复：%s\n',relay.Failure); end
            searchConfig=config;
            searchConfig.RelayPrecompute=pre;
            searchConfig.RandomSeed=config.RandomSeed+run-1;
            searchConfig.TimingIterations=min(config.MaxIterations,1200);
        searchConfig.TimeLimit_s=max(0,runBudget_s-toc(runClock));
        q=problem3.searchTiming(seed,data,searchConfig);
        if q.Feasible
            seed=q.Solution; transport=q.Transport; relay=q.Relay;
            pre=relay.Precompute;
            [rep,outcome]=certifiedCandidate(seed,transport,relay,data,config);
            if outcome.Feasible
                [archiveSolutions,archiveOutcomes,~]=problem3.updateParetoArchive( ...
                    archiveSolutions,archiveOutcomes,rep,outcome,config.ArchiveSize);
                saveCheckpoint(config,archiveSolutions,archiveOutcomes,runRows,operatorRows);
            end
        elseif isfield(q,'Solution') && ~isequaln(q.Solution,seed)
            resumeSeed=q.Solution;
            resumeSeed.Source=seed.Source+"（继续修复）";
            seeds{end+1}=resumeSeed; %#ok<AGROW>
        end
    end
    if ~outcome.Feasible
        runRows{end+1,1}=logRow(run,0,0,numel(archiveOutcomes),toc(clock), ...
            "未找到经认证的初始解"); %#ok<AGROW>
        continue;
    end
    current=seed; currentRep=rep; currentObj=outcome.Objectives;
    currentPre=pre; accepted=0; stagnant=0; used=0;
    operatorBase=[repmat(90/7,1,7),repmat(10/5,1,5)];
    operatorWeights=operatorBase;
    operatorAttempts=zeros(1,12); operatorFeasible=zeros(1,12);
    operatorAdded=zeros(1,12);
    for it=1:config.MaxIterations
        if toc(clock)>=config.TimeLimit_s || toc(runClock)>=runBudget_s || ...
                stagnant>=config.StagnationLimit
            break;
        end
        used=it;
        if ~isempty(currentRep.Relay.RelayTrips)
            % 联合完成时间导向：以较大概率扰动决定完工时刻的最晚返航架次。
            [~,lastIdx]=max(currentRep.Transport.Trips.Return_s);
            if rand<0.7
                critical=currentRep.Transport.Trips.TripID(lastIdx);
            else
                critical=currentRep.Transport.Trips.TripID(randi(height(currentRep.Transport.Trips)));
            end
        else
            critical="";
        end
        op=roulette(operatorWeights);
        operatorAttempts(op)=operatorAttempts(op)+1;
        [candidate,geometryChanged]=problem3.perturbSolution(current,data,critical,op);
        if isequaln(candidate,current)
            stagnant=stagnant+1; continue;
        end
        candT=problem3.decodeTransport(candidate,data);
        if ~candT.Feasible
            operatorWeights(op)=adapt(operatorWeights(op),operatorBase(op),0);
            stagnant=stagnant+1; continue;
        end
        trialConfig=config;
        if ~geometryChanged, trialConfig.RelayPrecompute=currentPre; end
        candR=problem3.planCertifiedRelay(candT,data,trialConfig);
        if ~candR.Feasible
            operatorWeights(op)=adapt(operatorWeights(op),operatorBase(op),0);
            stagnant=stagnant+1; continue;
        end
        [candRep,candOutcome]=certifiedCandidate(candidate,candT,candR,data,config);
        if ~candOutcome.Feasible
            operatorWeights(op)=adapt(operatorWeights(op),operatorBase(op),0);
            stagnant=stagnant+1; continue;
        end
        operatorFeasible(op)=operatorFeasible(op)+1;
        [archiveSolutions,archiveOutcomes,status]=problem3.updateParetoArchive( ...
            archiveSolutions,archiveOutcomes,candRep,candOutcome,config.ArchiveSize);
        if status=="added"
            saveCheckpoint(config,archiveSolutions,archiveOutcomes,runRows,operatorRows);
            stagnant=0; operatorAdded(op)=operatorAdded(op)+1;
            operatorWeights(op)=adapt(operatorWeights(op),operatorBase(op),3);
        else
            stagnant=stagnant+1;
            operatorWeights(op)=adapt(operatorWeights(op),operatorBase(op),1);
        end
        profile=mod(run-1,6)+1;
        oldScore=weighted(currentObj,profile);
        newScore=weighted(candOutcome.Objectives,profile);
        temp=max(0.002,0.04*(1-toc(runClock)/max(1,runBudget_s)));
        if newScore<=oldScore || rand<min(0.15,exp((oldScore-newScore)/temp))
            current=candidate; currentRep=candRep;
            currentObj=candOutcome.Objectives;
            currentPre=candR.Precompute;
            accepted=accepted+1;
        end
        if config.Verbose && (mod(it,config.ProgressEvery)==0 || status=="added")
            fprintf('[Q3] run %d iter %d | Pareto %d | %.0f s\n', ...
                run,it,numel(archiveOutcomes),toc(clock));
        end
    end
    runRows{end+1,1}=logRow(run,used,accepted,numel(archiveOutcomes),toc(clock), ...
        "完成"); %#ok<AGROW>
    for op=1:12
        operatorRows{end+1,1}=table(run,op,operatorAttempts(op), ...
            operatorFeasible(op),operatorAdded(op),operatorWeights(op), ...
            'VariableNames',{'Run','Operator','Attempts','Feasible', ...
            'ArchiveAdded','FinalWeight'}); %#ok<AGROW>
    end
end
catch ME
    if strcmp(ME.identifier,'problem3:TimeLimit')
        fprintf('[Q3] 搜索预算结束，导出 %d 个已认证方案。\n',numel(archiveOutcomes));
    else
        rethrow(ME);
    end
end
config=rmfield(config,{'DeadlineClock','DeadlineSeconds'});
result=struct('Config',config,'ParetoSolutions',{archiveSolutions}, ...
    'ParetoOutcomes',{archiveOutcomes},'RunLog',table(),'OperatorLog',table(), ...
    'ParetoFront',table(),'Representatives',struct(),'OutputFiles',struct());
result.BaselineObjectives=baselineObjectives;
if ~isempty(runRows), result.RunLog=vertcat(runRows{:}); end
if ~isempty(operatorRows), result.OperatorLog=vertcat(operatorRows{:}); end
if isempty(archiveOutcomes)
    result.Diagnostics="未找到满足全部硬约束且通过连续通信认证的方案";
    if config.Verbose, warning('%s',result.Diagnostics); end
    return;
end
result.ParetoFront=makeParetoTable(archiveOutcomes);
idx=representatives(archiveOutcomes);
names=fieldnames(idx);
for k=1:numel(names)
    result.Representatives.(names{k})=archiveSolutions{idx.(names{k})};
end
result.ParetoFront.IsSelected(result.ParetoFront.SolutionID==idx.Balanced)=true;
if config.ExportFiles
    result.OutputFiles=problem3.exportResults(result,data,config);
end
end

function c=defaults(c)
p=common.projectPaths();
d=struct('FlightBaseFile',p.FlightBaseFile,'DemandFile',p.DemandFile, ...
    'TransportUavFile',p.TransportUavFile, ...
    'RelayUavFile',fullfile(p.BaseDataDir,'中继无人机数据.xlsx'), ...
    'CommFile',fullfile(p.BaseDataDir,'通信链路参数.xlsx'), ...
    'DemFile',p.DemFile,'TemplateFile',p.TemplateFile,'ResultDir',p.ResultDir, ...
    'RandomSeed',2026,'NumRuns',10,'MaxIterations',2500, ...
    'TimeLimit_s',3600,'StagnationLimit',800,'ArchiveSize',200, ...
    'CommMaxDepth',30,'CommMinInterval_s',0.001, ...
    'GapSampleStep_s',1,'RelayBeamWidth',36, ...
    'MaxCoverageRepairs',4,'SeedQ3ArchiveFile',"",'CheckpointDir',"", ...
    'ExportFiles',true,'ExportFigures',true,'ProgressEvery',100, ...
    'Verbose',true);
fields=fieldnames(d);
for i=1:numel(fields)
    if ~isfield(c,fields{i}) || isempty(c.(fields{i}))
        c.(fields{i})=d.(fields{i});
    end
end
end

function [rep,outcome]=certifiedCandidate(solution,T,R,data,config)
outcome=struct('Feasible',false,'Objectives',inf(1,5));
rep=struct();
if ~R.Feasible, return; end
R=rmfield(R,intersect(fieldnames(R), ...
    {'Precompute','CandidatePoints','Capability','Gaps'}));
rep=struct('Solution',solution,'Transport',T,'Relay',R, ...
    'Coverage',table());
val=problem3.validateProblem3(rep,data,config);
if ~val.Feasible, return; end
rep.Coverage=val.Coverage;
rep.Validation=val;
outcome=struct('Feasible',true,'Objectives',val.Objectives);
end

function saveCheckpoint(config,solutions,outcomes,runRows,operatorRows)
if strlength(string(config.CheckpointDir))==0 || isempty(outcomes), return; end
if ~isfolder(config.CheckpointDir), mkdir(config.CheckpointDir); end
c=rmfield(config,{'DeadlineClock','DeadlineSeconds'});
saved=struct('Config',c,'ParetoSolutions',{solutions},'ParetoOutcomes',{outcomes}, ...
    'RunRows',{runRows},'OperatorRows',{operatorRows});
temporary=fullfile(config.CheckpointDir,'pending.mat');
save(temporary,'saved','-v7.3');
movefile(temporary,fullfile(config.CheckpointDir,'最新已认证档案.mat'),'f');
end

function s=weighted(x,profile)
scale=[0.1,8000,70,20,3];
weights=0.05*ones(1,5);
if profile<=5
    weights(profile)=0.8;
else
    weights=0.2*ones(1,5);
end
s=sum(weights.*x./scale);
end

function index=roulette(weights)
c=cumsum(weights/sum(weights));
index=find(rand<=c,1);
if isempty(index), index=numel(weights); end
end

function value=adapt(old,base,reward)
value=max(0.3*base,0.97*old+0.03*base*(0.5+reward));
end

function row=logRow(run,iterations,accepted,count,elapsed,status)
row=table(run,iterations,accepted,count,elapsed,string(status), ...
    'VariableNames',{'Run','Iterations','Accepted','ArchiveSize','Elapsed_s','Status'});
end

function T=makeParetoTable(outcomes)
n=numel(outcomes); x=zeros(n,5);
for k=1:n, x(k,:)=outcomes{k}.Objectives; end
T=table((1:n)',x(:,1),x(:,2),x(:,3),x(:,4),x(:,5),false(n,1), ...
    'VariableNames',{'SolutionID','Timeliness','JointMakespan_s', ...
    'TotalEnergy_kWh','TransportTripCount','RelayTripCount','IsSelected'});
T=sortrows(T,{'Timeliness','JointMakespan_s','TotalEnergy_kWh', ...
    'TransportTripCount','RelayTripCount'});
end

function idx=representatives(outcomes)
n=numel(outcomes); x=zeros(n,5);
for k=1:n, x(k,:)=outcomes{k}.Objectives; end
names={'TimelinessFirst','MakespanFirst','EnergyFirst', ...
    'TransportTripsFirst','RelayTripsFirst'};
idx=struct();
for j=1:5
    [~,order]=sortrows(x,[j,setdiff(1:5,j,'stable')]);
    idx.(names{j})=order(1);
end
minX=min(x,[],1); maxX=max(x,[],1);
span=maxX-minX; span(span<1e-12)=1;
z=(x-minX)./span;
[~,order]=sortrows([max(z,[],2),sum(z,2),z,x]);
idx.Balanced=order(1);
end
