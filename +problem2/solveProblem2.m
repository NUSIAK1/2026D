function result = solveProblem2(config)
%SOLVEPROBLEM2 多点组批、路径、机队和共享电池联合调度。
%
% 本实现以 MOALNS 搜索组批/路径/机型/派发顺序，并通过事件驱动
% 解码器分配实体无人机和电池。所有航段物理量均由 common.calcLegCost
% 预计算，避免复制问题一已验证的能耗口径。

if nargin < 1, config = struct(); end
config = applyDefaults(config);
rng(config.RandomSeed,'twister');

paths = common.projectPaths();
if ~isfile(config.FlightBaseFile)
    error('未找到 flightBase.mat，请先运行 common.computeTerrainMatrices()。');
end
S = load(config.FlightBaseFile);
data = loadProblemData(config, S);
base = precomputeLegs(data, S, config.Verbose);

archiveSolutions = {};
archiveOutcomes = {};
runLog = table();
bestSeedSolution = [];
bestSeedOutcome = [];
overallClock = tic;
completedIterations = 0;
plannedIterations = config.NumRuns*config.MaxIterations;

for runIdx = 1:config.NumRuns
    if config.ProgressEnabled
        fprintf('[Q2] 开始 ALNS 第 %d/%d 次独立运行（最多 %d 次迭代）。\n', ...
            runIdx,config.NumRuns,config.MaxIterations);
    end
    rng(config.RandomSeed+runIdx-1,'twister');
    current = buildInitialSolution(data, base);
    current = repairHardDeadlines(current, data, base, config);
    currentOutcome = decodeSolution(current, data, base);
    [archiveSolutions,archiveOutcomes,added] = updateArchive( ...
        archiveSolutions, archiveOutcomes, current, currentOutcome, config.ArchiveSize);

    destroyScore = ones(1,3);
    stagnant = 0;
    accepted = 0;
    for iter = 1:config.MaxIterations
        operator = roulette(destroyScore);
        candidate = perturbSolution(current, data, base, operator);
        candidate = repairHardDeadlines(candidate, data, base, config);
        candidateOutcome = decodeSolution(candidate, data, base);

        [archiveSolutions,archiveOutcomes,isAdded] = updateArchive( ...
            archiveSolutions, archiveOutcomes, candidate, candidateOutcome, config.ArchiveSize);
        if isAdded
            destroyScore(operator) = 0.85*destroyScore(operator)+0.15*6;
            stagnant = 0;
        else
            destroyScore(operator) = 0.97*destroyScore(operator)+0.03;
            stagnant = stagnant+1;
        end

        temperature = max(0.01, 1-iter/config.MaxIterations);
        if acceptCandidate(currentOutcome,candidateOutcome,temperature)
            current = candidate;
            currentOutcome = candidateOutcome;
            accepted = accepted+1;
        end
        completedIterations = completedIterations+1;
        if config.ProgressEnabled && (iter == 1 || ...
                mod(iter,config.ProgressEvery) == 0 || iter == config.MaxIterations)
            elapsed_s = toc(overallClock);
            rate = completedIterations/max(elapsed_s,eps);
            eta_s = max(0,(plannedIterations-completedIterations)/rate);
            fprintf(['[Q2] run %d/%d | iter %d/%d | 总进度 %.1f%% | ' ...
                'Pareto %d | 已耗时 %s | 预计剩余 %s（按最大迭代上限）\n'], ...
                runIdx,config.NumRuns,iter,config.MaxIterations, ...
                100*completedIterations/plannedIterations,numel(archiveOutcomes), ...
                formatDuration(elapsed_s),formatDuration(eta_s));
            drawnow limitrate;
        end
        if stagnant >= config.StagnationLimit
            if config.ProgressEnabled
                fprintf('[Q2] 第 %d 次运行因连续 %d 次未改进而提前停止。\n', ...
                    runIdx,stagnant);
            end
            break;
        end
    end

    runRow = table(runIdx,iter,accepted,currentOutcome.Feasible, ...
        currentOutcome.Objectives(1),currentOutcome.Objectives(2), ...
        currentOutcome.Objectives(3),currentOutcome.Objectives(4), ...
        'VariableNames',{'Run','Iterations','Accepted','Feasible', ...
        'Timeliness','Makespan_s','Energy_kWh','TripCount'});
    runLog = [runLog;runRow]; %#ok<AGROW>
    if isempty(bestSeedOutcome) || scoreOutcome(currentOutcome) < scoreOutcome(bestSeedOutcome)
        bestSeedSolution = current;
        bestSeedOutcome = currentOutcome;
    end
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

