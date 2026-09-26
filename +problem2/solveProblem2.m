function result = solveProblem2(config)
%SOLVEPROBLEM2 多点组批、路径、机队和共享电池联合调度。
%
% 本实现以 MOALNS 搜索组批/路径/机型/派发顺序，并通过事件驱动
% 解码器分配实体无人机和电池。所有航段物理量均由 common.calcLegCost
% 预计算，避免复制问题一已验证的能耗口径。

if nargin < 1, config = struct(); end
config = applyDefaults(config);
rng(config.RandomSeed,'twister');
overallClock = tic;

paths = common.projectPaths();
if ~isfile(config.FlightBaseFile)
    error('未找到 flightBase.mat，请先运行 common.computeTerrainMatrices()。');
end
S = load(config.FlightBaseFile);
data = loadProblemData(config, S);
base = precomputeLegs(data, S, config.Verbose);
warmStart = loadExternalWarmStart(data,base,config);

archiveSolutions = {};
archiveOutcomes = {};
seedDiagnostics = table();
seedReevaluation = table();
if strlength(string(config.SeedArchiveFile)) > 0
    seed = load(config.SeedArchiveFile,'paretoArchive');
    assert(isfield(seed,'paretoArchive'),'初始档案缺少 paretoArchive。');
    old = seed.paretoArchive;
    seedObjectives = zeros(numel(old.ParetoSolutions),4);
    originalObjectives = zeros(size(seedObjectives));
    seedFeasible = false(size(seedObjectives,1),1);
    seedViolation = zeros(size(seedFeasible));
    for k = 1:numel(old.ParetoSolutions)
        sol = old.ParetoSolutions{k};
        assert(isequal(sort(sol.Order),1:numel(sol.Trips)), '旧档案派发顺序无效。');
        assert(isequal(sort([sol.Trips.BoxIdx]),1:height(data.Boxes)), '旧档案货箱覆盖无效。');
        out = decodeSolution(sol,data,base);
        if config.SeedEvaluationMode == "strict"
        assert(out.Feasible,'旧档案第 %d 个方案在当前口径下不可行。',k);
        assert(max(abs(out.Objectives-old.ParetoOutcomes{k}.Objectives)) < 1e-7, ...
            ['旧档案第 %d 个方案的重算目标不一致，停止优化。\n' ...
            '旧目标 [及时性,秒,kWh,架次]=%s\n当前目标=%s\n地形缓存=%s'], ...
            k,mat2str(old.ParetoOutcomes{k}.Objectives,12), ...
            mat2str(out.Objectives,12),char(config.FlightBaseFile));
        assert(isequaln(out.Deliveries,old.ParetoOutcomes{k}.Deliveries) && ...
            isequaln(out.Trips,old.ParetoOutcomes{k}.Trips), '旧方案逐箱或逐架次重算不一致。');
        end
        seedObjectives(k,:) = out.Objectives;
        originalObjectives(k,:) = old.ParetoOutcomes{k}.Objectives;
        seedFeasible(k) = out.Feasible;
        seedViolation(k) = out.Violation;
        [archiveSolutions,archiveOutcomes] = problem2.updateParetoArchive( ...
            archiveSolutions,archiveOutcomes,sol,out,inf);
    end
    seedReevaluation = table((1:numel(seedFeasible)).',seedFeasible,seedViolation, ...
        originalObjectives,seedObjectives,seedObjectives-originalObjectives, ...
        'VariableNames',{'OriginalIndex','Feasible','Violation','OriginalObjectives', ...
        'RecomputedObjectives','ObjectiveDelta'});
    assert(any(seedFeasible),'旧档案在当前地形下没有可行方案，不能继续增量优化；需重新构造初始方案。');
    seedDiagnostics = array2table(seedObjectives(seedFeasible,:),'VariableNames', ...
        {'Timeliness','Makespan_s','Energy_kWh','TripCount'});
    config.BaselineMakespan_s = min(seedObjectives(seedFeasible,2));
    fprintf('[Q2] 旧档案重算完成：%d/%d 可行；基线采用当前地形重算目标。模式：%s\n', ...
        nnz(seedFeasible),numel(seedFeasible),config.SeedEvaluationMode);
    if config.ExportFiles
        writetable(seedReevaluation,fullfile(config.ResultDir,'旧档案地形重算审计.xlsx'));
    end
end
runLog = table();
% 数值缓冲区按块增长，避免每次迭代拼接整张历史表。
convergenceRows = zeros(4096,10);
convergenceProfiles = strings(4096,1);
operatorLog = table();
operatorNames = ["随机小破坏","服务区重组","低利用率重组","机型重分配", ...
    "访问顺序","派发顺序","瓶颈拆分","货箱迁移交换"];
operatorCounts = zeros(numel(operatorNames),8);
operatorElapsed = zeros(numel(operatorNames),1);
operatorNoop = zeros(numel(operatorNames),1);
operatorImproved = zeros(numel(operatorNames),1);
neighborhoodEvaluated = zeros(numel(operatorNames),1);
neighborhoodFeasible = zeros(numel(operatorNames),1);
neighborhoodAdded = zeros(numel(operatorNames),1);
localSolutions = {}; localOutcomes = {}; localAdded = 0;
completedIterations = 0;
plannedIterations = config.NumRuns*config.MaxIterations;

for runIdx = 1:config.NumRuns
    if toc(overallClock) >= config.TimeLimit_s
        break;
    end
    if config.ProgressEnabled
        fprintf('[Q2] 开始 ALNS 第 %d/%d 次独立运行（最多 %d 次迭代）。\n', ...
            runIdx,config.NumRuns,config.MaxIterations);
    end
    rng(config.RandomSeed+runIdx-1,'twister');
    profile = config.RunProfiles(mod(runIdx-1,numel(config.RunProfiles))+1);
    if ~isempty(archiveSolutions)
        ranked = rankOutcomes(archiveOutcomes,profile);
        seedIdx = ranked(1);
        current = archiveSolutions{seedIdx};
    else
        current = buildInitialSolution(data, base, config, profile, runIdx, warmStart);
    end
    seedTripCount = numel(current.Trips);
    current = repairHardDeadlines(current, data, base, config);
    currentOutcome = decodeSolution(current, data, base);
    if ~currentOutcome.Feasible && warmStart.Enabled
        current = warmStart.Solution;
        currentOutcome = decodeSolution(current,data,base);
    end
    [archiveSolutions,archiveOutcomes,~] = problem2.updateParetoArchive( ...
        archiveSolutions, archiveOutcomes, current, currentOutcome, config.ArchiveSize);

    destroyScore = ones(1,numel(operatorNames));
    segmentReward = zeros(size(destroyScore));
    segmentUses = zeros(size(destroyScore));
    segmentSeconds = zeros(size(destroyScore));
    stagnant = 0;
    accepted = 0;
    runClock = tic;
    runBudget_s = max(0,(config.TimeLimit_s-toc(overallClock))/ ...
        (config.NumRuns-runIdx+1));
    actualIterations = 0;
    for iter = 1:config.MaxIterations
        if toc(overallClock) >= config.TimeLimit_s || toc(runClock) >= runBudget_s
            break;
        end
        operator = roulette(destroyScore);
        operatorClock = tic;
        localSolutions = {}; localOutcomes = {}; localAdded = 0;
        candidate = perturbSolution(current, data, base, operator, profile,@recordNeighborhood);
        % 小比例探索内部已解码的其他可行结构，交由外层退火决定是否移动。
        if ~isempty(localSolutions) && rand < 0.20
            candidate = localSolutions{randi(numel(localSolutions))};
        end
        if isequaln(candidate,current)
            candidateOutcome = currentOutcome;
        else
            cached = find(cellfun(@(s)isequaln(s,candidate),localSolutions),1);
            if ~isempty(cached)
                candidateOutcome = localOutcomes{cached};
            else
                candidate = repairHardDeadlines(candidate, data, base, config);
                candidateOutcome = decodeSolution(candidate, data, base);
            end
        end
        unchanged = isequaln(candidate,current);
        elapsedOperator_s = toc(operatorClock);
        operatorElapsed(operator) = operatorElapsed(operator)+elapsedOperator_s;
        operatorNoop(operator) = operatorNoop(operator)+unchanged;

        [archiveSolutions,archiveOutcomes,archiveStatus] = problem2.updateParetoArchive( ...
            archiveSolutions, archiveOutcomes, candidate, candidateOutcome, config.ArchiveSize);
        operatorCounts(operator,1) = operatorCounts(operator,1)+1;
        operatorCounts(operator,2) = operatorCounts(operator,2)+candidateOutcome.Feasible;
        switch archiveStatus
            case "dominated", operatorCounts(operator,3) = operatorCounts(operator,3)+1;
            case "duplicate", operatorCounts(operator,4) = operatorCounts(operator,4)+1;
            case "added", operatorCounts(operator,5) = operatorCounts(operator,5)+1;
            case "pruned", operatorCounts(operator,6) = operatorCounts(operator,6)+1;
        end
        if archiveStatus == "added" || localAdded > 0
            stagnant = 0;
        else
            stagnant = stagnant+1;
        end

        % 按本次实际时段降温，避免时间上限先到而温度始终偏高。
        progress = max(iter/config.MaxIterations, ...
            min(1,toc(runClock)/max(runBudget_s,eps)));
        temperature = config.InitialTemperature* ...
            (config.FinalTemperature/config.InitialTemperature)^progress;
        delta = compareOutcomes(candidateOutcome,currentOutcome,profile);
        improved = ~unchanged && candidateOutcome.Feasible && delta < -1e-12;
        operatorImproved(operator) = operatorImproved(operator)+improved;
        reward = 6*((archiveStatus == "added")+localAdded)+3*improved;
        if ~unchanged && acceptCandidate(currentOutcome,candidateOutcome,temperature,profile, ...
                config.WorseAcceptanceCap)
            current = candidate;
            currentOutcome = candidateOutcome;
            accepted = accepted+1;
            operatorCounts(operator,7) = operatorCounts(operator,7)+1;
            if delta > 1e-12
                operatorCounts(operator,8) = operatorCounts(operator,8)+1;
            end
        end
        segmentReward(operator) = segmentReward(operator)+reward;
        segmentUses(operator) = segmentUses(operator)+1;
        segmentSeconds(operator) = segmentSeconds(operator)+elapsedOperator_s;
        if mod(iter,config.AdaptationEvery) == 0
            used = segmentUses > 0;
            % 以每秒收益分配预算，保留探索下限；无变化不算接受或改进。
            utility = segmentReward(used)./max(segmentSeconds(used),0.01);
            if any(utility > 0), utility = utility/max(utility); end
            destroyScore(used) = 0.7*destroyScore(used)+0.3*(0.10+utility);
            segmentReward(:)=0; segmentUses(:)=0; segmentSeconds(:)=0;
        end
        actualIterations = actualIterations+1;
        completedIterations = completedIterations+1;
        [bestObjectives,bestCount] = archiveSummary(archiveOutcomes);
        if completedIterations > size(convergenceRows,1)
            convergenceRows(end+4096,10) = 0;
            convergenceProfiles(end+4096,1) = "";
        end
        convergenceRows(completedIterations,:) = [runIdx,iter,completedIterations, ...
            toc(overallClock),numel(archiveOutcomes),bestCount,bestObjectives];
        convergenceProfiles(completedIterations) = string(profile);
        if config.ProgressEnabled && (iter == 1 || ...
                mod(iter,config.ProgressEvery) == 0 || iter == config.MaxIterations)
            elapsed_s = toc(overallClock);
            rate = completedIterations/max(elapsed_s,eps);
            eta_s = min(max(0,config.TimeLimit_s-elapsed_s), ...
                max(0,(plannedIterations-completedIterations)/rate));
            percent = 100*max(completedIterations/plannedIterations, ...
                min(1,elapsed_s/config.TimeLimit_s));
            fprintf(['[Q2] run %d/%d | iter %d/%d | 总进度 %.1f%% | ' ...
                'Pareto %d | 已耗时 %s | 剩余预算 %s\n'], ...
                runIdx,config.NumRuns,iter,config.MaxIterations, ...
                percent,numel(archiveOutcomes), ...
                formatDuration(elapsed_s),formatDuration(eta_s));
            drawnow limitrate;
        end
        if stagnant >= config.StagnationLimit
            if config.ProgressEnabled
                fprintf('[Q2] 第 %d 次运行因连续 %d 次未改进而提前停止。\n', ...
                    runIdx,stagnant);
            end
            break;
        elseif stagnant > 0 && mod(stagnant,config.RestartEvery) == 0
            current = diversifyRestart(current,archiveSolutions,archiveOutcomes, ...
                profile);
            current = repairHardDeadlines(current,data,base,config);
            currentOutcome = decodeSolution(current,data,base);
        end
    end

    [bestObjectives,bestCount] = archiveSummary(archiveOutcomes);
    runRow = table(runIdx,string(profile),seedTripCount,actualIterations,accepted, ...
        accepted/max(actualIterations,1),currentOutcome.Feasible,currentOutcome.Objectives(1), ...
        currentOutcome.Objectives(2),currentOutcome.Objectives(3), ...
        currentOutcome.Objectives(4),bestObjectives(1),bestObjectives(2), ...
        bestObjectives(3),bestObjectives(4),bestCount, ...
        'VariableNames',{'Run','Profile','SeedTripCount','Iterations','Accepted', ...
        'AcceptanceRate','FinalFeasible','FinalTimeliness','FinalMakespan_s', ...
        'FinalEnergy_kWh','FinalTripCount','BestTimeliness','BestMakespan_s', ...
        'BestEnergy_kWh','BestTripCount','ArchiveSize'});
    runLog = [runLog;runRow]; %#ok<AGROW>
    operatorLog = [operatorLog; table(runIdx,string(profile),destroyScore, ...
        'VariableNames',{'Run','Profile','OperatorWeights'})]; %#ok<AGROW>
    if config.SaveRunArchive
        checkpointFile = saveRunCheckpoint(archiveSolutions,archiveOutcomes, ...
            runLog,config,runIdx,completedIterations,toc(overallClock));
        if config.ProgressEnabled
            fprintf('[Q2] 第 %d 次运行检查点已保存：%s\n',runIdx,checkpointFile);
        end
    end
