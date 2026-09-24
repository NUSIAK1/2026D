function out = solveServiceParetoDP(demand, modes, options)
%SOLVESERVICEPARETODP 四类物资单服务区的精确 Pareto 动态规划。
%
% demand: [医疗, 饮用水, 食品, 卫生用品] 的非负整数需求。
% modes : 至少包含 Med/Water/Food/Hygiene、Energy_kWh、OperationTime_s。
% options.Tolerance: 默认 [0,1e-9,1e-6]。

if nargin < 3
    options = struct();
end
if ~isfield(options,'Tolerance') || isempty(options.Tolerance)
    options.Tolerance = [0,1e-9,1e-6];
end
options.Tolerance = double(options.Tolerance(:)).';
if numel(options.Tolerance) ~= 3
    error('Tolerance 必须包含 [N,E,T] 三个容差。');
end

demand = double(demand(:)).';
if numel(demand) ~= 4 || any(demand < 0) || ...
        any(abs(demand-round(demand)) > 1e-12)
    error('demand 必须是包含 4 个非负整数的向量。');
end

required = {'Med','Water','Food','Hygiene','Energy_kWh','OperationTime_s'};
if ~istable(modes) || ~all(ismember(required,modes.Properties.VariableNames))
    error('modes 缺少必要列：%s。',strjoin(required,', '));
end

modeLoad = double(modes{:,{'Med','Water','Food','Hygiene'}});
if any(modeLoad(:) < 0) || any(abs(modeLoad(:)-round(modeLoad(:))) > 1e-12)
    error('运输模式中的物资数量必须是非负整数。');
end
if any(sum(modeLoad,2) == 0)
    error('运输模式不能包含全零空载模式。');
end
if any(~isfinite(modes.Energy_kWh)) || any(modes.Energy_kWh < 0) || ...
        any(~isfinite(modes.OperationTime_s)) || any(modes.OperationTime_s < 0)
    error('运输模式的能耗和作业时间必须是有限非负数。');
end

dims = demand + 1;
nStates = prod(dims);
states = zeros(nStates,4);
pos = 0;
for s4 = 0:demand(4)
    for s3 = 0:demand(3)
        for s2 = 0:demand(2)
            for s1 = 0:demand(1)
                pos = pos + 1;
                states(pos,:) = [s1,s2,s3,s4];
            end
        end
    end
end

[~,order] = sortrows([sum(states,2),states],[1,2,3,4,5]);

template = struct('N',0,'E',0,'T',0, ...
    'PrevState',0,'PrevLabel',0,'ModeIndex',0);
emptyLabels = repmat(template,0,1);
labelsByState = repmat({emptyLabels},nStates,1);
labelsByState{1} = template;

for oo = 1:numel(order)
    stateIdx = order(oo);
    currentLabels = labelsByState{stateIdx};
    if isempty(currentLabels)
        continue;
    end

    state = states(stateIdx,:);
    remaining = demand-state;
    feasibleModeIdx = find(all(modeLoad <= remaining,2));

    for mm = feasibleModeIdx(:).'
        nextState = state + modeLoad(mm,:);
        nextIdx = stateToIndex(nextState,dims);

        for ll = 1:numel(currentLabels)
            candidate = template;
            candidate.N = currentLabels(ll).N + 1;
            candidate.E = currentLabels(ll).E + modes.Energy_kWh(mm);
            candidate.T = currentLabels(ll).T + modes.OperationTime_s(mm);
            candidate.PrevState = stateIdx;
            candidate.PrevLabel = ll;
            candidate.ModeIndex = mm;
            labelsByState{nextIdx} = insertLabel( ...
                labelsByState{nextIdx},candidate,options.Tolerance);
        end
    end
end

targetIdx = stateToIndex(demand,dims);
frontLabels = labelsByState{targetIdx};
if isempty(frontLabels)
    error('给定需求没有可行的完整交付方案。');
end

nFront = numel(frontLabels);
solutionID = (1:nFront).';
N = reshape([frontLabels.N],[],1);
E = reshape([frontLabels.E],[],1);
T = reshape([frontLabels.T],[],1);
modePlans = cell(nFront,1);

for ff = 1:nFront
    modePlans{ff} = reconstructPlan(labelsByState,targetIdx,ff);
end

front = table(solutionID,N,E,T,modePlans, ...
    'VariableNames',{'SolutionID','N','E_kWh','T_s','ModeIndices'});
front = sortrows(front,{'N','E_kWh','T_s'},{'ascend','ascend','ascend'});

out = struct();
out.Demand = demand;
out.StateCount = nStates;
out.Front = front;
out.LabelsByState = labelsByState;
out.States = states;
end

function idx = stateToIndex(state,dims)
idx = 1 + state(1) + dims(1)*(state(2) + ...
    dims(2)*(state(3) + dims(3)*state(4)));
end

function labels = insertLabel(labels,candidate,tol)
candidateObj = objectiveVector(candidate);
remove = false(numel(labels),1);

for k = 1:numel(labels)
    existingObj = objectiveVector(labels(k));
    if all(abs(existingObj-candidateObj) <= tol)
        return;
    end
    if dominates(existingObj,candidateObj,tol)
        return;
    end
    if dominates(candidateObj,existingObj,tol)
        remove(k) = true;
    end
end
labels = labels(~remove);
labels = labels(:);
if isempty(labels)
    labels = candidate;
else
    labels(end+1,1) = candidate;
end
end

function obj = objectiveVector(label)
if ~isscalar(label.N) || ~isscalar(label.E) || ~isscalar(label.T)
    error('Pareto 标签目标必须为标量，当前尺寸 N=%s, E=%s, T=%s。', ...
        mat2str(size(label.N)),mat2str(size(label.E)),mat2str(size(label.T)));
end
obj = zeros(1,3);
obj(1) = double(label.N);
obj(2) = double(label.E);
obj(3) = double(label.T);
end

function tf = dominates(a,b,tol)
tf = all(a <= b + tol) && any(a < b - tol);
end

function plan = reconstructPlan(labelsByState,stateIdx,labelIdx)
plan = zeros(0,1);
while true
    label = labelsByState{stateIdx}(labelIdx);
    if label.ModeIndex == 0
        break;
    end
    plan(end+1,1) = label.ModeIndex; %#ok<AGROW>
    stateIdx = label.PrevState;
    labelIdx = label.PrevLabel;
end
plan = flipud(plan);
end