selectedIndex = chooseKneePoint(archiveOutcomes);
selectedSolution = archiveSolutions{selectedIndex};
selectedOutcome = archiveOutcomes{selectedIndex};
validation = validateOutcome(selectedSolution,selectedOutcome,data,base);

paretoTable = makeParetoTable(archiveOutcomes,selectedIndex);
result = struct();
result.Config = config;
result.DataSummary = table(height(data.Boxes),sum(data.Boxes.Mass_kg), ...
    sum(data.Boxes.Volume_m3),'VariableNames',{'BoxCount','TotalMass_kg','TotalVolume_m3'});
result.Selected = struct('Solution',selectedSolution,'Objectives', ...
    objectiveStruct(selectedOutcome.Objectives),'Trips',selectedOutcome.Trips, ...
    'Deliveries',selectedOutcome.Deliveries,'DroneTimeline',selectedOutcome.DroneTimeline, ...
    'BatteryTimeline',selectedOutcome.BatteryTimeline);
result.ParetoFront = paretoTable;
result.ParetoSolutions = archiveSolutions;
result.Validation = validation;
result.RunLog = runLog;
result.OutputFiles = struct();
if config.ExportFiles
    result.OutputFiles = exportResults(result,data,config);
end

if config.Verbose
    fprintf('问题二：得到 %d 个可行非支配方案，选择方案 %d。\n', ...
        numel(archiveOutcomes), selectedIndex);
end
end

function config = applyDefaults(config)
paths = common.projectPaths();
defaults = struct( ...
    'FlightBaseFile',paths.FlightBaseFile, ...
    'DemandFile',paths.DemandFile, ...
    'TransportUavFile',paths.TransportUavFile, ...
    'TemplateFile',paths.TemplateFile, ...
    'ResultDir',paths.ResultDir, ...
    'ExportFiles',true, ...
    'RandomSeed',2026, ...
    'NumRuns',10, ...
    'MaxIterations',10000, ...
    'StagnationLimit',2000, ...
    'ArchiveSize',500, ...
    'ProgressEnabled',true, ...
    'ProgressEvery',100, ...
    'SaveRunArchive',true, ...
    'CheckpointDir',fullfile(paths.ResultDir,'问题二_ALNS检查点'), ...
    'Verbose',true);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(config,names{k}) || isempty(config.(names{k}))
        config.(names{k}) = defaults.(names{k});
    end
end
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
end

function solution = buildInitialSolution(data, base)
n = height(data.Boxes);
solution = emptySolution();

% 先为每个服务区的医疗/首批货箱建立独立紧急架次。软货箱不得在
% 初始构造阶段并入这些架次，以免增加准备、装载和交接时间而压缩硬时限。
hardMask = ~isnan(data.Boxes.HardDeadline_s);
hardServices = unique(data.Boxes.ServiceID(hardMask),'stable');
for s = 1:numel(hardServices)
    boxIdx = find(data.Boxes.ServiceID == hardServices(s) & hardMask).';
    best = []; bestTime = inf;
    for g = 1:height(data.Models)
        candidate = struct('BoxIdx',boxIdx,'Stops',hardServices(s), ...
            'Model',data.Models.Model(g));
        info = evaluateTrip(candidate,data,base);
        if info.Feasible
            hardOffsets = info.DeliveryOffset_s;
            hardDeadline = data.Boxes.HardDeadline_s(boxIdx);
            if all(hardOffsets <= hardDeadline+1e-7) && max(hardOffsets) < bestTime
                best = candidate; bestTime = max(hardOffsets);
            end
        end
    end
    if isempty(best)
        error('服务区 %s 的医疗/首批货箱无法形成单独可行架次。',hardServices(s));
    end
    solution.Trips(end+1) = best;
end

remaining = find(~hardMask).';
[~,perm] = sortrows([data.Boxes.ExpectedDeadline_s(remaining), ...
    -data.Boxes.Priority(remaining)],[1 2]);
order = remaining(perm);
for q = 1:numel(order)
    solution = insertBoxGreedy(solution,order(q),data,base);
end
solution.Order = urgencyOrder(solution,data);
end