end

if isempty(archiveOutcomes)
    error(['未找到满足医疗和首批硬时限的可行方案。请增加 MaxIterations，' ...
        '或检查基础数据与 flightBase 是否一致。']);
end

representativeIndices = chooseRepresentatives(archiveOutcomes);
representatives = buildRepresentatives(archiveSolutions,archiveOutcomes, ...
    representativeIndices,data,base);
balancedIndex = representativeIndices.Balanced;

paretoTable = makeParetoTable(archiveOutcomes,balancedIndex);
result = struct();
result.Config = config;
result.DataSummary = table(height(data.Boxes),sum(data.Boxes.Mass_kg), ...
    sum(data.Boxes.Volume_m3),'VariableNames',{'BoxCount','TotalMass_kg','TotalVolume_m3'});
result.Diagnostics = struct( ...
    'MassLowerBound',ceil(sum(data.Boxes.Mass_kg)/max(data.Models.MaxPayload_kg)), ...
    'VolumeLowerBound',ceil(sum(data.Boxes.Volume_m3)/max(data.Models.MaxVolume_m3)), ...
    'PackingSeedTripCount',min(runLog.SeedTripCount), ...
    'BaselineMakespan_s',config.BaselineMakespan_s, ...
    'BestMakespan_s',representatives.MakespanFirst.Objectives.Makespan_s, ...
    'WarmStart',warmStart.Diagnostics);
if warmStart.Enabled
    result.WarmStartBaseline = struct('Solution',warmStart.Solution, ...
        'Outcome',warmStart.Outcome);
else
    result.WarmStartBaseline = struct('Solution',[],'Outcome',[]);
end
result.Representatives = representatives;
result.ParetoFront = paretoTable;
result.ParetoSolutions = archiveSolutions;
result.ParetoOutcomes = archiveOutcomes;
result.RunLog = runLog;
result.ConvergenceLog = array2table(convergenceRows(1:completedIterations,:), ...
    'VariableNames',{'Run','Iteration','CompletedIterations','Elapsed_s', ...
    'ArchiveSize','FeasibleArchiveSize','BestTimeliness','BestMakespan_s', ...
    'BestEnergy_kWh','BestTripCount'});
result.ConvergenceLog = addvars(result.ConvergenceLog, ...
    convergenceProfiles(1:completedIterations),'After','Run','NewVariableNames','Profile');
result.OperatorLog = operatorLog;
result.SeedDiagnostics = seedDiagnostics;
result.SeedReevaluation = seedReevaluation;
result.SearchElapsed_s = toc(overallClock);
result.OperatorDiagnostics = table(operatorNames.',operatorCounts(:,1), ...
    operatorCounts(:,2),operatorCounts(:,3),operatorCounts(:,4), ...
    operatorCounts(:,5),operatorCounts(:,6),operatorCounts(:,7), ...
    operatorCounts(:,8),operatorCounts(:,7)./max(operatorCounts(:,1),1), ...
    'VariableNames',{'Operator','Candidates', ...
    'Feasible','Dominated','Duplicate','Added','Pruned', ...
    'Accepted','AcceptedWorse','AcceptanceRate'});
result.OperatorDiagnostics.Elapsed_s = operatorElapsed;
result.OperatorDiagnostics.Unchanged = operatorNoop;
result.OperatorDiagnostics.ScoreImproved = operatorImproved;
result.OperatorDiagnostics.InternalEvaluated = neighborhoodEvaluated;
result.OperatorDiagnostics.InternalFeasible = neighborhoodFeasible;
result.OperatorDiagnostics.InternalAdded = neighborhoodAdded;
result.OperatorDiagnostics.AddedPerSecond = ...
    (operatorCounts(:,5)+neighborhoodAdded)./max(operatorElapsed,eps);
result.OutputFiles = struct();
if config.ExportFiles
    result.OutputFiles = exportResults(result,data,config);
end

if config.Verbose
    fprintf('问题二：得到 %d 个可行非支配方案，选择方案 %d。\n', ...
        numel(archiveOutcomes), balancedIndex);
end

    function recordNeighborhood(sol,out)
        % 所有内部完整解码候选都经过正式支配筛选；已解码结果直接复用。
        neighborhoodEvaluated(operator) = neighborhoodEvaluated(operator)+1;
        if ~out.Feasible, return; end
        neighborhoodFeasible(operator) = neighborhoodFeasible(operator)+1;
        localSolutions{end+1} = sol;
        localOutcomes{end+1} = out;
        [archiveSolutions,archiveOutcomes,status] = problem2.updateParetoArchive( ...
            archiveSolutions,archiveOutcomes,sol,out,config.ArchiveSize);
        if status == "added"
            localAdded = localAdded+1;
            neighborhoodAdded(operator) = neighborhoodAdded(operator)+1;
        end
    end
end

function config = applyDefaults(config)
paths = common.projectPaths();
defaults = struct( ...
    'AlgorithmVersion',"q2-visible-lexicographic-v4", ...
    'FlightBaseFile',paths.FlightBaseFile, ...
    'DemandFile',paths.DemandFile, ...
    'TransportUavFile',paths.TransportUavFile, ...
    'TemplateFile',paths.TemplateFile, ...
    'ResultDir',paths.ResultDir, ...
    'ExportFiles',true, ...
    'RandomSeed',2026, ...
    'NumRuns',10, ...
    'MaxIterations',2500, ...
    'TimeLimit_s',1200, ...
    'StagnationLimit',800, ...
    'ArchiveSize',200, ...
    'RestartEvery',120, ...
    'InitialTemperature',0.05, ...
    'FinalTemperature',0.002, ...
    'WorseAcceptanceCap',0.25, ...
    'WarmStartTripFile',"", ...
    'WarmStartDeliveryFile',"", ...
    'SeedArchiveFile',"", ...
    'SeedEvaluationMode',"strict", ...
    'AdaptationEvery',40, ...
    'RunProfiles',["timeliness","makespan","energy","trips","balanced"], ...
    'BaselineMakespan_s',9643.64851977594, ...
    'ExportParetoArchive',true, ...
    'ProgressEnabled',true, ...
    'ProgressEvery',100, ...
    'SaveRunArchive',false, ...
    'CheckpointDir',fullfile(paths.ResultDir,'问题二_ALNS检查点'), ...
    'Verbose',true);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(config,names{k}) || isempty(config.(names{k}))
        config.(names{k}) = defaults.(names{k});
    end
end
config.SeedEvaluationMode = string(config.SeedEvaluationMode);
assert(isscalar(config.SeedEvaluationMode) && ...
    any(config.SeedEvaluationMode == ["strict","recompute"]),'无效的旧档案评价模式。');
end

function data = loadProblemData(config, flightBase)
raw = readcell(config.DemandFile,'Sheet','逐箱货箱清单');
valid = ~cellfun(@isempty,raw(:,1));
raw = raw(valid,:);
if size(raw,1) < 2
    error('逐箱货箱清单为空。');
end
raw = raw(2:end,:);
boxes = table(string(raw(:,1)),string(raw(:,2)),string(raw(:,3)), ...
    cell2mat(raw(:,4)),cell2mat(raw(:,5)),string(raw(:,6)), ...
    nanCell2double(raw(:,7)),nanCell2double(raw(:,8)),cell2mat(raw(:,9)), ...
    'VariableNames',{'BoxID','ServiceID','Material','Mass_kg','Volume_m3', ...
    'IsFirst','FirstDeadline_s','ExpectedDeadline_s','Priority'});
