function result = solveProblem1Pareto(config)
%SOLVEPROBLEM1PARETO 问题一：单点往返组批的多目标 DP/Pareto 求解。
%
% result = solveProblem1Pareto()
% result = solveProblem1Pareto(config)
%
% config 可选字段：
%   DataDir           基础数据目录
%   TemplateFile      结果提交模板
%   FlightBaseFile    flightBase.mat 路径
%   OutputDir         结果输出目录
%   ReserveRatios     安全余量情景，默认 0.10:0.05:0.30
%   BaselineRatio     基准安全余量，默认 0.20
%   ExportFiles       是否输出 xlsx，默认 true
%   Tolerance         Pareto 比较容差 [N,E,T]

if nargin < 1
    config = struct();
end
config = applyDefaults(config);

if ~isfile(config.FlightBaseFile)
    error('未找到 %s，请先运行 common.computeTerrainMatrices()。',config.FlightBaseFile);
end

flightBase = load(config.FlightBaseFile);
data = readProblemData(config,flightBase);

reserveRatios = unique(double(config.ReserveRatios(:)).','stable');
if ~any(abs(reserveRatios-config.BaselineRatio) <= 1e-12)
    error('ReserveRatios 必须包含 BaselineRatio。');
end

scenarioTemplate = struct('ReserveRatio',[], 'Services',[], ...
    'GlobalFront',table(), 'SelectedChoices',[], 'SelectedTrips',table(), ...
    'MaxSafePayload',table(), 'ModeSummary',table(), 'Validation',table());
scenarios = repmat(scenarioTemplate,numel(reserveRatios),1);

for rr = 1:numel(reserveRatios)
    scenarios(rr) = solveScenario(data,flightBase,reserveRatios(rr),config.Tolerance);
end

baselineIndex = find(abs(reserveRatios-config.BaselineRatio) <= 1e-12,1);
baseline = scenarios(baselineIndex);

sensitivity = buildSensitivityTable(scenarios);
maxSafePayload = vertcat(scenarios.MaxSafePayload);
validation = baseline.Validation;

qMonotone = checkPayloadMonotonicity(maxSafePayload);
nMonotone = all(diff(sensitivity.N) >= 0);
validation = [validation; makeCheck("安全余量增加时最大安全载荷不增加",qMonotone, ...
    "按服务区和机型检查五个情景"); ...
    makeCheck("安全余量增加时最少架次数不减少",nMonotone, ...
    "按字典序主方案检查五个情景")];

result = struct();
result.Config = config;
result.Input = data;
result.Scenarios = scenarios;
result.Baseline = baseline;
result.MaxSafePayload = maxSafePayload;
result.FeasibleModes = {baseline.Services.AllModes}.';
result.ServiceFronts = {baseline.Services.Front}.';
result.GlobalFront = baseline.GlobalFront;
result.Selected = struct('Choices',baseline.SelectedChoices, ...
    'Trips',baseline.SelectedTrips, ...
    'Objectives',baseline.GlobalFront(1,{'N','E_kWh','T_s'}));
result.Sensitivity = sensitivity;
result.Validation = validation;
result.OutputFiles = struct('Submission',"",'Analysis',"");

if config.ExportFiles
    result.OutputFiles = exportResults(result);
end
end

function config = applyDefaults(config)
paths = common.projectPaths();

defaults = struct();
defaults.DataDir = paths.BaseDataDir;
defaults.TemplateFile = paths.TemplateFile;
defaults.FlightBaseFile = paths.FlightBaseFile;
defaults.OutputDir = paths.ResultDir;
defaults.ReserveRatios = 0.10:0.05:0.30;
defaults.BaselineRatio = 0.20;
defaults.ExportFiles = true;
defaults.Tolerance = [0,1e-9,1e-6];

names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(config,names{k}) || isempty(config.(names{k}))
        config.(names{k}) = defaults.(names{k});
    end
end

if any(config.ReserveRatios < 0 | config.ReserveRatios >= 1)
    error('ReserveRatios 必须满足 0 <= rho < 1。');
end
if config.BaselineRatio < 0 || config.BaselineRatio >= 1
    error('BaselineRatio 必须满足 0 <= rho < 1。');
end
end

function data = readProblemData(config,flightBase)
demandFile = fullfile(config.DataDir,'物资需求与配送时限.xlsx');
if ~isfile(demandFile)
    error('未找到需求数据：%s。',demandFile);
end

materialNames = ["医疗物资","饮用水","应急食品","生活卫生用品"];
demandRaw = readcell(demandFile,'Sheet','数据');

serviceIDs = strings(0,1);
for r = 2:size(demandRaw,1)
    sid = string(demandRaw{r,1});
    if startsWith(sid,"S") && ~any(serviceIDs == sid)
        serviceIDs(end+1,1) = sid; %#ok<AGROW>
    end
end
serviceIDs = sort(serviceIDs);
demand = zeros(numel(serviceIDs),4);

for r = 2:size(demandRaw,1)
    sid = string(demandRaw{r,1});
    material = string(demandRaw{r,2});
    if ~startsWith(sid,"S")
        continue;
    end
    ii = find(serviceIDs == sid,1);
    jj = find(materialNames == material,1);
    if isempty(jj)
        error('无法识别物资类型：%s。',material);
    end
    demand(ii,jj) = double(demandRaw{r,3});
end

boxRaw = readcell(demandFile,'Sheet','逐箱货箱清单');
nBox = size(boxRaw,1)-1;
boxID = strings(nBox,1);
boxService = strings(nBox,1);
boxMaterial = strings(nBox,1);
boxMass = zeros(nBox,1);
boxVolume = zeros(nBox,1);
boxTypeIndex = zeros(nBox,1);
valid = false(nBox,1);

for r = 2:size(boxRaw,1)
    k = r-1;
    boxID(k) = string(boxRaw{r,1});
    if boxID(k) == "" || ismissing(boxID(k))
        continue;
    end
    valid(k) = true;
    boxService(k) = string(boxRaw{r,2});
    boxMaterial(k) = string(boxRaw{r,3});
    boxMass(k) = double(boxRaw{r,4});
    boxVolume(k) = double(boxRaw{r,5});
    boxTypeIndex(k) = find(materialNames == boxMaterial(k),1);
end

boxes = table(boxID(valid),boxService(valid),boxMaterial(valid), ...
    boxTypeIndex(valid),boxMass(valid),boxVolume(valid), ...
    'VariableNames',{'BoxID','ServiceID','Material','TypeIndex', ...
    'Mass_kg','Volume_m3'});

if numel(serviceIDs) ~= 15
    error('应读取 15 个服务区，实际读取 %d 个。',numel(serviceIDs));
end
if height(boxes) ~= 80
    error('应读取 80 个货箱，实际读取 %d 个。',height(boxes));
end
if height(flightBase.uav) ~= 3
    error('flightBase 中应包含 3 种运输机型。');
end

data = struct();
data.ServiceIDs = serviceIDs;
data.MaterialNames = materialNames;
data.Demand = demand;
data.Boxes = boxes;
data.DemandFile = demandFile;
end

function scenario = solveScenario(data,flightBase,reserveRatio,tolerance)
nService = numel(data.ServiceIDs);
serviceTemplate = struct('ServiceID',"",'Demand',zeros(1,4), ...
    'AllModes',table(),'Modes',table(),'Front',table(),'StateCount',0);
services = repmat(serviceTemplate,nService,1);
maxSafeParts = cell(nService,1);
modeSummaryParts = cell(nService,1);

for ii = 1:nService
    sid = data.ServiceIDs(ii);
    demand = data.Demand(ii,:);
    [qMax,detail] = problem1.calcMaxSafePayload(sid,flightBase,reserveRatio);
    detail.ServiceID = repmat(sid,height(detail),1);
    detail.ReserveRatio(:) = reserveRatio;
    detail = movevars(detail,{'ServiceID','ReserveRatio'},'Before',1);
    maxSafeParts{ii} = detail(:,{'ServiceID','Model','ReserveRatio', ...
        'RatedMaxPayload_kg','MaxSafePayload_kg','BindingConstraint', ...
        'EnergyLimit_kWh','EmptyRoundTripFeasible','FullRatedLoadFeasible'});

    allModes = buildModes(sid,demand,qMax,flightBase,reserveRatio,tolerance);
    dpModes = pruneEquivalentModes(allModes,tolerance);
    dp = problem1.solveServiceParetoDP(demand,dpModes,struct('Tolerance',tolerance));

    services(ii).ServiceID = sid;
    services(ii).Demand = demand;
    services(ii).AllModes = allModes;
    services(ii).Modes = dpModes;
    services(ii).Front = dp.Front;
    services(ii).StateCount = dp.StateCount;

    modeSummaryParts{ii} = table(sid,reserveRatio,height(allModes), ...
        height(dpModes),dp.StateCount,height(dp.Front), ...
        'VariableNames',{'ServiceID','ReserveRatio','FeasibleModeCount', ...
        'DPModeCount','StateCount','LocalParetoCount'});
end

[globalFront,selectedChoices] = combineServiceFronts(services,tolerance);
selectedTrips = reconstructTrips(services,selectedChoices,data,flightBase,reserveRatio);
validation = validateScenario(services,globalFront,selectedTrips,data,flightBase,reserveRatio,tolerance);

scenario = struct();
scenario.ReserveRatio = reserveRatio;
scenario.Services = services;
scenario.GlobalFront = globalFront;
scenario.SelectedChoices = selectedChoices;
scenario.SelectedTrips = selectedTrips;
scenario.MaxSafePayload = vertcat(maxSafeParts{:});
scenario.ModeSummary = vertcat(modeSummaryParts{:});
scenario.Validation = validation;
end

function modes = buildModes(serviceID,demand,qMax,flightBase,reserveRatio,tolerance)
uav = flightBase.uav;
combos = problem1.genPayloadCombos(qMax,uav.MaxVolume,demand,false,uav.ID);
if isempty(combos)
    error('服务区 %s 在安全余量 %.0f%% 下没有可行装载模式。', ...
        serviceID,100*reserveRatio);
end

n = height(combos);
totalBoxes = sum(combos{:,{'Med','Water','Food','Hygiene'}},2);
flightTime = zeros(n,1);
operationTime = zeros(n,1);
energy = zeros(n,1);
soc = zeros(n,1);
budget = zeros(n,1);
maxVolume = zeros(n,1);
maxSafe = zeros(n,1);
modelIndex = zeros(n,1);

for r = 1:n
    model = string(combos.Drone(r));
    g = find(uav.ID == model,1);
    if isempty(g)
        error('未找到机型 %s。',model);
    end
    modelIndex(r) = g;
    outLeg = common.calcLegCost("O01",serviceID,model,combos.TotalMass_kg(r),flightBase);
    backLeg = common.calcLegCost(serviceID,"O01",model,0,flightBase);
    flightTime(r) = outLeg.T_total + backLeg.T_total;
    energy(r) = outLeg.E_total + backLeg.E_total;
    budget(r) = (1-reserveRatio)*uav.BatteryUse(g);
    soc(r) = 100*(1-energy(r)/uav.BatteryUse(g));
    maxVolume(r) = uav.MaxVolume(g);
    maxSafe(r) = qMax(g);
    operationTime(r) = uav.PrepTime(g) + ...
        uav.LoadTimeBox(g)*totalBoxes(r) + flightTime(r) + ...
        uav.HandoverBase(g) + uav.HandoverBox(g)*totalBoxes(r);
end

feasible = energy <= budget+tolerance(2) & ...
    combos.TotalMass_kg <= maxSafe+1e-6 & ...
    combos.TotalVolume_m3 <= maxVolume+1e-12;
combos = combos(feasible,:);
totalBoxes = totalBoxes(feasible);
flightTime = flightTime(feasible);
operationTime = operationTime(feasible);
energy = energy(feasible);
soc = soc(feasible);
budget = budget(feasible);
maxVolume = maxVolume(feasible);
maxSafe = maxSafe(feasible);
modelIndex = modelIndex(feasible);

modes = combos;
modes.TotalBoxes = totalBoxes;
modes.RoundTripTime_s = flightTime;
modes.OperationTime_s = operationTime;
modes.Energy_kWh = energy;
modes.ReturnSOC_pct = soc;
modes.EnergyBudget_kWh = budget;
modes.MaxVolume_m3 = maxVolume;
modes.MaxSafePayload_kg = maxSafe;
modes.ModelIndex = modelIndex;
modes = sortrows(modes,{'Drone','Med','Water','Food','Hygiene'});
modes.ModeID = (1:height(modes)).';
modes = movevars(modes,'ModeID','Before',1);
end

function dpModes = pruneEquivalentModes(modes,tolerance)
loadMatrix = modes{:,{'Med','Water','Food','Hygiene'}};
[uniqueLoads,~,group] = unique(loadMatrix,'rows','stable'); %#ok<ASGLU>
keep = false(height(modes),1);

for gg = 1:max(group)
    idx = find(group == gg);
    objectives = [ones(numel(idx),1),modes.Energy_kWh(idx),modes.OperationTime_s(idx)];
    localKeep = problem1.paretoKeepIndices(objectives,tolerance);
    keep(idx(localKeep)) = true;
end

dpModes = modes(keep,:);
dpModes.ModeID = (1:height(dpModes)).';
end

function [front,selectedChoices] = combineServiceFronts(services,tolerance)
objectives = [0,0,0];
choices = zeros(1,0);

for ii = 1:numel(services)
    local = services(ii).Front;
    nCandidate = size(objectives,1)*height(local);
    nextObjectives = zeros(nCandidate,3);
    nextChoices = zeros(nCandidate,ii);
    pos = 0;

    for aa = 1:size(objectives,1)
        for bb = 1:height(local)
            pos = pos + 1;
            nextObjectives(pos,:) = objectives(aa,:) + ...
                [local.N(bb),local.E_kWh(bb),local.T_s(bb)];
            if ii > 1
                nextChoices(pos,1:ii-1) = choices(aa,:);
            end
            nextChoices(pos,ii) = bb;
        end
    end

    keep = problem1.paretoKeepIndices(nextObjectives,tolerance);
    objectives = nextObjectives(keep,:);
    choices = nextChoices(keep,:);
end

[objectives,order] = sortrows(objectives,[1,2,3]);
choices = choices(order,:);
solutionID = (1:size(objectives,1)).';
isSelected = false(size(solutionID));
isSelected(1) = true;
choiceCell = mat2cell(choices,ones(size(choices,1),1),size(choices,2));
front = table(solutionID,objectives(:,1),objectives(:,2),objectives(:,3), ...
    isSelected,choiceCell, ...
    'VariableNames',{'SolutionID','N','E_kWh','T_s','IsSelected','LocalChoices'});
selectedChoices = choices(1,:);
end

function trips = reconstructTrips(services,selectedChoices,data,flightBase,reserveRatio)
tripID = strings(0,1);
serviceID = strings(0,1);
modelID = strings(0,1);
boxIDs = strings(0,1);
mass = zeros(0,1);
volume = zeros(0,1);
flightTime = zeros(0,1);
operationTime = zeros(0,1);
energy = zeros(0,1);
soc = zeros(0,1);
med = zeros(0,1);
water = zeros(0,1);
food = zeros(0,1);
hygiene = zeros(0,1);
maxSafe = zeros(0,1);
maxVolume = zeros(0,1);
energyBudget = zeros(0,1);

used = false(height(data.Boxes),1);
row = 0;
for ii = 1:numel(services)
    sid = services(ii).ServiceID;
    frontRow = selectedChoices(ii);
    plan = services(ii).Front.ModeIndices{frontRow};
    for pp = 1:numel(plan)
        mode = services(ii).Modes(plan(pp),:);
        row = row+1;
        tripID(row,1) = sprintf('Q1-%s-%03d',sid,pp);
        serviceID(row,1) = sid;
        modelID(row,1) = string(mode.Drone);
        counts = mode{1,{'Med','Water','Food','Hygiene'}};
        selectedBoxes = strings(0,1);
        for jj = 1:4
            candidates = find(~used & data.Boxes.ServiceID == sid & ...
                data.Boxes.TypeIndex == jj);
            if numel(candidates) < counts(jj)
                error('服务区 %s 的第 %d 类货箱不足。',sid,jj);
            end
            take = candidates(1:counts(jj));
            used(take) = true;
            selectedBoxes = [selectedBoxes; data.Boxes.BoxID(take)]; %#ok<AGROW>
        end
        boxIDs(row,1) = strjoin(selectedBoxes,',');
        mass(row,1) = mode.TotalMass_kg;
        volume(row,1) = mode.TotalVolume_m3;
        flightTime(row,1) = mode.RoundTripTime_s;
        operationTime(row,1) = mode.OperationTime_s;
        energy(row,1) = mode.Energy_kWh;
        soc(row,1) = mode.ReturnSOC_pct;
        med(row,1) = counts(1);
        water(row,1) = counts(2);
        food(row,1) = counts(3);
        hygiene(row,1) = counts(4);
        maxSafe(row,1) = mode.MaxSafePayload_kg;
        maxVolume(row,1) = mode.MaxVolume_m3;
        energyBudget(row,1) = mode.EnergyBudget_kWh;
    end
end

if ~all(used)
    error('方案重构后仍有 %d 个货箱未分配。',nnz(~used));
end

trips = table(tripID,serviceID,modelID,boxIDs,mass,volume, ...
    flightTime,operationTime,energy,soc,med,water,food,hygiene, ...
    maxSafe,maxVolume,energyBudget, ...
    'VariableNames',{'TripID','ServiceID','ModelID','BoxIDs', ...
    'TotalMass_kg','TotalVolume_m3','RoundTripTime_s','OperationTime_s', ...
    'Energy_kWh','ReturnSOC_pct','Med','Water','Food','Hygiene', ...
    'MaxSafePayload_kg','MaxVolume_m3','EnergyBudget_kWh'});

% 触发一次结构校验，防止 flightBase 与模式机型不一致。
assert(all(ismember(trips.ModelID,flightBase.uav.ID)));
assert(reserveRatio >= 0 && reserveRatio < 1);
end

function validation = validateScenario(services,globalFront,trips,data,flightBase,reserveRatio,tolerance)
validation = table(strings(0,1),false(0,1),strings(0,1), ...
    'VariableNames',{'Check','Passed','Details'});
validation = [validation; makeCheck("输入包含15个服务区",numel(data.ServiceIDs)==15, ...
    sprintf('实际 %d 个',numel(data.ServiceIDs)))];
validation = [validation; makeCheck("输入包含80个货箱",height(data.Boxes)==80, ...
    sprintf('实际 %d 个',height(data.Boxes)))];

assigned = strings(0,1);
for r = 1:height(trips)
    if trips.BoxIDs(r) ~= ""
        assigned = [assigned; split(trips.BoxIDs(r),',')]; %#ok<AGROW>
    end
end
allOnce = numel(assigned)==height(data.Boxes) && ...
    numel(unique(assigned))==height(data.Boxes) && ...
    all(ismember(data.Boxes.BoxID,assigned));
validation = [validation; makeCheck("全部货箱均且仅安排一次",allOnce, ...
    sprintf('方案含 %d 个货箱编号',numel(assigned)))];

delivered = zeros(numel(data.ServiceIDs),4);
for ii = 1:numel(data.ServiceIDs)
    mask = trips.ServiceID == data.ServiceIDs(ii);
    delivered(ii,:) = sum(trips{mask,{'Med','Water','Food','Hygiene'}},1);
end
validation = [validation; makeCheck("各服务区四类需求完全满足", ...
    isequal(delivered,data.Demand),"逐服务区逐物资核对")];

tripFeasible = all(trips.TotalMass_kg <= trips.MaxSafePayload_kg+1e-6) && ...
    all(trips.TotalVolume_m3 <= trips.MaxVolume_m3+1e-12) && ...
    all(trips.Energy_kWh <= trips.EnergyBudget_kWh+tolerance(2)) && ...
    all(trips.ReturnSOC_pct+1e-8 >= 100*reserveRatio);
validation = [validation; makeCheck("每架次满足质量、体积和能量约束", ...
    tripFeasible,sprintf('共 %d 个架次',height(trips)))];

frontObjectives = globalFront{:,{'N','E_kWh','T_s'}};
keep = problem1.paretoKeepIndices(frontObjectives,tolerance);
validation = [validation; makeCheck("全局前沿不存在被支配或重复点", ...
    numel(keep)==height(globalFront),sprintf('前沿含 %d 个点',height(globalFront)))];

selected = globalFront(1,:);
objectiveOK = height(trips)==selected.N && ...
    abs(sum(trips.Energy_kWh)-selected.E_kWh)<=1e-8 && ...
    abs(sum(trips.OperationTime_s)-selected.T_s)<=1e-5;
validation = [validation; makeCheck("重构方案与全局目标值一致",objectiveOK, ...
    sprintf('N=%d, E=%.9f kWh, T=%.6f s', ...
    height(trips),sum(trips.Energy_kWh),sum(trips.OperationTime_s)))];

stateCount = sum([services.StateCount]);
validation = [validation; makeCheck("动态规划状态规模符合输入需求",stateCount==644, ...
    sprintf('逐服务区状态数合计 %d',stateCount))];

modelOK = all(ismember(trips.ModelID,flightBase.uav.ID));
validation = [validation; makeCheck("所有架次机型编号有效",modelOK, ...
    "机型来自 flightBase.uav")];
end

function row = makeCheck(name,passed,details)
row = table(string(name),logical(passed),string(details), ...
    'VariableNames',{'Check','Passed','Details'});
end

function sensitivity = buildSensitivityTable(scenarios)
n = numel(scenarios);
reserveRatio = zeros(n,1);
N = zeros(n,1);
E = zeros(n,1);
T = zeros(n,1);
frontCount = zeros(n,1);
tripCount = zeros(n,1);
for k = 1:n
    reserveRatio(k) = scenarios(k).ReserveRatio;
    N(k) = scenarios(k).GlobalFront.N(1);
    E(k) = scenarios(k).GlobalFront.E_kWh(1);
    T(k) = scenarios(k).GlobalFront.T_s(1);
    frontCount(k) = height(scenarios(k).GlobalFront);
    tripCount(k) = height(scenarios(k).SelectedTrips);
end
sensitivity = table(reserveRatio,N,E,T,tripCount,frontCount, ...
    'VariableNames',{'ReserveRatio','N','E_kWh','T_s','TripCount','GlobalParetoCount'});
sensitivity = sortrows(sensitivity,'ReserveRatio');
end

function tf = checkPayloadMonotonicity(allPayload)
keys = unique(allPayload(:,{'ServiceID','Model'}),'rows');
tf = true;
for k = 1:height(keys)
    mask = allPayload.ServiceID == keys.ServiceID(k) & ...
        allPayload.Model == keys.Model(k);
    part = sortrows(allPayload(mask,:),'ReserveRatio');
    q = part.MaxSafePayload_kg;
    q(isnan(q)) = -inf;
    if any(diff(q) > 1e-6)
        tf = false;
        return;
    end
end
end

function files = exportResults(result)
config = result.Config;
if ~isfolder(config.OutputDir)
    mkdir(config.OutputDir);
end

submissionFile = fullfile(config.OutputDir,'问题一_结果提交.xlsx');
analysisFile = fullfile(config.OutputDir,'问题一_DP_Pareto分析.xlsx');

if ~isfile(config.TemplateFile)
    error('未找到结果提交模板：%s。',config.TemplateFile);
end
copyfile(config.TemplateFile,submissionFile,'f');

trips = result.Baseline.SelectedTrips;
official = table(trips.TripID,trips.ServiceID,trips.ModelID,trips.BoxIDs, ...
    trips.TotalMass_kg,trips.TotalVolume_m3,trips.RoundTripTime_s, ...
    trips.Energy_kWh,trips.ReturnSOC_pct, ...
    'VariableNames',{'架次编号','服务区编号','机型编号','货箱编号列表', ...
    '总质量_kg','总体积_m3','往返时间_s','架次能耗_kWh','返航SOC_pct'});
writetable(official,submissionFile,'Sheet','Q1_单点组批','Range','A2', ...
    'WriteVariableNames',false);

if isfile(analysisFile)
    delete(analysisFile);
end

selected = result.GlobalFront(1,:);
summary = {
    '问题一动态规划与Pareto前沿结果','';
    '基准返航安全余量',result.Config.BaselineRatio;
    '主方案架次数',selected.N;
    '主方案总能耗（kWh）',selected.E_kWh;
    '主方案累计作业时间（s）',selected.T_s;
    '全局Pareto方案数',height(result.GlobalFront)
    };
writecell(summary,analysisFile,'Sheet','主方案','Range','A1');
writetable(trips,analysisFile,'Sheet','主方案','Range','A8');
writetable(result.GlobalFront(:,{'SolutionID','N','E_kWh','T_s','IsSelected'}), ...
    analysisFile,'Sheet','全局Pareto','Range','A1');

serviceFront = collectServiceFronts(result.Baseline.Services);
writetable(serviceFront,analysisFile,'Sheet','服务区Pareto','Range','A1');
writetable(result.MaxSafePayload,analysisFile,'Sheet','最大安全载荷','Range','A1');
writetable(result.Sensitivity,analysisFile,'Sheet','敏感性','Range','A1');
writetable(result.Baseline.ModeSummary,analysisFile,'Sheet','模式统计','Range','A1');
writetable(result.Validation,analysisFile,'Sheet','校核','Range','A1');

files = struct('Submission',string(submissionFile),'Analysis',string(analysisFile));
end

function T = collectServiceFronts(services)
parts = cell(numel(services),1);
for ii = 1:numel(services)
    f = services(ii).Front(:,{'SolutionID','N','E_kWh','T_s'});
    f.ServiceID = repmat(services(ii).ServiceID,height(f),1);
    f = movevars(f,'ServiceID','Before',1);
    parts{ii} = f;
end
T = vertcat(parts{:});
end