function solution = buildInitialSolution_legacy(data, base) %#ok<DEFNU>
n = height(data.Boxes); %#ok<NASGU>
[~,order] = sortrows([isnan(data.Boxes.HardDeadline_s), ...
    replaceNaN(data.Boxes.HardDeadline_s,inf),data.Boxes.ExpectedDeadline_s, ...
    -data.Boxes.Priority],[1 2 3 4]);
solution = emptySolution();
for q = 1:numel(order)
    solution = insertBoxGreedy(solution,order(q),data,base);
end
solution.Order = urgencyOrder(solution,data);
end

function solution = perturbSolution(solution,data,base,operator)
if isempty(solution.Trips), return; end
nTrip = numel(solution.Trips);
switch operator
    case 1 % 随机货箱破坏
        allBox = [solution.Trips.BoxIdx];
        remove = allBox(randperm(numel(allBox),min(numel(allBox),randi([2,min(8,numel(allBox))]))));
    case 2 % 相关服务区破坏
        seedTrip = solution.Trips(randi(nTrip));
        seedService = seedTrip.Stops(randi(numel(seedTrip.Stops)));
        allServices = data.Boxes.ServiceID;
        remove = find(allServices == seedService);
        if numel(remove) > 8, remove = remove(randperm(numel(remove),8)); end
    otherwise % 整架次或最差架次破坏
        idx = randi(nTrip);
        remove = solution.Trips(idx).BoxIdx;
end
solution = removeBoxes(solution,remove,data);
remove = remove(randperm(numel(remove)));
for k = 1:numel(remove)
    solution = insertBoxGreedy(solution,remove(k),data,base);
end

if ~isempty(solution.Trips) && rand < 0.45
    r = randi(numel(solution.Trips));
    if numel(solution.Trips(r).Stops) >= 2
        solution.Trips(r).Stops = fliplr(solution.Trips(r).Stops);
    end
end
if ~isempty(solution.Trips) && rand < 0.35
    r = randi(numel(solution.Trips));
    feasibleModels = feasibleModelsForBoxes(solution.Trips(r).BoxIdx,solution.Trips(r).Stops,data,base);
    if ~isempty(feasibleModels)
        solution.Trips(r).Model = feasibleModels(randi(numel(feasibleModels)));
    end
end
solution.Order = urgencyOrder(solution,data);
if rand < 0.3 && numel(solution.Order) >= 2
    p = randperm(numel(solution.Order),2);
    solution.Order(p) = solution.Order(fliplr(p));
end
end

function solution = insertBoxGreedy(solution,boxIdx,data,base)
best = []; bestScore = inf;
for r = 1:numel(solution.Trips)
    original = solution.Trips(r);
    service = data.Boxes.ServiceID(boxIdx);
    % 初始构造中，软货箱不并入含硬时限货箱的架次；后续 ALNS 可在
    % 调度可行性校验下自行探索此类合并。
    if isnan(data.Boxes.HardDeadline_s(boxIdx)) && ...
            any(~isnan(data.Boxes.HardDeadline_s(original.BoxIdx)))
        continue;
    end
    if any(original.Stops == service)
        candidate = original;
        candidate.BoxIdx = [candidate.BoxIdx,boxIdx];
        models = [candidate.Model; feasibleModelsForBoxes(candidate.BoxIdx,candidate.Stops,data,base)];
        models = unique(models,'stable');
        for g = 1:numel(models)
            candidate.Model = models(g);
            info = evaluateTrip(candidate,data,base);
            if info.Feasible && tripScore(info) < bestScore
                best = struct('Trip',candidate,'Index',r); bestScore = tripScore(info);
            end
        end
    else
        for pos = 1:numel(original.Stops)+1
            candidate = original;
            candidate.BoxIdx = [candidate.BoxIdx,boxIdx];
            candidate.Stops = [candidate.Stops(1:pos-1),service,candidate.Stops(pos:end)];
            models = feasibleModelsForBoxes(candidate.BoxIdx,candidate.Stops,data,base);
            for g = 1:numel(models)
                candidate.Model = models(g);
                info = evaluateTrip(candidate,data,base);
                if info.Feasible && tripScore(info) < bestScore
                    best = struct('Trip',candidate,'Index',r); bestScore = tripScore(info);
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
else
    solution.Trips(best.Index) = best.Trip;
end
end

function models = feasibleModelsForBoxes(boxIdx,stops,data,base)
models = strings(0,1);
for g = 1:height(data.Models)
    candidate = struct('BoxIdx',boxIdx,'Stops',stops,'Model',data.Models.Model(g));
    if evaluateTrip(candidate,data,base).Feasible
        models(end+1,1) = candidate.Model; %#ok<AGROW>
    end