boxes.IsMedical = boxes.Material == "医疗物资";
boxes.IsFirst = boxes.IsFirst == "是";
boxes.HardDeadline_s = nan(height(boxes),1);
boxes.HardDeadline_s(boxes.IsMedical) = boxes.ExpectedDeadline_s(boxes.IsMedical);
mask = boxes.IsFirst;
boxes.HardDeadline_s(mask) = minNaN(boxes.HardDeadline_s(mask),boxes.FirstDeadline_s(mask));

uavRaw = readcell(config.TransportUavFile,'Sheet','数据');
isModel = ismember(string(uavRaw(:,1)),["A","B","C"]);
isModel = isModel & cellfun(@(x)isnumeric(x)&&isscalar(x)&&~isnan(x),uavRaw(:,4));
rows = uavRaw(isModel,:);
models = table(string(rows(:,1)),cell2mat(rows(:,4)),cell2mat(rows(:,5)), ...
    cell2mat(rows(:,6)),cell2mat(rows(:,9)),cell2mat(rows(:,10))/100, ...
    cell2mat(rows(:,11)),cell2mat(rows(:,12)),cell2mat(rows(:,13)), ...
    cell2mat(rows(:,14)), ...
    'VariableNames',{'Model','MaxPayload_kg','MaxVolume_m3','CruiseSpeed_mps', ...
    'BatteryUse_kWh','ReserveRatio','PrepTime_s','LoadTimeBox_s', ...
    'HandoverBase_s','HandoverBox_s'});

isDrone = startsWith(string(uavRaw(:,1)),"U");
drones = table(string(uavRaw(isDrone,1)),string(uavRaw(isDrone,2)), ...
    'VariableNames',{'DroneID','Model'});
isBattery = ismember(string(uavRaw(:,1)),["A","B","C"]) & ...
    cellfun(@(x)isnumeric(x)&&isscalar(x)&&~isnan(x),uavRaw(:,2));
bRows = uavRaw(isBattery,:);
batteryModels = string(bRows(:,1));
batteryCounts = cell2mat(bRows(:,2));
batteryCharge = cell2mat(bRows(:,3));
batteryID = strings(0,1); batteryModel = strings(0,1); batteryFull = zeros(0,1);
for g = 1:numel(batteryModels)
    for k = 1:batteryCounts(g)
        batteryID(end+1,1) = sprintf('BAT-%s%02d',batteryModels(g),k); %#ok<AGROW>
        batteryModel(end+1,1) = batteryModels(g); %#ok<AGROW>
        batteryFull(end+1,1) = batteryCharge(g); %#ok<AGROW>
    end
end
batteries = table(batteryID,batteryModel,batteryFull, ...
    'VariableNames',{'BatteryID','Model','FullChargeTime_s'});

data = struct('Boxes',boxes,'Models',models,'Drones',drones,'Batteries',batteries, ...
    'NodeIDs',flightBase.nodes.ID,'Nodes',flightBase.nodes);
end

function base = precomputeLegs(data, flightBase, verbose)
n = numel(data.NodeIDs);
gCount = height(data.Models);
base.Time_s = nan(n,n,gCount);
base.Energy_kWh = nan(n,n,gCount,81);
if verbose, fprintf('问题二：预计算航段时间和能耗查找表...\n'); end
precomputeClock = tic;
for g = 1:gCount
    model = data.Models.Model(g);
    maxQ = floor(data.Models.MaxPayload_kg(g));
    for i = 1:n
        for j = 1:n
            if i == j
                base.Time_s(i,j,g) = 0;
                base.Energy_kWh(i,j,g,1) = 0;
                continue;
            end
            for q = 0:maxQ
                leg = common.calcLegCost(data.NodeIDs(i),data.NodeIDs(j),model,q,flightBase);
                base.Energy_kWh(i,j,g,q+1) = leg.E_total;
                if q == 0, base.Time_s(i,j,g) = leg.T_total; end
            end
        end
    end
    if verbose
        fprintf('[Q2] 航段预计算：机型 %s 完成（%d/%d，已耗时 %s）。\n', ...
            model,g,gCount,formatDuration(toc(precomputeClock)));
        drawnow limitrate;
    end
end
base.NodeIndex = containers.Map(cellstr(data.NodeIDs),num2cell(1:n));
% 每次求解独立缓存，防止需求或机型参数变化时复用旧架次评价。
base.CacheKey = tempname;
end

function warmStart = loadExternalWarmStart(data,base,config)
tripFile = string(config.WarmStartTripFile);
deliveryFile = string(config.WarmStartDeliveryFile);
enabled = strlength(strtrim(tripFile)) > 0 || strlength(strtrim(deliveryFile)) > 0;
emptyDiagnostics = struct('Enabled',false,'TripFile',"",'DeliveryFile',"", ...
    'ImportedTripCount',0,'ImportedBoxCount',0,'InitialFeasible',false, ...
    'InitialObjectives',struct(),'InitialValidation',table(), ...
    'SchedulingFields',"未使用外部热启动");
warmStart = struct('Enabled',false,'Solution',emptySolution(),'Outcome',[], ...
    'Diagnostics',emptyDiagnostics);
if ~enabled, return; end
if strlength(strtrim(tripFile)) == 0 || strlength(strtrim(deliveryFile)) == 0
    error('外部热启动必须同时提供 WarmStartTripFile 和 WarmStartDeliveryFile。');
end
if ~isfile(tripFile)
    error('未找到外部初始解架次文件：%s',tripFile);
end
if ~isfile(deliveryFile)
    error('未找到外部初始解逐箱文件：%s',deliveryFile);
end

tripRows = readWarmStartTripRows(tripFile);
deliveryRows = readWarmStartDeliveryRows(deliveryFile);
if height(tripRows) ~= 22
    error('外部初始解架次文件必须包含 22 条架次，当前读取到 %d 条。',height(tripRows));
end
if numel(unique(tripRows.TripID)) ~= height(tripRows)
    error('外部初始解架次文件含重复架次编号。');
end
if any(~isfinite(tripRows.Start_s) | tripRows.Start_s < 0)
    error('外部初始解的开始时刻必须是非负有限数值。');
end
if numel(unique(deliveryRows.BoxID)) ~= height(deliveryRows)
    error('外部初始解逐箱文件含重复货箱编号。');
end
if height(deliveryRows) ~= height(data.Boxes) || ...
        ~isempty(setxor(deliveryRows.BoxID,data.Boxes.BoxID))
    error('外部初始解必须恰好覆盖当前需求中的 %d 个货箱。',height(data.Boxes));
end
unknownTrips = setdiff(unique(deliveryRows.TripID),tripRows.TripID);
if ~isempty(unknownTrips)
    error('逐箱文件引用了架次文件中不存在的架次：%s',strjoin(unknownTrips,','));
end