end
end

function info = evaluateTrip(trip,data,base)
boxes = data.Boxes(trip.BoxIdx,:);
g = find(data.Models.Model == trip.Model,1);
if isempty(g), error('未知机型 %s。',trip.Model); end
info = struct('Feasible',false,'Mass_kg',sum(boxes.Mass_kg), ...
    'Volume_m3',sum(boxes.Volume_m3),'Energy_kWh',inf,'Duration_s',inf, ...
    'ReturnSOC',-inf,'ChargeTime_s',inf,'DeliveryOffset_s',nan(numel(trip.BoxIdx),1));
if info.Mass_kg > data.Models.MaxPayload_kg(g)+1e-9 || ...
        info.Volume_m3 > data.Models.MaxVolume_m3(g)+1e-12 || ...
        numel(unique(trip.Stops)) ~= numel(trip.Stops)
    return;
end
if ~all(ismember(unique(boxes.ServiceID),trip.Stops)) || ...
        ~all(ismember(trip.Stops,unique(boxes.ServiceID)))
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
        return;
    end
    e = base.Energy_kWh(i,j,g,round(payload)+1);
    if isnan(e), return; end
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
    return;
end
info.ChargeTime_s = problem2.chargeTime(info.ReturnSOC, ...
    batteryFullTime(trip.Model,data));
info.Feasible = all(isfinite(info.DeliveryOffset_s));
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

tripRows = cell(nTrip,1); deliveryRows = cell(nTrip,1); droneRows = cell(nTrip,1); batteryRows = cell(nTrip,1);
for r = 1:nTrip
    trip = solution.Trips(r); info = infos(r);
    tripID = sprintf('T%03d',r);
    tripRows{r} = table(string(tripID),tripDrone(r),trip.Model,tripBattery(r),tripStart(r), ...
        string(strjoin(cellstr(trip.Stops),'->')),tripStart(r)+info.Duration_s,info.Energy_kWh, ...
        info.Mass_kg,info.Volume_m3,100*info.ReturnSOC,info.ChargeTime_s, ...
        'VariableNames',{'TripID','DroneID','Model','BatteryID','Start_s', ...
        'Route','Return_s','Energy_kWh','Mass_kg','Volume_m3','ReturnSOC_pct','ChargeTime_s'});
    b = data.Boxes(trip.BoxIdx,:);
    deliveryRows{r} = table(b.BoxID,repmat(string(tripID),height(b),1),b.ServiceID, ...
        tripStart(r)+info.DeliveryOffset_s,b.IsMedical,b.IsFirst,b.HardDeadline_s, ...
        b.ExpectedDeadline_s,b.Priority, ...
        'VariableNames',{'BoxID','TripID','ServiceID','Delivery_s','IsMedical', ...
        'IsFirst','HardDeadline_s','ExpectedDeadline_s','Priority'});
    droneRows{r} = table(tripDrone(r),string(tripID),tripStart(r), ...
        tripStart(r)+info.Duration_s,'VariableNames',{'DroneID','TripID','Start_s','End_s'});
    batteryRows{r} = table(tripBattery(r),string(tripID),tripStart(r), ...
        tripStart(r)+info.Duration_s,tripStart(r)+info.Duration_s+info.ChargeTime_s, ...
        'VariableNames',{'BatteryID','TripID','TaskStart_s','Return_s','Available_s'});
end
trips = vertcat(tripRows{:}); deliveries = vertcat(deliveryRows{:});
droneTimeline = vertcat(droneRows{:}); batteryTimeline = vertcat(batteryRows{:});
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
for pass = 1:height(data.Boxes)
    out = decodeSolution(solution,data,base);
    lateMask = ~isnan(out.Deliveries.HardDeadline_s) & ...
        out.Deliveries.Delivery_s > out.Deliveries.HardDeadline_s+1e-7;
    late = out.Deliveries.BoxID(lateMask);
    if isempty(late), return; end
    idx = find(data.Boxes.BoxID == late(1),1);
    solution = removeBoxes(solution,idx,data);
    best = [];
    for g = 1:height(data.Models)
        cand = struct('BoxIdx',idx,'Stops',data.Boxes.ServiceID(idx),'Model',data.Models.Model(g));
        if evaluateTrip(cand,data,base).Feasible
            best = cand; break;
        end
    end
    if isempty(best), return; end
    solution.Trips(end+1) = best;
    solution.Order = urgencyOrder(solution,data);
end
end

function solution = removeBoxes(solution,boxIdx,data)
for r = numel(solution.Trips):-1:1
    keep = ~ismember(solution.Trips(r).BoxIdx,boxIdx);
    solution.Trips(r).BoxIdx = solution.Trips(r).BoxIdx(keep);
    if isempty(solution.Trips(r).BoxIdx)
        solution.Trips(r) = [];
    else
        presentServices = unique(data.Boxes.ServiceID(solution.Trips(r).BoxIdx),'stable');
        solution.Trips(r).Stops = solution.Trips(r).Stops( ...
            ismember(solution.Trips(r).Stops,presentServices));
    end
end
solution = normalizeTrips(solution);
solution.Order = 1:numel(solution.Trips);
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

function [solutions,outcomes,added] = updateArchive(solutions,outcomes,solution,outcome,maxSize)
added = false;
if ~outcome.Feasible, return; end
obj = outcome.Objectives;
remove = false(1,numel(outcomes));
for k = 1:numel(outcomes)
    old = outcomes{k}.Objectives;
    if all(old <= obj+1e-9) && any(old < obj-1e-9), return; end
    if all(abs(old-obj) <= 1e-9), return; end
    if all(obj <= old+1e-9) && any(obj < old-1e-9), remove(k) = true; end
end
solutions(remove) = []; outcomes(remove) = [];
solutions{end+1} = solution; outcomes{end+1} = outcome; added = true;
if numel(outcomes) > maxSize
    obj = zeros(numel(outcomes),4);
    for k = 1:numel(outcomes), obj(k,:) = outcomes{k}.Objectives; end
    span = max(obj,[],1)-min(obj,[],1); span(span < 1e-12) = 1;
    score = sum((obj-min(obj,[],1))./span,2);
    [~,drop] = max(score); solutions(drop)=[]; outcomes(drop)=[];
end
end

function index = chooseKneePoint(outcomes)
obj = zeros(numel(outcomes),4);
for k = 1:numel(outcomes), obj(k,:) = outcomes{k}.Objectives; end
lo = min(obj,[],1); hi = max(obj,[],1); span = hi-lo; span(span < 1e-12)=1;
z = (obj-lo)./span;
key = [max(z,[],2),sum(z,2),z];
[~,index] = sortrows(key,1:size(key,2)); index = index(1);
end

function tf = acceptCandidate(current,candidate,temperature)
if candidate.Feasible && ~current.Feasible, tf = true; return; end
if ~candidate.Feasible && current.Feasible, tf = false; return; end
delta = scoreOutcome(candidate)-scoreOutcome(current);
tf = delta <= 0 || rand < exp(-delta/max(temperature,1e-9));
end

function value = scoreOutcome(outcome)
o = outcome.Objectives;
value = 1e9*(~outcome.Feasible)+outcome.Violation+1e5*o(1)+o(2)/10+100*o(3)+500*o(4);
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
submission = fullfile(config.ResultDir,'问题二_结果提交.xlsx');
analysis = fullfile(config.ResultDir,'问题二_多目标调度分析.xlsx');
copyfile(config.TemplateFile,submission,'f');
trips = sortrows(result.Selected.Trips,{'Start_s','TripID'});
officialTrip = trips(:,{'TripID','DroneID','Model','BatteryID','Start_s','Route','Return_s','Energy_kWh'});
writetable(officialTrip,submission,'Sheet','Q2_运输架次','Range','A2','WriteVariableNames',false);
delivery = sortrows(result.Selected.Deliveries,'BoxID');
officialDelivery = delivery(:,{'BoxID','TripID','ServiceID','Delivery_s'});
writetable(officialDelivery,submission,'Sheet','Q2_逐箱交付','Range','A2','WriteVariableNames',false);
if isfile(analysis), delete(analysis); end
summary = {'指标','数值';'及时性目标',result.Selected.Objectives.Timeliness; ...
    '全部任务完成时间（s）',result.Selected.Objectives.Makespan_s; ...
    '总能耗（kWh）',result.Selected.Objectives.Energy_kWh; ...
    '架次数',result.Selected.Objectives.TripCount};