solution = emptySolution();
for r = 1:height(tripRows)
    tripID = tripRows.TripID(r);
    if ~ismember(tripRows.Model(r),data.Models.Model)
        error('外部初始解架次 %s 使用未知机型 %s。',tripID,tripRows.Model(r));
    end
    stops = split(replace(tripRows.Route(r),"->","→"),"→");
    stops = strip(stops); stops = stops(strlength(stops)>0);
    if isempty(stops) || numel(unique(stops)) ~= numel(stops) || ...
            ~all(ismember(stops,data.NodeIDs)) || any(stops == "O01")
        error('外部初始解架次 %s 的服务区访问顺序非法。',tripID);
    end
    boxIDs = deliveryRows.BoxID(deliveryRows.TripID == tripID);
    if isempty(boxIDs)
        error('外部初始解架次 %s 未分配任何货箱。',tripID);
    end
    boxIdx = zeros(1,numel(boxIDs));
    for k = 1:numel(boxIDs)
        boxIdx(k) = find(data.Boxes.BoxID == boxIDs(k),1);
    end
    if ~all(ismember(unique(data.Boxes.ServiceID(boxIdx)),stops))
        error('外部初始解架次 %s 的货箱服务区不在其访问顺序中。',tripID);
    end
    candidate = struct('BoxIdx',boxIdx,'Stops',stops.','Model',tripRows.Model(r));
    info = evaluateTrip(candidate,data,base);
    if ~info.Feasible
        error('外部初始解架次 %s 在当前载荷、体积或能量口径下不可行。',tripID);
    end
    solution.Trips(end+1) = candidate; %#ok<AGROW>
end
[~,solution.Order] = sortrows([tripRows.Start_s,(1:height(tripRows)).'],[1 2]);
solution.Order = solution.Order.';
initialOutcome = decodeSolution(solution,data,base);
initialValidation = validateOutcome(solution,initialOutcome,data,base);
diagnostics = struct('Enabled',true,'TripFile',tripFile,'DeliveryFile',deliveryFile, ...
    'ImportedTripCount',height(tripRows),'ImportedBoxCount',height(deliveryRows), ...
    'InitialFeasible',initialOutcome.Feasible, ...
    'InitialObjectives',objectiveStruct(initialOutcome.Objectives), ...
    'InitialValidation',initialValidation, ...
    'SchedulingFields',"表 6 的无人机、电池、返回时刻和能耗仅作审计；正式排程已按当前模型重算。");
warmStart = struct('Enabled',true,'Solution',solution, ...
    'Outcome',initialOutcome,'Diagnostics',diagnostics);
end

function T = readWarmStartTripRows(file)
best = table();
for sheet = string(sheetnames(file)).'
    raw = readcell(file,'Sheet',sheet);
    for r = 1:size(raw,1)
        header = string(raw(r,:));
        idCol = find(contains(header,"架次编号"),1);
        modelCol = find(header == "机型",1);
        startCol = find(contains(header,"开始"),1);
        routeCol = find(contains(header,"访问服务区顺序"),1);
        if isempty(idCol) || isempty(modelCol) || isempty(startCol) || isempty(routeCol), continue; end
        id = strings(0,1); model = strings(0,1); start_s = zeros(0,1); route = strings(0,1);
        for q = r+1:size(raw,1)
            if warmStartBlank(raw{q,idCol}), continue; end
            id(end+1,1) = warmStartText(raw{q,idCol}); %#ok<AGROW>
            model(end+1,1) = warmStartText(raw{q,modelCol}); %#ok<AGROW>
            start_s(end+1,1) = warmStartNumber(raw{q,startCol},file,sheet,q,"开始时刻"); %#ok<AGROW>
            route(end+1,1) = warmStartText(raw{q,routeCol}); %#ok<AGROW>
        end
        candidate = table(id,model,start_s,route, ...
            'VariableNames',{'TripID','Model','Start_s','Route'});
        if height(candidate) > height(best), best = candidate; end
    end
end
if isempty(best)
    error('未在 %s 中识别到“架次编号、机型、开始、访问服务区顺序”表头。',file);
end
T = best;
end

function T = readWarmStartDeliveryRows(file)
best = table();
for sheet = string(sheetnames(file)).'
    raw = readcell(file,'Sheet',sheet);
    for r = 1:size(raw,1)
        header = string(raw(r,:));
        boxCols = find(contains(header,"货箱编号"));
        tripCols = find(contains(header,"架次编号"));
        timeCols = find(contains(header,"交付时刻"));
        pairCount = min([numel(boxCols),numel(tripCols),numel(timeCols)]);
        if pairCount == 0, continue; end
        box = strings(0,1); trip = strings(0,1); delivery_s = zeros(0,1);
        for q = r+1:size(raw,1)
            for p = 1:pairCount
                if warmStartBlank(raw{q,boxCols(p)}), continue; end
                box(end+1,1) = warmStartText(raw{q,boxCols(p)}); %#ok<AGROW>
                trip(end+1,1) = warmStartText(raw{q,tripCols(p)}); %#ok<AGROW>
                delivery_s(end+1,1) = warmStartNumber(raw{q,timeCols(p)},file,sheet,q,"交付时刻"); %#ok<AGROW>
            end
        end
        candidate = table(box,trip,delivery_s, ...
            'VariableNames',{'BoxID','TripID','Delivery_s'});
        if height(candidate) > height(best), best = candidate; end
    end
end
if isempty(best)
    error('未在 %s 中识别到“货箱编号、架次编号、交付时刻”表头。',file);
end
T = best;
end

function tf = warmStartBlank(value)
tf = isempty(value) || (isstring(value) && all(ismissing(value))) || ...
    (ischar(value) && isempty(strtrim(value)));
end

function value = warmStartText(raw)
value = strtrim(string(raw));
if strlength(value) == 0 || ismissing(value)
    error('外部初始解存在空文本字段。');
end
end

function value = warmStartNumber(raw,file,sheet,row,label)
if isnumeric(raw) && isscalar(raw)
    value = double(raw);
else
    value = str2double(string(raw));
end
if ~isfinite(value)
    error('%s 中工作表 %s 第 %d 行的%s不是有效数值。',file,sheet,row,label);
end
end

function solution = buildInitialSolution(data, base, config, profile, runIdx, warmStart)
% 从问题一的精确单点组批取得紧凑的可行装载，再由问题二处理
% 实体无人机、电池和硬时限。问题一的 18 趟结果是高质量热启动，
% 避免逐箱贪心把 49 个软货箱拆成 49 个单箱架次。
if warmStart.Enabled
    % 外部方案已按表 6 的开始时刻排好顺序。原方案独立保留为基线，
    % 后续运行由主流程从档案解构造不同的起点。
    solution = warmStart.Solution;
    return;
end
solution = emptySolution();
try
    q1Config = struct('ExportFiles',false,'ReserveRatios',0.20, ...
        'BaselineRatio',0.20,'FlightBaseFile',config.FlightBaseFile);
    q1 = problem1.solveProblem1Pareto(q1Config);
    q1Trips = q1.Selected.Trips;
    for r = 1:height(q1Trips)
        ids = split(string(q1Trips.BoxIDs(r)),',');
        boxIdx = zeros(1,numel(ids));
        for k = 1:numel(ids)
            boxIdx(k) = find(data.Boxes.BoxID == ids(k),1);
        end
        candidate = struct('BoxIdx',{boxIdx},'Stops',string(q1Trips.ServiceID(r)), ...
            'Model',string(q1Trips.ModelID(r)));
        if ~evaluateTrip(candidate,data,base).Feasible
            error('问题一热启动架次 %d 在问题二口径下不可行。',r);
        end
        solution.Trips(end+1) = candidate; %#ok<AGROW>
    end
catch ME
    warning('问题一热启动不可用，改用容量优先构造：%s',ME.message);
    solution = buildCapacitySeed(data,base);
end
solution.Order = urgencyOrder(solution,data);
if profile == "makespan" || profile == "balanced"
    solution = rebalanceSeed(solution,data,base);
end
if mod(runIdx,3) == 2
    solution = splitSeedForA(solution,data,base);
elseif mod(runIdx,3) == 0
    solution = diversifyRouteSeed(solution,data,base);
end
solution.Order = initialScheduleOrder(solution,data,base,profile);
end

function solution = buildCapacitySeed(data,base)
% 备用构造：按截止时间、优先级和质量排序，再按真正的边际成本插入。
solution = emptySolution();
hard = data.Boxes.HardDeadline_s;
hard(isnan(hard)) = inf;
[~,order] = sortrows([hard,data.Boxes.ExpectedDeadline_s, ...
    -data.Boxes.Priority,-data.Boxes.Mass_kg],[1 2 3 4]);
for k = 1:numel(order)
    solution = insertBoxGreedy(solution,order(k),data,base);
end
solution.Order = urgencyOrder(solution,data);
end

function solution = perturbSolution(solution,data,base,operator,profile,visit)
if isempty(solution.Trips), return; end
nTrip = numel(solution.Trips);
switch operator
    case 1 % 小规模破坏，避免将优质热启动一次打散 8--24 箱。
        allBox = [solution.Trips.BoxIdx];
        nRemove = min(numel(allBox),randi([3,8]));
        remove = allBox(randperm(numel(allBox),nRemove));
    case 2 % 相关服务区破坏：整服务区一起重组
        seedTrip = solution.Trips(randi(nTrip));
        seedService = seedTrip.Stops(randi(numel(seedTrip.Stops)));
        allServices = data.Boxes.ServiceID;
        remove = find(allServices == seedService);
        if numel(remove) < 8
            related = find(ismember(allServices,seedTrip.Stops));
            remove = unique([remove(:);related(:)]).';
        end
    case 3 % 按质量和体积利用率选择，而不是把绝对质量当作利用率。
        utilization = zeros(1,nTrip);
        for r = 1:nTrip
            g = find(data.Models.Model == solution.Trips(r).Model,1);
            info = evaluateTrip(solution.Trips(r),data,base);
            utilization(r) = max(info.Mass_kg/data.Models.MaxPayload_kg(g), ...
                info.Volume_m3/data.Models.MaxVolume_m3(g));
        end
        [~,ranked] = sort(utilization);
        idx = ranked(randi(min(3,nTrip)));
        remove = solution.Trips(idx).BoxIdx;
    case 4 % 整架次机型调整：不捆绑随机派发扰动。
        solution = improveModelAssignment(solution,data,base,profile,visit);
        return;
    case 5 % 仅改变单架次访问顺序。
        solution = tryRouteNeighborhood(solution,data,base);
        return;
    case 6 % 派发顺序：瓶颈强化与同机型随机探索。
        if rand < 0.75
        solution = improveCriticalOrder(solution,data,base,profile,visit);
        else
            solution = perturbOrder(solution,data,base,profile);
        end
        return;
    case 7 % 瓶颈拆分，所有机型均按真实约束参与。
        solution = splitCriticalTrip(solution,data,base,profile,visit);
        return;
    case 8 % 单箱迁移与交换是同一货箱重分配邻域的两种尺度。
        if rand < 0.8
        solution = transferCriticalBox(solution,data,base,profile,visit);
        else
            solution = tryCrossTripExchange(solution,data,base);
        end
        return;
    otherwise
        error('未知问题二算子编号。');
end
solution = removeBoxes(solution,remove,data);
remove = remove(randperm(numel(remove)));
for k = 1:numel(remove)
    solution = insertBoxGreedy(solution,remove(k),data,base);
end

end

function solution = splitSeedForA(solution,data,base)
for k = 1:min(4,numel(solution.Trips))
    before = numel(solution.Trips);
    solution = trySplitForA(solution,data,base);
    if numel(solution.Trips) == before, break; end
end
end

function solution = rebalanceSeed(solution,data,base)
for k = 1:min(6,numel(solution.Trips))
    changed = tryModelRebalance(solution,data,base);
    if isequaln(changed,solution), break; end
    solution = changed;
end
end

function solution = diversifyRouteSeed(solution,data,base)
for r = 1:numel(solution.Trips)
    if numel(solution.Trips(r).Stops) > 1 && rand < 0.6
        solution.Trips(r).Stops = solution.Trips(r).Stops(randperm(numel(solution.Trips(r).Stops)));
    end
end
end

function solution = trySplitForA(solution,data,base)
% 将 B/C 的一部分货箱拆出给 A 型机，目标是释放瓶颈机型的并行容量。
candidateIdx = find([solution.Trips.Model] ~= "A" & ...
    arrayfun(@(x)numel(x.BoxIdx)>=2,solution.Trips));
if isempty(candidateIdx), return; end
r = candidateIdx(randi(numel(candidateIdx)));
trip = solution.Trips(r);
boxOrder = trip.BoxIdx(randperm(numel(trip.BoxIdx)));
pick = zeros(1,0);
for b = boxOrder
    test = [pick,b];
    stops = stopsForBoxes(test,trip.Stops,data);
    aTrip = struct('BoxIdx',test,'Stops',stops,'Model',"A");
    remainder = setdiff(trip.BoxIdx,test,'stable');
    if evaluateTrip(aTrip,data,base).Feasible && ~isempty(remainder)
        remTrip = trip;
        remTrip.BoxIdx = remainder;
        remTrip.Stops = stopsForBoxes(remainder,trip.Stops,data);
        if evaluateTrip(remTrip,data,base).Feasible
            solution.Trips(r) = remTrip;
            solution.Trips(end+1) = aTrip;
            pos = find(solution.Order == r,1);
            if isempty(pos)
                solution.Order = 1:(numel(solution.Trips)-1);
                pos = numel(solution.Order)+1;
            end
            solution.Order = [solution.Order(1:pos-1),numel(solution.Trips), ...
                solution.Order(pos:end)];
            return;
        end
    end
    pick = test;
end
end

function solution = tryModelRebalance(solution,data,base)
% 优先从单位机队工作量最高的机型迁出整条可行架次。
load = modelWorkload(solution,data,base);
[~,g] = max(load.WorkPerDrone_s);
fromModel = load.Model(g);
idx = find([solution.Trips.Model] == fromModel);
idx = idx(randperm(numel(idx)));
for r = idx
    trip = solution.Trips(r);
    targets = setdiff(data.Models.Model,fromModel,'stable');
    [~,order] = sort(load.WorkPerDrone_s(ismember(load.Model,targets)),'ascend');
    targets = targets(order);
    for m = targets.'
        candidate = trip; candidate.Model = m;
        if evaluateTrip(candidate,data,base).Feasible
            solution.Trips(r) = candidate;
            return;
        end
    end
end
end

function solution = improveModelAssignment(solution,data,base,profile,visit)
% 用真实无人机/电池排程比较替代机型，避免仅凭平均工作量判断收益。
source = solution;
bestOutcome = decodeSolution(source,data,base);
critical = criticalTripIndices(source,data,base);
pool = unique([critical,randperm(numel(source.Trips),min(3,numel(source.Trips)))],'stable');
for r = pool
    trip = source.Trips(r);
    models = capacityModels(trip.BoxIdx,data);
    models(models == trip.Model) = [];
    for model = reshape(models,1,[])
        trial = source; trial.Trips(r).Model = model;
        if ~evaluateTrip(trial.Trips(r),data,base).Feasible, continue; end
        out = decodeSolution(trial,data,base);
        visit(trial,out);
        value = compareOutcomes(out,bestOutcome,profile);
        if out.Feasible && value < -1e-12
            solution = trial; bestOutcome = out;
        end
    end
end
end

function solution = tryRouteNeighborhood(solution,data,base)
idx = find(arrayfun(@(x)numel(x.Stops)>=2,solution.Trips));
if isempty(idx), return; end
r = idx(randi(numel(idx))); trip = solution.Trips(r);
stops = trip.Stops;
if rand < 0.35
    stops = fliplr(stops);
elseif rand < 0.5
    p = randperm(numel(stops),2); stops(p) = stops(fliplr(p));
else
    % 单点搬移补充交换和反转无法一步到达的访问顺序。
    p = randperm(numel(stops),2);
    stop = stops(p(1)); stops(p(1)) = [];
    stops = [stops(1:p(2)-1),stop,stops(p(2):end)];
end
candidate = trip; candidate.Stops = stops;
if evaluateTrip(candidate,data,base).Feasible
    solution.Trips(r) = candidate;
end
end

function solution = tryCrossTripExchange(solution,data,base)
if numel(solution.Trips) < 2, return; end
p = randperm(numel(solution.Trips),2); a = solution.Trips(p(1)); b = solution.Trips(p(2));
if isempty(a.BoxIdx) || isempty(b.BoxIdx), return; end
ia = a.BoxIdx(randi(numel(a.BoxIdx))); ib = b.BoxIdx(randi(numel(b.BoxIdx)));
a.BoxIdx(a.BoxIdx==ia) = ib; b.BoxIdx(b.BoxIdx==ib) = ia;
a.Stops = stopsForBoxes(a.BoxIdx,a.Stops,data); b.Stops = stopsForBoxes(b.BoxIdx,b.Stops,data);
if evaluateTrip(a,data,base).Feasible && evaluateTrip(b,data,base).Feasible
    solution.Trips(p(1)) = a; solution.Trips(p(2)) = b;
end
end

function stops = stopsForBoxes(boxIdx,oldStops,data)
present = unique(data.Boxes.ServiceID(boxIdx),'stable');
stops = oldStops(ismember(oldStops,present));
missing = setdiff(present,stops,'stable');
stops = [stops,missing.'];
end

function solution = perturbOrder(solution,data,base,profile)
if isempty(solution.Trips), return; end
if isempty(solution.Order) || numel(solution.Order) ~= numel(solution.Trips) || ...
        ~isequal(sort(solution.Order),1:numel(solution.Trips))
    solution.Order = initialScheduleOrder(solution,data,base,profile);
end
if numel(solution.Order) < 2, return; end
% 不同机型资源完全独立，交换跨机型的全局位置可能不改变任何排程。
model = solution.Trips(solution.Order(randi(numel(solution.Order)))).Model;
positions = find([solution.Trips(solution.Order).Model] == model);
if numel(positions) < 2, return; end
if rand < 0.55
    p = positions(randperm(numel(positions),2));
    solution.Order(p) = solution.Order(fliplr(p));
else
    p = positions(randperm(numel(positions),2)); from = p(1); to = p(2);
    value = solution.Order(from); solution.Order(from) = [];
    solution.Order = [solution.Order(1:to-1),value,solution.Order(to:end)];
end
end

function order = initialScheduleOrder(solution,data,base,profile)
% 硬时限架次优先；非紧急架次按时长降序以均衡并行机队。
n = numel(solution.Trips); key = zeros(n,4);
for r = 1:n
    b = data.Boxes(solution.Trips(r).BoxIdx,:); hard = b.HardDeadline_s; hard(isnan(hard)) = inf;
    duration = evaluateTrip(solution.Trips(r),data,base).Duration_s;
    if profile == "timeliness", secondary = min(b.ExpectedDeadline_s); else, secondary = -duration; end
    key(r,:) = [min(hard),secondary,-max(b.Priority),r];
end
[~,order] = sortrows(key,[1 2 3 4]); order = order.';
end

function solution = diversifyRestart(solution,archiveSolutions,archiveOutcomes,profile)
% 每段从真实极值出发；停滞时兼顾极值邻域和整个前沿的结构多样性。
if isempty(archiveSolutions), return; end
ranked = rankOutcomes(archiveOutcomes,profile);
if rand < 0.8
    idx = ranked(randi(min(5,numel(ranked))));
else
    idx = ranked(randi(numel(ranked)));
end
solution = archiveSolutions{idx};
end
function idx = criticalTripIndices(solution,data,base)
out = decodeSolution(solution,data,base);
if isempty(out.Trips) || ~all(isfinite(out.Trips.Return_s))
    idx = zeros(1,0);
    return;
end
[~,last] = max(out.Trips.Return_s);
droneID = out.Trips.DroneID(last);
sameDrone = find(out.Trips.DroneID == droneID);
[~,p] = sort(out.Trips.Return_s(sameDrone),'descend');
idx = sameDrone(p(1:min(3,numel(p)))).';
end

function solution = improveCriticalOrder(solution,data,base,profile,visit)
critical = criticalTripIndices(solution,data,base);
if isempty(critical), return; end
best = solution;
bestOutcome = decodeSolution(solution,data,base);
for r = critical(1:min(2,numel(critical)))
    pos = find(solution.Order == r,1);
    if isempty(pos), continue; end
    sameModel = find([solution.Trips(solution.Order).Model] == solution.Trips(r).Model);
    targets = unique([sameModel, numel(solution.Order)]);
    for target = targets
        if target == pos, continue; end
        trial = solution;
        order = trial.Order;
        order(pos) = [];
        trial.Order = [order(1:target-1),r,order(target:end)];
        out = decodeSolution(trial,data,base);
        visit(trial,out);
        if out.Feasible
            value = compareOutcomes(out,bestOutcome,profile);
            if value < -1e-12
                best = trial;
                bestOutcome = out;
            end
        end
    end
end
solution = best;
end

function solution = splitCriticalTrip(solution,data,base,profile,visit)
critical = criticalTripIndices(solution,data,base);
if isempty(critical), return; end
best = solution;
bestOutcome = decodeSolution(solution,data,base);
fullDecodes = 0;
for r = critical(randperm(numel(critical)))
    trip = solution.Trips(r);
    if numel(trip.BoxIdx) < 2, continue; end
    b = trip.BoxIdx;
    % 不允许拆走全部货箱，避免空架次；随机化预算内的候选覆盖。
    pairs = nchoosek(1:numel(b),2);
    if numel(b) == 2, pairs = zeros(0,2); end
    subsets = [num2cell(pairs,2);num2cell((1:numel(b)).')];
    for j = randperm(numel(subsets))
        move = b(subsets{j});
        remaining = setdiff(b,move,'stable');
        sourceTrip = trip;
        sourceTrip.BoxIdx = remaining;
        sourceTrip.Stops = stopsForBoxes(remaining,trip.Stops,data);
        if ~evaluateTrip(sourceTrip,data,base).Feasible, continue; end
        models = capacityModels(move,data);
        for model = reshape(models(randperm(numel(models))),1,[])
            newTrip = struct('BoxIdx',{move}, ...
                'Stops',unique(data.Boxes.ServiceID(move),'stable').', ...
                'Model',model);
            if ~evaluateTrip(newTrip,data,base).Feasible, continue; end
            trial = solution;
            trial.Trips(r) = sourceTrip;
            trial.Trips(end+1) = newTrip;
            pos = find(trial.Order == r,1);
            for insertAt = unique([1,pos])
                candidate = trial;
                candidate.Order = [trial.Order(1:insertAt-1), ...
                    numel(trial.Trips),trial.Order(insertAt:end)];
                out = decodeSolution(candidate,data,base);
                visit(candidate,out);
                fullDecodes = fullDecodes+1;
                if out.Feasible
                    value = compareOutcomes(out,bestOutcome,profile);
                    if value < -1e-12
                        best = candidate;
                        bestOutcome = out;
                    end
                end
                if fullDecodes >= 16, break; end
            end
            if fullDecodes >= 16, break; end
        end
        if fullDecodes >= 16, break; end
    end
    if fullDecodes >= 16, break; end
end
solution = best;
end

function solution = transferCriticalBox(solution,data,base,profile,visit)
critical = criticalTripIndices(solution,data,base);
if isempty(critical), return; end
best = solution;
bestOutcome = decodeSolution(solution,data,base);
fullDecodes = 0;
for r = critical
    source = solution.Trips(r);
    if numel(source.BoxIdx) < 2, continue; end
    boxes = source.BoxIdx(randperm(numel(source.BoxIdx)));
    for box = boxes
        for target = randperm(numel(solution.Trips))
            if target == r, continue; end
            recipient = solution.Trips(target);
            service = data.Boxes.ServiceID(box);
            recipient.BoxIdx = [recipient.BoxIdx,box];
            if ~any(recipient.Stops == service)
                recipient.Stops = [recipient.Stops,service];
            end
            if ~evaluateTrip(recipient,data,base).Feasible, continue; end
            remaining = setdiff(source.BoxIdx,box,'stable');
            donor = source;
            donor.BoxIdx = remaining;
            donor.Stops = stopsForBoxes(remaining,source.Stops,data);
            if ~evaluateTrip(donor,data,base).Feasible, continue; end
            trial = solution;
            trial.Trips(r) = donor;
            trial.Trips(target) = recipient;
            out = decodeSolution(trial,data,base);
        visit(trial,out);
            fullDecodes = fullDecodes+1;
            if out.Feasible
                value = compareOutcomes(out,bestOutcome,profile);
                if value < -1e-12
                    best = trial;
                    bestOutcome = out;
                end
            end
            if fullDecodes >= 12, break; end
        end
        if fullDecodes >= 12, break; end
    end
    if fullDecodes >= 12, break; end
end
solution = best;
end

function solution = insertBoxGreedy(solution,boxIdx,data,base)
best = []; bestScore = inf;
for r = 1:numel(solution.Trips)
    original = solution.Trips(r);
    service = data.Boxes.ServiceID(boxIdx);
    originalInfo = evaluateTrip(original,data,base);
    if ~originalInfo.Feasible, continue; end
    if any(original.Stops == service)
        candidate = original;
        candidate.BoxIdx = [candidate.BoxIdx,boxIdx];
        models = capacityModels(candidate.BoxIdx,data);
        models = unique([candidate.Model;models],'stable');
        for g = 1:numel(models)
            candidate.Model = models(g);
            info = evaluateTrip(candidate,data,base);
            delta = tripScore(info)-tripScore(originalInfo);
            if info.Feasible && delta < bestScore
                best = struct('Trip',candidate,'Index',r); bestScore = delta;
            end
        end
    else
        for pos = 1:numel(original.Stops)+1
            candidate = original;
            candidate.BoxIdx = [candidate.BoxIdx,boxIdx];
            candidate.Stops = [candidate.Stops(1:pos-1),service,candidate.Stops(pos:end)];
            models = capacityModels(candidate.BoxIdx,data);
            for g = 1:numel(models)
                candidate.Model = models(g);
                info = evaluateTrip(candidate,data,base);
                delta = tripScore(info)-tripScore(originalInfo);
                if info.Feasible && delta < bestScore
                    best = struct('Trip',candidate,'Index',r); bestScore = delta;
                end
            end
        end
    end
end
service = data.Boxes.ServiceID(boxIdx);
for g = 1:height(data.Models)
    candidate = struct('BoxIdx',boxIdx,'Stops',service,'Model',data.Models.Model(g));
    info = evaluateTrip(candidate,data,base);
    if info.Feasible && tripScore(info) < bestScore
        best = struct('Trip',candidate,'Index',0); bestScore = tripScore(info);
    end
end
if isempty(best)
    error('货箱 %s 无法由任一机型单独运输。',data.Boxes.BoxID(boxIdx));
end
if best.Index == 0
    solution.Trips(end+1) = best.Trip;
    solution.Order = [solution.Order,numel(solution.Trips)];
else
    solution.Trips(best.Index) = best.Trip;
end
end

function models = capacityModels(boxIdx,data)
% 仅作必要条件筛选；能量、航线及全部硬约束仍由 evaluateTrip 核验。
mass = sum(data.Boxes.Mass_kg(boxIdx));
volume = sum(data.Boxes.Volume_m3(boxIdx));
models = data.Models.Model(data.Models.MaxPayload_kg+1e-9 >= mass & ...
    data.Models.MaxVolume_m3+1e-12 >= volume);
end

function info = evaluateTrip(trip,data,base)
persistent tripCache cacheKey
if isempty(cacheKey) || ~strcmp(cacheKey,base.CacheKey)
    tripCache = containers.Map('KeyType','char','ValueType','any');
    cacheKey = base.CacheKey;
end
key = char(strjoin([string(trip.Model),strjoin(string(trip.BoxIdx),','), ...
    strjoin(trip.Stops,'>')],'|'));
if isKey(tripCache,key)
    info = tripCache(key);
    return;
end
boxes = data.Boxes(trip.BoxIdx,:);
g = find(data.Models.Model == trip.Model,1);
if isempty(g), error('未知机型 %s。',trip.Model); end
info = struct('Feasible',false,'Mass_kg',sum(boxes.Mass_kg), ...
    'Volume_m3',sum(boxes.Volume_m3),'Energy_kWh',inf,'Duration_s',inf, ...
    'ReturnSOC',-inf,'ChargeTime_s',inf,'DeliveryOffset_s',nan(numel(trip.BoxIdx),1));
if info.Mass_kg > data.Models.MaxPayload_kg(g)+1e-9 || ...
        info.Volume_m3 > data.Models.MaxVolume_m3(g)+1e-12 || ...
        numel(unique(trip.Stops)) ~= numel(trip.Stops)
    tripCache(key) = info;
    return;
end
if ~all(ismember(unique(boxes.ServiceID),trip.Stops)) || ...
        ~all(ismember(trip.Stops,unique(boxes.ServiceID)))
    tripCache(key) = info;
    return;
end

payload = info.Mass_kg;
energy = 0;
cursor = data.Models.PrepTime_s(g)+data.Models.LoadTimeBox_s(g)*height(boxes);
prev = "O01";
for h = 1:numel(trip.Stops)
    current = trip.Stops(h);
    i = base.NodeIndex(char(prev)); j = base.NodeIndex(char(current));
    if abs(payload-round(payload)) > 1e-9 || payload < 0 || payload > 80
        tripCache(key) = info;
        return;
    end
    e = base.Energy_kWh(i,j,g,round(payload)+1);
    if isnan(e)
        tripCache(key) = info;
        return;
    end
    energy = energy+e;
    cursor = cursor+base.Time_s(i,j,g);
    delivered = boxes.ServiceID == current;
    cursor = cursor+data.Models.HandoverBase_s(g)+ ...
        data.Models.HandoverBox_s(g)*nnz(delivered);
    info.DeliveryOffset_s(delivered) = cursor;
    payload = payload-sum(boxes.Mass_kg(delivered));
    prev = current;
end
i = base.NodeIndex(char(prev)); j = base.NodeIndex('O01');
e = base.Energy_kWh(i,j,g,1);
energy = energy+e;
cursor = cursor+base.Time_s(i,j,g);
info.Energy_kWh = energy;
info.Duration_s = cursor;
info.ReturnSOC = 1-energy/data.Models.BatteryUse_kWh(g);
if energy > (1-data.Models.ReserveRatio(g))*data.Models.BatteryUse_kWh(g)+1e-9
    tripCache(key) = info;
    return;
end
info.ChargeTime_s = common.chargeTime(info.ReturnSOC, ...
    batteryFullTime(trip.Model,data));
info.Feasible = all(isfinite(info.DeliveryOffset_s));
tripCache(key) = info;
end

function outcome = decodeSolution(solution,data,base)
nTrip = numel(solution.Trips);
infoPrototype = struct('Feasible',false,'Mass_kg',0,'Volume_m3',0, ...
    'Energy_kWh',inf,'Duration_s',inf,'ReturnSOC',-inf, ...
    'ChargeTime_s',inf,'DeliveryOffset_s',[]);
infos = repmat(infoPrototype,nTrip,1);
for r = 1:nTrip, infos(r) = evaluateTrip(solution.Trips(r),data,base); end

droneAvail = zeros(height(data.Drones),1);
batteryAvail = zeros(height(data.Batteries),1);
tripStart = nan(nTrip,1); tripDrone = strings(nTrip,1); tripBattery = strings(nTrip,1);
for q = 1:numel(solution.Order)
    r = solution.Order(q);
    if ~infos(r).Feasible, continue; end
    model = solution.Trips(r).Model;
    dIdx = find(data.Drones.Model == model);
    bIdx = find(data.Batteries.Model == model);
    [dTime,dPos] = min(droneAvail(dIdx));
    [bTime,bPos] = min(batteryAvail(bIdx));
    actualD = dIdx(dPos); actualB = bIdx(bPos);
    tripStart(r) = max(dTime,bTime);
    tripDrone(r) = data.Drones.DroneID(actualD);
    tripBattery(r) = data.Batteries.BatteryID(actualB);
    droneAvail(actualD) = tripStart(r)+infos(r).Duration_s;
    batteryAvail(actualB) = droneAvail(actualD)+infos(r).ChargeTime_s;
end

% 先构造整列，再一次性建立表，避免每个候选创建上百个小 table。
tripIDs = compose('T%03d',(1:nTrip).');
models = strings(nTrip,1); routes = strings(nTrip,1);
boxIndices = zeros(0,1); deliveryTripIDs = strings(0,1); deliveryTimes = zeros(0,1);
for r = 1:nTrip
    trip = solution.Trips(r); info = infos(r);
    models(r) = trip.Model;
    routes(r) = strjoin(trip.Stops,'->');
    boxIndices = [boxIndices;trip.BoxIdx(:)]; %#ok<AGROW>
    deliveryTripIDs = [deliveryTripIDs;repmat(tripIDs(r),numel(trip.BoxIdx),1)]; %#ok<AGROW>
    deliveryTimes = [deliveryTimes;tripStart(r)+info.DeliveryOffset_s]; %#ok<AGROW>
end
returns = tripStart+[infos.Duration_s].';
charges = [infos.ChargeTime_s].';
trips = table(tripIDs,tripDrone,models,tripBattery,tripStart,routes,returns, ...
    [infos.Energy_kWh].',[infos.Mass_kg].',[infos.Volume_m3].', ...
    100*[infos.ReturnSOC].',charges,'VariableNames', ...
    {'TripID','DroneID','Model','BatteryID','Start_s','Route','Return_s', ...
    'Energy_kWh','Mass_kg','Volume_m3','ReturnSOC_pct','ChargeTime_s'});
b = data.Boxes(boxIndices,:);
deliveries = table(b.BoxID,deliveryTripIDs,b.ServiceID,deliveryTimes,b.IsMedical, ...
    b.IsFirst,b.HardDeadline_s,b.ExpectedDeadline_s,b.Priority,'VariableNames', ...
    {'BoxID','TripID','ServiceID','Delivery_s','IsMedical','IsFirst', ...
    'HardDeadline_s','ExpectedDeadline_s','Priority'});
droneTimeline = table(tripDrone,tripIDs,tripStart,returns, ...
    'VariableNames',{'DroneID','TripID','Start_s','End_s'});
batteryTimeline = table(tripBattery,tripIDs,tripStart,returns,returns+charges, ...
    'VariableNames',{'BatteryID','TripID','TaskStart_s','Return_s','Available_s'});
deliveries = sortrows(deliveries,'BoxID');

hardLate = max(0,deliveries.Delivery_s-deliveries.HardDeadline_s);
hardLate(isnan(hardLate)) = 0;
coverageOK = height(deliveries)==height(data.Boxes) && numel(unique(deliveries.BoxID))==height(data.Boxes);
routeOK = all([infos.Feasible]);
resourceOK = timelineValid(droneTimeline,'DroneID','Start_s','End_s') && ...
    timelineValid(batteryTimeline,'BatteryID','TaskStart_s','Available_s');
feasible = routeOK && coverageOK && all(hardLate <= 1e-7) && resourceOK;
softTardiness = max(0,deliveries.Delivery_s-deliveries.ExpectedDeadline_s) ./ deliveries.ExpectedDeadline_s;
timeliness = sum(deliveries.Priority.*softTardiness)/sum(data.Boxes.Priority);
if ~routeOK || any(~isfinite(trips.Return_s))
    objectiveVector = [inf,inf,inf,inf];
else
    objectiveVector = [timeliness,max(trips.Return_s),sum(trips.Energy_kWh),height(trips)];
end
outcome = struct('Feasible',feasible,'Trips',trips,'Deliveries',deliveries, ...
    'DroneTimeline',droneTimeline,'BatteryTimeline',batteryTimeline, ...
    'Objectives',objectiveVector, ...
    'Violation',sum(hardLate)+1e6*(~routeOK)+1e6*(~coverageOK)+1e6*(~resourceOK));
end

function solution = repairHardDeadlines(solution,data,base,config)
for pass = 1:min(12,height(data.Boxes))
    out = decodeSolution(solution,data,base);
    lateMask = ~isnan(out.Deliveries.HardDeadline_s) & ...
        out.Deliveries.Delivery_s > out.Deliveries.HardDeadline_s+1e-7;
    if ~any(lateMask), return; end
    lateness = out.Deliveries.Delivery_s-out.Deliveries.HardDeadline_s;
    lateness(~lateMask) = -inf;
    [~,lateRow] = max(lateness);
    idx = find(data.Boxes.BoxID == out.Deliveries.BoxID(lateRow),1);
    r = find(arrayfun(@(x)ismember(idx,x.BoxIdx),solution.Trips),1);
    best = solution;
    bestLate = hardLateness(out);

    % 首先把超时架次提前，不改变货箱组批。
    pos = find(solution.Order == r,1);
    targets = unique([1,max(1,round(pos/2)),max(1,pos-1)]);
    for target = targets(targets < pos)
        trial = solution;
        order = trial.Order;
        order(pos) = [];
        trial.Order = [order(1:target-1),r,order(target:end)];
        value = hardLateness(decodeSolution(trial,data,base));
        if value < bestLate-1e-7
            best = trial;
            bestLate = value;
        end
    end
    if bestLate <= 1e-7
        solution = best;
        continue;
    end

    % 再尝试把超时货箱放入同服务区的其他架次。
    reduced = removeBoxes(solution,idx,data);
    service = data.Boxes.ServiceID(idx);
    for target = 1:numel(reduced.Trips)
        if ~any(reduced.Trips(target).Stops == service), continue; end
        trial = reduced;
        trip = trial.Trips(target);
        trip.BoxIdx = [trip.BoxIdx,idx];
        if ~evaluateTrip(trip,data,base).Feasible, continue; end
        trial.Trips(target) = trip;
        value = hardLateness(decodeSolution(trial,data,base));
        if value < bestLate-1e-7
            best = trial;
            bestLate = value;
        end
    end

    % 最后才拆出单箱架次，并挑选可行的早期派发位置。
    if bestLate > 1e-7
        for g = 1:height(data.Models)
            trip = struct('BoxIdx',idx,'Stops',service,'Model',data.Models.Model(g));
            if ~evaluateTrip(trip,data,base).Feasible, continue; end
            trial = reduced;
            trial.Trips(end+1) = trip;
            targets = unique([1,min(3,numel(trial.Order)+1), ...
                min(6,numel(trial.Order)+1)]);
            for target = targets
                candidate = trial;
                candidate.Order = [trial.Order(1:target-1), ...
                    numel(trial.Trips),trial.Order(target:end)];
                value = hardLateness(decodeSolution(candidate,data,base));
                if value < bestLate-1e-7
                    best = candidate;
                    bestLate = value;
                end
            end
        end
    end
    if isequaln(best,solution), return; end
    solution = best;
end
end

function value = hardLateness(outcome)
value = outcome.Violation;
if ~isfinite(value), value = inf; end
end

function solution = removeBoxes(solution,boxIdx,data)
keepTrip = true(1,numel(solution.Trips));
for r = numel(solution.Trips):-1:1
    keep = ~ismember(solution.Trips(r).BoxIdx,boxIdx);
    solution.Trips(r).BoxIdx = solution.Trips(r).BoxIdx(keep);
    if isempty(solution.Trips(r).BoxIdx)
        keepTrip(r) = false;
    else
        presentServices = unique(data.Boxes.ServiceID(solution.Trips(r).BoxIdx),'stable');
        solution.Trips(r).Stops = solution.Trips(r).Stops( ...
            ismember(solution.Trips(r).Stops,presentServices));
    end
end
solution = retainTrips(solution,keepTrip);
solution = normalizeTrips(solution);
end

function solution = retainTrips(solution,keepTrip)
% 删除架次时同步重映射派发顺序，保留其余架次的相对次序。
n = numel(solution.Trips);
oldOrder = solution.Order;
if numel(oldOrder) ~= n || ~isequal(sort(oldOrder),1:n)
    oldOrder = 1:n;
end
mapping = zeros(1,n);
mapping(keepTrip) = 1:nnz(keepTrip);
solution.Trips = solution.Trips(keepTrip);
newOrder = mapping(oldOrder);
solution.Order = newOrder(newOrder > 0);
end

function solution = normalizeTrips(solution)
for r = 1:numel(solution.Trips)
    solution.Trips(r).BoxIdx = unique(solution.Trips(r).BoxIdx,'stable');
    solution.Trips(r).Stops = unique(solution.Trips(r).Stops,'stable');
end
end

function order = urgencyOrder(solution,data)
n = numel(solution.Trips);
key = zeros(n,4);
for r = 1:n
    b = data.Boxes(solution.Trips(r).BoxIdx,:);
    hard = b.HardDeadline_s; hard(isnan(hard)) = inf;
    key(r,:) = [min(hard),min(b.ExpectedDeadline_s),-max(b.Priority),r];
end
[~,order] = sortrows(key,[1 2 3 4]);
order = order.';
end

function T = modelWorkload(solution,data,base)
model = data.Models.Model;
work = zeros(height(data.Models),1);
for r = 1:numel(solution.Trips)
    g = find(model == solution.Trips(r).Model,1);
    if ~isempty(g), work(g) = work(g)+evaluateTrip(solution.Trips(r),data,base).Duration_s; end
end
droneCount = zeros(height(data.Models),1);
for g = 1:height(data.Models), droneCount(g) = nnz(data.Drones.Model == model(g)); end
T = table(model,work,droneCount,work./droneCount, ...
    'VariableNames',{'Model','Work_s','DroneCount','WorkPerDrone_s'});
end

function [best,count] = archiveSummary(outcomes)
count = numel(outcomes); best = [inf,inf,inf,inf];
for k = 1:count, best = min(best,outcomes{k}.Objectives); end
end

function representatives = buildRepresentatives(solutions,outcomes,indices,data,base)
names = fieldnames(indices); representatives = struct();
for k = 1:numel(names)
    idx = indices.(names{k}); out = outcomes{idx}; sol = solutions{idx};
    representatives.(names{k}) = struct('Solution',sol, ...
        'Objectives',objectiveStruct(out.Objectives),'Trips',out.Trips, ...
        'Deliveries',out.Deliveries,'DroneTimeline',out.DroneTimeline, ...
        'BatteryTimeline',out.BatteryTimeline,'Validation',validateOutcome(sol,out,data,base), ...
        'ParetoIndex',idx);
end
end

function indices = chooseRepresentatives(outcomes)
obj = zeros(numel(outcomes),4);
for k = 1:numel(outcomes), obj(k,:) = outcomes{k}.Objectives; end
lo = min(obj,[],1); hi = max(obj,[],1); span = hi-lo; span(span < 1e-12)=1;
z = (obj-lo)./span;
indices = struct();
indices.TimelinessFirst = representativeIndex(obj,z,1);
indices.MakespanFirst = representativeIndex(obj,z,2);
indices.EnergyFirst = representativeIndex(obj,z,3);
indices.TripCountFirst = representativeIndex(obj,z,4);
key = [max(z,[],2),sum(z,2),z];
[~,ix] = sortrows(key,1:size(key,2)); indices.Balanced = ix(1);
end

function index = representativeIndex(obj,z,primary)
% 主目标严格优先；仅在数值等价时以其余目标的最大归一化差距打破平局。
tol = max(1e-9,1e-8*max(1,abs(min(obj(:,primary)))));
pool = find(obj(:,primary) <= min(obj(:,primary))+tol);
other = setdiff(1:4,primary,'stable');
key = [max(z(pool,other),[],2),sum(z(pool,other),2),z(pool,other),pool];
[~,p] = sortrows(key,1:size(key,2)); index = pool(p(1));
end

function tf = acceptCandidate(current,candidate,temperature,profile,worseCap)
if candidate.Feasible && ~current.Feasible, tf = true; return; end
if ~candidate.Feasible && current.Feasible, tf = false; return; end
delta = compareOutcomes(candidate,current,profile);
tf = delta <= 0 || rand < min(worseCap,exp(-delta/max(temperature,1e-9)));
end

function delta = compareOutcomes(candidate,current,profile)
% 以首个显著不同的目标决定方向；主目标改善不再被次目标抵消。
if ~candidate.Feasible || ~current.Feasible
    delta = (1e6*~candidate.Feasible+candidate.Violation) - ...
        (1e6*~current.Feasible+current.Violation);
    return;
end
a = searchKey(candidate.Objectives,profile);
b = searchKey(current.Objectives,profile);
idx = find(abs(a-b) > 1e-12,1);
if isempty(idx), delta = 0; else, delta = a(idx)-b(idx); end
end

function ranked = rankOutcomes(outcomes,profile)
obj = cellfun(@(o)o.Objectives,outcomes,'UniformOutput',false);
key = searchKey(vertcat(obj{:}),profile);
[~,ranked] = sortrows(key);
end

function key = searchKey(obj,profile)
z = obj./[1,2e4,50,20];
switch profile
    case "timeliness", order = [1,2,3,4];
    case "makespan", order = [2,1,3,4];
    case "energy", order = [3,1,2,4];
    case "trips", order = [4,1,2,3];
    otherwise
        key = [max(z,[],2),sum(z,2),z];
        return;
end
key = z(:,order);
end
function op = roulette(weights)
c = cumsum(weights/sum(weights)); op = find(rand <= c,1); if isempty(op), op=numel(weights); end
end

function value = tripScore(info)
value = info.Duration_s+400*info.Energy_kWh;
end

function full = batteryFullTime(model,data)
idx = find(data.Batteries.Model == model,1);
full = data.Batteries.FullChargeTime_s(idx);
end

function validation = validateOutcome(solution,outcome,data,base)
checks = strings(0,1); passed = false(0,1); detail = strings(0,1);
    function add(name,ok,msg)
        checks(end+1,1)=name; passed(end+1,1)=ok; detail(end+1,1)=msg;
    end
add("货箱数量",height(outcome.Deliveries)==80,sprintf('交付记录 %d 行。',height(outcome.Deliveries)));
add("货箱唯一交付",numel(unique(outcome.Deliveries.BoxID))==height(data.Boxes),'每个货箱仅出现一次。');
add("医疗与首批时限",all(outcome.Deliveries.Delivery_s(~isnan(outcome.Deliveries.HardDeadline_s)) <= ...
    outcome.Deliveries.HardDeadline_s(~isnan(outcome.Deliveries.HardDeadline_s))+1e-7),'硬时限均满足。');
add("航程载荷能量",all(outcome.Trips.ReturnSOC_pct >= 100*data.Models.ReserveRatio( ...
    arrayfun(@(x)find(data.Models.Model==x,1),outcome.Trips.Model))-1e-7),'各架次返航 SOC 合格。');
add("无人机资源",timelineValid(outcome.DroneTimeline,'DroneID','Start_s','End_s'),'无人机时间线无重叠。');
add("电池资源",timelineValid(outcome.BatteryTimeline,'BatteryID','TaskStart_s','Available_s'),'电池任务和充电无重叠。');
add("整体可行",outcome.Feasible,'调度解码器判定可行。');
validation = table(checks,passed,detail,'VariableNames',{'Check','Passed','Details'});
end

function tf = timelineValid(T,idVar,startVar,endVar)
tf = true;
ids = unique(T.(idVar));
for k = 1:numel(ids)
    x = T(T.(idVar)==ids(k),:);
    x = sortrows(x,startVar);
    if any(x.(startVar)(2:end) < x.(endVar)(1:end-1)-1e-7), tf=false; return; end
end
end

function files = exportResults(result,data,config)
if ~exist(config.ResultDir,'dir'), mkdir(config.ResultDir); end
analysis = fullfile(config.ResultDir,'问题二_多目标调度分析.xlsx');
archiveFile = fullfile(config.ResultDir,'问题二_Pareto完整档案.mat');
repNames = fieldnames(result.Representatives);
submissionNames = ["及时性优先","完成时间优先","能耗优先","架次数优先","折中方案"];
submissions = struct();
for k = 1:numel(repNames)
    file = fullfile(config.ResultDir,"问题二_结果提交_"+submissionNames(k)+".xlsx");
    writeRepresentativeSubmission(result.Representatives.(repNames{k}),config.TemplateFile,file);
    submissions.(repNames{k}) = file;
end
if isfile(analysis), delete(analysis); end
writetable(representativeSummary(result),analysis,'Sheet','代表方案汇总','Range','A1');
writetable(result.ParetoFront,analysis,'Sheet','Pareto前沿','Range','A1');
writetable(buildParetoTripTable(result),analysis,'Sheet','Pareto架次','Range','A1');
writetable(buildParetoDeliveryTable(result),analysis,'Sheet','Pareto逐箱交付','Range','A1');
writetable(buildRepresentativeTripTable(result),analysis,'Sheet','代表方案架次','Range','A1');
writetable(buildRepresentativeDeliveryTable(result),analysis,'Sheet','代表方案逐箱交付','Range','A1');
writetable(buildRepresentativeValidationTable(result),analysis,'Sheet','代表方案校核','Range','A1');
writetable(result.RunLog,analysis,'Sheet','运行汇总','Range','A1');
writetable(result.ConvergenceLog,analysis,'Sheet','收敛记录','Range','A1');
writetable(result.OperatorDiagnostics,analysis,'Sheet','算子诊断','Range','A1');
writetable(buildResourceBottleneckTable(result,data),analysis,'Sheet','资源瓶颈','Range','A1');
problem2.writeDiagnostics(result,analysis);
if config.ExportParetoArchive
    paretoArchive = struct('Config',result.Config, ...
        'ParetoFront',result.ParetoFront, ...
        'ParetoSolutions',{result.ParetoSolutions}, ...
        'ParetoOutcomes',{result.ParetoOutcomes}, ...
        'WarmStartBaseline',result.WarmStartBaseline);
    save(archiveFile,'paretoArchive','-v7.3');
else
    archiveFile = "";
end
files = struct('Submissions',submissions,'Analysis',analysis, ...
    'ParetoArchive',archiveFile);
end

function writeRepresentativeSubmission(rep,templateFile,submission)
copied = false; message = '';
for attempt = 1:3
    [copied,message] = copyfile(templateFile,submission,'f');
    if copied, break; end
    pause(1);
end
if ~copied
    error('无法复制提交模板到 %s：%s',submission,message);
end
trips = sortrows(rep.Trips,{'Start_s','TripID'});
officialTrip = trips(:,{'TripID','DroneID','Model','BatteryID','Start_s','Route','Return_s','Energy_kWh'});
writetable(officialTrip,submission,'Sheet','Q2_运输架次','Range','A2','WriteVariableNames',false);
delivery = sortrows(rep.Deliveries,'BoxID');
officialDelivery = delivery(:,{'BoxID','TripID','ServiceID','Delivery_s'});
writetable(officialDelivery,submission,'Sheet','Q2_逐箱交付','Range','A2','WriteVariableNames',false);
end

function T = representativeSummary(result)
names = fieldnames(result.Representatives); n = numel(names);
label = strings(n,1); timeliness = zeros(n,1); makespan = zeros(n,1); energy = zeros(n,1); trips = zeros(n,1); index = zeros(n,1);
for k = 1:n
    r = result.Representatives.(names{k}); label(k) = string(names{k});
    timeliness(k) = r.Objectives.Timeliness; makespan(k) = r.Objectives.Makespan_s;
    energy(k) = r.Objectives.Energy_kWh; trips(k) = r.Objectives.TripCount; index(k) = r.ParetoIndex;
end
T = table(label,index,timeliness,makespan,energy,trips, ...
    'VariableNames',{'Representative','ParetoIndex','Timeliness','Makespan_s','Energy_kWh','TripCount'});
end

function T = buildRepresentativeTripTable(result)
names = fieldnames(result.Representatives); parts = cell(numel(names),1);
for k = 1:numel(names)
    x = result.Representatives.(names{k}).Trips; x.Representative = repmat(string(names{k}),height(x),1);
    parts{k} = movevars(x,'Representative','Before',1);
end
T = vertcat(parts{:}); T = sortrows(T,{'Representative','Start_s','TripID'});
end

function T = buildRepresentativeDeliveryTable(result)
names = fieldnames(result.Representatives); parts = cell(numel(names),1);
for k = 1:numel(names)
    x = result.Representatives.(names{k}).Deliveries; x.Representative = repmat(string(names{k}),height(x),1);
    parts{k} = movevars(x,'Representative','Before',1);
end
T = vertcat(parts{:}); T = sortrows(T,{'Representative','Delivery_s','BoxID'});
end

function T = buildRepresentativeValidationTable(result)
names = fieldnames(result.Representatives); parts = cell(numel(names),1);
for k = 1:numel(names)
    x = result.Representatives.(names{k}).Validation; x.Representative = repmat(string(names{k}),height(x),1);
    parts{k} = movevars(x,'Representative','Before',1);
end
T = vertcat(parts{:});
end

function T = buildResourceBottleneckTable(result,data)
names = fieldnames(result.Representatives); parts = cell(numel(names),1);
for k = 1:numel(names)
    rep = result.Representatives.(names{k}); makespan = rep.Objectives.Makespan_s;
    rows = cell(height(data.Models),1);
    for g = 1:height(data.Models)
        model = data.Models.Model(g); trips = rep.Trips(rep.Trips.Model==model,:);
        used = unique(trips.DroneID); duration = sum(trips.Return_s-trips.Start_s);
        droneCount = nnz(data.Drones.Model==model); batteryWait = sum(max(0,trips.Start_s));
        utilization = duration/max(eps,droneCount*makespan);
        rows{g} = table(string(names{k}),model,height(trips),droneCount,numel(used), ...
            duration,duration/droneCount,utilization,batteryWait, ...
            'VariableNames',{'Representative','Model','TripCount','FleetSize','UsedDrones', ...
            'TotalWork_s','WorkLowerBound_s','DroneUtilization','StartDelay_s'});
    end
    parts{k} = vertcat(rows{:});
end
T = vertcat(parts{:});
end

function T = buildParetoTripTable(result)
parts = cell(numel(result.ParetoOutcomes),1);
selectedID = result.ParetoFront.SolutionID(result.ParetoFront.IsSelected);
for k = 1:numel(result.ParetoOutcomes)
    x = result.ParetoOutcomes{k}.Trips;
    x.SolutionID = repmat(k,height(x),1);
    x.IsSelected = repmat(k == selectedID,height(x),1);
    parts{k} = movevars(x,{'SolutionID','IsSelected'},'Before',1);
end
T = vertcat(parts{:});
T = sortrows(T,{'SolutionID','Start_s','TripID'});
end

function T = buildParetoDeliveryTable(result)
parts = cell(numel(result.ParetoOutcomes),1);
selectedID = result.ParetoFront.SolutionID(result.ParetoFront.IsSelected);
for k = 1:numel(result.ParetoOutcomes)
    x = result.ParetoOutcomes{k}.Deliveries;
    x.SolutionID = repmat(k,height(x),1);
    x.IsSelected = repmat(k == selectedID,height(x),1);
    parts{k} = movevars(x,{'SolutionID','IsSelected'},'Before',1);
end
T = vertcat(parts{:});
T = sortrows(T,{'SolutionID','Delivery_s','BoxID'});
end

function checkpointFile = saveRunCheckpoint(archiveSolutions,archiveOutcomes, ...
    runLog,config,runIdx,completedIterations,elapsed_s)
if ~exist(config.CheckpointDir,'dir'), mkdir(config.CheckpointDir); end
checkpoint = struct();
checkpoint.Version = "problem2-moalns-v1";
checkpoint.CompletedRuns = runIdx;
checkpoint.CompletedIterations = completedIterations;
checkpoint.Elapsed_s = elapsed_s;
checkpoint.Config = config;
checkpoint.ParetoSolutions = archiveSolutions;
if isempty(archiveOutcomes)
    checkpoint.ParetoTable = table();
    checkpoint.ParetoObjectives = zeros(0,4);
else
    repIndex = chooseRepresentatives(archiveOutcomes);
    checkpoint.ParetoTable = makeParetoTable(archiveOutcomes,repIndex.Balanced);
    checkpoint.ParetoObjectives = zeros(numel(archiveOutcomes),4);
    for k = 1:numel(archiveOutcomes)
        checkpoint.ParetoObjectives(k,:) = archiveOutcomes{k}.Objectives;
    end
end
checkpoint.RunLog = runLog;
checkpointFile = fullfile(config.CheckpointDir, ...
    sprintf('问题二_ALNS档案_run%02d.mat',runIdx));
save(checkpointFile,'checkpoint','-v7.3');
end

function T = makeParetoTable(outcomes,selected)
n = numel(outcomes); rows = zeros(n,4);
for k = 1:n, rows(k,:) = outcomes{k}.Objectives; end
T = table((1:n).',rows(:,1),rows(:,2),rows(:,3),rows(:,4),(1:n).'==selected, ...
    'VariableNames',{'SolutionID','Timeliness','Makespan_s','Energy_kWh','TripCount','IsSelected'});
T = sortrows(T,{'Timeliness','Makespan_s','Energy_kWh','TripCount'});
end

function s = objectiveStruct(x)
s = struct('Timeliness',x(1),'Makespan_s',x(2),'Energy_kWh',x(3),'TripCount',x(4));
end

function x = nanCell2double(c)
x = nan(numel(c),1);
for k=1:numel(c)
    if isnumeric(c{k}) && isscalar(c{k}) && ~isnan(c{k}), x(k)=c{k}; end
end
end

function y = minNaN(a,b)
y = a;
for k=1:numel(a)
    if isnan(a(k)), y(k)=b(k); elseif ~isnan(b(k)), y(k)=min(a(k),b(k)); end
end
end

function text = formatDuration(seconds)
if ~isfinite(seconds), text = '未知'; return; end
seconds = round(max(0,seconds));
hours = floor(seconds/3600);
minutes = floor(mod(seconds,3600)/60);
secs = mod(seconds,60);
if hours > 0
    text = sprintf('%d时%02d分%02d秒',hours,minutes,secs);
elseif minutes > 0
    text = sprintf('%d分%02d秒',minutes,secs);
else
    text = sprintf('%d秒',secs);
end
end

function solution = emptySolution()
solution = struct('Trips',struct('BoxIdx',{},'Stops',{},'Model',{}),'Order',[]);
end