writecell(summary,analysis,'Sheet','主方案','Range','A1');
writetable(result.Selected.Trips,analysis,'Sheet','主方案','Range','A8');
writetable(result.ParetoFront,analysis,'Sheet','Pareto前沿','Range','A1');
writetable(result.Selected.Deliveries,analysis,'Sheet','逐箱交付','Range','A1');
writetable(result.Selected.DroneTimeline,analysis,'Sheet','无人机时间线','Range','A1');
writetable(result.Selected.BatteryTimeline,analysis,'Sheet','电池时间线','Range','A1');
writetable(result.Validation,analysis,'Sheet','校核','Range','A1');
writetable(result.RunLog,analysis,'Sheet','算法稳定性','Range','A1');
exportFigures(result,data,config.ResultDir);
files = struct('Submission',submission,'Analysis',analysis);
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
checkpoint.ParetoOutcomes = archiveOutcomes;
if isempty(archiveOutcomes)
    checkpoint.ParetoTable = table();
else
    checkpoint.ParetoTable = makeParetoTable(archiveOutcomes, ...
        chooseKneePoint(archiveOutcomes));
end
checkpoint.RunLog = runLog;
checkpointFile = fullfile(config.CheckpointDir, ...
    sprintf('问题二_ALNS档案_run%02d.mat',runIdx));
save(checkpointFile,'checkpoint','-v7.3');
end

function exportFigures(result,data,resultDir)
figureDir = fullfile(resultDir,'问题二_图表');
if ~exist(figureDir,'dir'), mkdir(figureDir); end
try
    trips = result.Selected.Trips;
    f = figure('Visible','off','Color','w'); hold on;
    plot(data.Nodes.Lon,data.Nodes.Lat,'k.','MarkerSize',14);
    text(data.Nodes.Lon,data.Nodes.Lat,cellstr(data.Nodes.ID),'FontSize',7, ...
        'VerticalAlignment','bottom');
    colors = lines(max(1,height(trips)));
    for r = 1:height(trips)
        stops = split(string(trips.Route),'->');
        ids = ["O01";stops;"O01"];
        idx = arrayfun(@(x)find(data.Nodes.ID==x,1),ids);
        plot(data.Nodes.Lon(idx),data.Nodes.Lat(idx),'-o','Color',colors(r,:), ...
            'MarkerSize',3,'LineWidth',1);
    end
    xlabel('经度（°）'); ylabel('纬度（°）'); title('问题二主方案运输路线'); grid on;
    exportgraphics(f,fullfile(figureDir,'运输路线.png'),'Resolution',180); close(f);

    f = figure('Visible','off','Color','w');
    drawTimeline(result.Selected.DroneTimeline,'DroneID','Start_s','End_s','无人机');
    title('无人机任务甘特图'); xlabel('时间（s）');
    exportgraphics(f,fullfile(figureDir,'无人机甘特图.png'),'Resolution',180); close(f);

    f = figure('Visible','off','Color','w');
    drawTimeline(result.Selected.BatteryTimeline,'BatteryID','TaskStart_s','Available_s','电池');
    title('电池任务与充电甘特图'); xlabel('时间（s）');
    exportgraphics(f,fullfile(figureDir,'电池甘特图.png'),'Resolution',180); close(f);

    p = result.ParetoFront;
    f = figure('Visible','off','Color','w');
    scatter3(p.Makespan_s,p.Energy_kWh,p.TripCount,45,p.Timeliness,'filled');
    colorbar; xlabel('完成时间（s）'); ylabel('总能耗（kWh）'); zlabel('架次数');
    title('问题二 Pareto 前沿（颜色为及时性目标）'); grid on;
    exportgraphics(f,fullfile(figureDir,'Pareto前沿.png'),'Resolution',180); close(f);
catch ME
    warning('问题二图表导出失败：%s',ME.message);
end
end

function drawTimeline(T,idVar,startVar,endVar,label)
ids = unique(T.(idVar),'stable'); hold on;
for k = 1:numel(ids)
    rows = T(T.(idVar)==ids(k),:);
    for r = 1:height(rows)
        rectangle('Position',[rows.(startVar)(r),k-0.35, ...
            rows.(endVar)(r)-rows.(startVar)(r),0.7], ...
            'FaceColor',[0.25 0.55 0.85],'EdgeColor','none');
    end
end
yticks(1:numel(ids)); yticklabels(cellstr(ids)); ylabel(label); grid on;
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

function y = replaceNaN(x,value)
y=x; y(isnan(y))=value;
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
