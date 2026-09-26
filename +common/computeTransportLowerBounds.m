function bounds = computeTransportLowerBounds(config)
%COMPUTETRANSPORTLOWERBOUNDS 计算问题二/三可共用的严格运输松弛下界。
%
% 这些界只删除约束，不增加约束：忽略实体机、电池、充电、硬时限及通信资源。
% 能耗界由互不重叠的两部分组成：空载航路连通成本和水平载荷增量成本。
% 完成时间界为无限资源下逐箱最短任务关键路径。架次界使用容量与不相容团。
%
% v2 增强（可证强化，仍只松弛不收紧）：
%   1) 能量限最大载荷：把“机型到服务区往返”的能量预算约束纳入容量分母，
%      远服务区 C 型有效载荷由 80 kg 降为 ~59--69 kg，提升完成时间与架次界。
%   2) 逐服务区最少访问次数：基础交接按 ceil(质量/最大有效载荷) 计次，
%      而不是每次服务区只计一次。
%   3) 对偶界改用细网格精确求解（R||Cmax LP 松弛），不再依赖粗网格。

if nargin < 1, config = struct(); end
p = common.projectPaths();
config = defaults(config,struct( ...
    'FlightBaseFile',p.FlightBaseFile, ...
    'DemandFile',p.DemandFile, ...
    'TransportUavFile',p.TransportUavFile));

assert(isfile(config.FlightBaseFile),'缺少飞行基础缓存：%s',config.FlightBaseFile);
assert(isfile(config.DemandFile),'缺少逐箱需求文件：%s',config.DemandFile);
base = load(config.FlightBaseFile);
required = {'nodes','uav','D','Hup','Hdown'};
for k = 1:numel(required)
    assert(isfield(base,required{k}),'flightBase 缺少字段 %s。',required{k});
end
boxes = loadBoxes(config.DemandFile);
models = base.uav(ismember(base.uav.ID,["A";"B";"C"]),:);
assert(height(models)==3,'flightBase 必须包含 A/B/C 三类运输机型。');

serviceIDs = unique(boxes.ServiceID,'stable');
requiredNodes = ["O01";serviceIDs(:)];
assert(all(ismember(requiredNodes,base.nodes.ID)),'逐箱清单包含 flightBase 中不存在的节点。');

% 实体无人机数量
rawUav = readcell(config.TransportUavFile,'Sheet','数据');
droneRows = startsWith(string(rawUav(:,1)),"U");
droneModels = string(rawUav(droneRows,2));
counts = zeros(1,height(models));
for g = 1:height(models), counts(g) = nnz(droneModels==models.ID(g)); end
assert(all(counts>0),'A/B/C 实体运输无人机数量必须为正。');

% 能量限最大载荷 effPayload(g, s)：往返 O01->s->O01 满足能量预算的最大载荷
effPayload = effectivePayloadMatrix(base,models);

% 逐服务区最少访问次数（按最大有效载荷与最大体积）
o = find(base.nodes.ID=="O01",1);
serviceVisits = zeros(numel(serviceIDs),1);
for k = 1:numel(serviceIDs)
    use = boxes.ServiceID==serviceIDs(k);
    ms = sum(boxes.Mass_kg(use)); vs = sum(boxes.Volume_m3(use));
    s = find(base.nodes.ID==serviceIDs(k),1);
    bestCap = max(effPayload(:,s));
    bestVol = max(models.MaxVolume);
    serviceVisits(k) = max(ceil(ms/bestCap-1e-9), ceil(vs/bestVol-1e-12));
end

% 1) 空载部分：任一可行航路并集都连接 O01 和全部需求点；其空载能耗
% 不小于按“机型、方向均可自由选择”进一步松弛后的无向最小生成树。
n = numel(requiredNodes);
W = inf(n);
for i = 1:n
    W(i,i) = 0;
    for j = i+1:n
        best = inf;
        for g = 1:height(models)
            a = common.calcLegCost(requiredNodes(i),requiredNodes(j),models.ID(g),0,base);
            b = common.calcLegCost(requiredNodes(j),requiredNodes(i),models.ID(g),0,base);
            best = min([best,a.E_total,b.E_total]);
        end
        W(i,j)=best; W(j,i)=best;
    end
end
[mstEnergy,mstEdges] = primMST(W,requiredNodes);

% 1b) 空载部分的第二个下界：架次是经过 O01 的闭合回路，且架次数至少
% 为质量容量界（>=10）。每个架次的空载能耗不小于“最短往返空载能耗”，
% 因此空载能耗 >= 最少架次数 x 最短往返空载能耗。与 MST 取较大者。
minRoundTripEmpty = inf;
for k = 1:numel(serviceIDs)
    s = find(base.nodes.ID==serviceIDs(k),1);
    for g = 1:height(models)
        a = common.calcLegCost(base.nodes.ID(o),base.nodes.ID(s),models.ID(g),0,base).E_total;
        b = common.calcLegCost(base.nodes.ID(s),base.nodes.ID(o),models.ID(g),0,base).E_total;
        minRoundTripEmpty = min(minRoundTripEmpty, a+b);
    end
end
massTripsEmpty = ceil(sum(boxes.Mass_kg)/max(models.MaxPayload)-1e-12);
roundTripEmpty = massTripsEmpty*minRoundTripEmpty;
emptyEnergyLB = max(mstEnergy, roundTripEmpty);

% 2) 载荷部分：水平能耗增量关于载荷非负、凸且超可加。把同一航段的
% 增量逐箱分摊，再用三角不等式把实际折线路径松弛为 O01 到服务区直线。
% 爬升载荷增量全部舍去，因此不会与 MST 的空载能耗重复计数。
assertPayloadSuperadditivity(models);
payloadLB = zeros(height(boxes),1);
criticalTimeLB = zeros(height(boxes),1);
bestEnergyModel = strings(height(boxes),1);
bestTimeModel = strings(height(boxes),1);
timeMatrices = shortestTimeMatrices(base,models);
for b = 1:height(boxes)
    s = find(base.nodes.ID==boxes.ServiceID(b),1);
    eBest = inf; tBest = inf;
    for g = 1:height(models)
        if boxes.Mass_kg(b)>models.MaxPayload(g)+1e-9 || ...
                boxes.Volume_m3(b)>models.MaxVolume(g)+1e-12
            continue;
        end
        q = boxes.Mass_kg(b);
        leq = models.RangeEmpty(g) - ...
            (models.RangeEmpty(g)-models.RangeFull(g))*(q/models.MaxPayload(g))^(3/2);
        increment = models.BatteryUse(g)*base.D(o,s)* ...
            (1/leq-1/models.RangeEmpty(g));
        if increment < eBest
            eBest=increment; bestEnergyModel(b)=models.ID(g);
        end
        mission = models.PrepTime(g)+models.LoadTimeBox(g)+ ...
            timeMatrices(o,s,g)+models.HandoverBase(g)+models.HandoverBox(g)+ ...
            timeMatrices(s,o,g);
        if mission < tBest
            tBest=mission; bestTimeModel(b)=models.ID(g);
        end
    end
    assert(isfinite(eBest) && isfinite(tBest),'货箱 %s 无任何容量可行机型。',boxes.BoxID(b));
    payloadLB(b)=max(0,eBest); criticalTimeLB(b)=tBest;
end

% 3) 架次：删除路线、能量和机型库存，只保留最大机型的二维容量。
% 能量限载荷对“全局质量容量界”不收紧（近服务区仍可满载 80 kg），
% 但逐服务区访问次数用它收紧。
maxMass = max(models.MaxPayload);
maxVolume = max(models.MaxVolume);
massLB = ceil(sum(boxes.Mass_kg)/maxMass-1e-12);
volumeLB = ceil(sum(boxes.Volume_m3)/maxVolume-1e-12);
incompatible = false(height(boxes));
for i = 1:height(boxes)
    for j = i+1:height(boxes)
        incompatible(i,j) = boxes.Mass_kg(i)+boxes.Mass_kg(j)>maxMass+1e-9 || ...
            boxes.Volume_m3(i)+boxes.Volume_m3(j)>maxVolume+1e-12;
        incompatible(j,i) = incompatible(i,j);
    end
end
[cliqueLB,cliqueIdx] = greedyCliqueLowerBound(incompatible);
serviceLB = max(serviceVisits);
tripLB = max([massLB,volumeLB,cliqueLB,serviceLB]);

energyLB = emptyEnergyLB+sum(payloadLB);
[workloadLB,workloadAudit] = fleetWorkloadLowerBound( ...
    boxes,models,base,timeMatrices,effPayload,serviceVisits,counts);
makespanLB = max(max(criticalTimeLB),workloadLB);
boxAudit = table(boxes.BoxID,boxes.ServiceID,boxes.Mass_kg,boxes.Volume_m3, ...
    payloadLB,bestEnergyModel,criticalTimeLB,bestTimeModel, ...
    'VariableNames',{'BoxID','ServiceID','Mass_kg','Volume_m3', ...
    'PayloadEnergyLB_kWh','EnergyModel','CriticalPathLB_s','TimeModel'});
components = table( ...
    ["空载航路 MST 能耗";"最少架次×最短往返空载能耗";"空载能耗下界"; ...
     "逐箱水平载荷增量";"运输总能耗"; ...
     "无限资源逐箱关键路径";"受限机队工作量对偶界";"完成时间"; ...
     "总质量容量";"总体积容量"; ...
     "二维不相容团";"逐服务区容量（取最大）";"运输架次"], ...
    [mstEnergy;roundTripEmpty;emptyEnergyLB;sum(payloadLB);energyLB; ...
     max(criticalTimeLB);workloadLB;makespanLB;massLB;volumeLB; ...
     cliqueLB;serviceLB;tripLB], ...
    ["kWh";"kWh";"kWh";"kWh";"kWh";"s";"s";"s";"趟";"趟";"趟";"趟";"趟"], ...
    'VariableNames',{'Component','LowerBound','Unit'});

bounds = struct('Energy_kWh',energyLB,'Makespan_s',makespanLB, ...
    'TransportTripCount',tripLB,'Timeliness',0,'RelayTripCount',0, ...
    'Components',components,'BoxAudit',boxAudit,'MSTEdges',mstEdges, ...
    'WorkloadAudit',workloadAudit, ...
    'IncompatibleCliqueBoxes',boxes.BoxID(cliqueIdx), ...
    'Config',config);
end

function boxes = loadBoxes(file)
raw=readcell(file,'Sheet','逐箱货箱清单');
ids=string(raw(:,1));
mask=startsWith(ids,'S') & contains(ids,'-') & ~ismissing(ids);
r=raw(mask,:);
boxes=table(string(r(:,1)),string(r(:,2)),cell2mat(r(:,4)),cell2mat(r(:,5)), ...
    'VariableNames',{'BoxID','ServiceID','Mass_kg','Volume_m3'});
assert(height(boxes)==80 && numel(unique(boxes.BoxID))==80,'逐箱清单必须恰有 80 个唯一货箱。');
end

function effP = effectivePayloadMatrix(base,models)
% 能量限最大载荷：往返 O01->s->O01 满足 (1-rho)*Euse 预算的最大载荷。
n = height(base.nodes); o = find(base.nodes.ID=="O01",1);
effP = zeros(height(models),n);
for g = 1:height(models)
    m = models(g,:);
    budget = (1-m.ReservePct/100)*m.BatteryUse;
    for s = 1:n
        if s==o, effP(g,s)=0; continue; end
        lo = 0; hi = m.MaxPayload;
        for it = 1:60
            mid = (lo+hi)/2;
            e1 = common.calcLegCost(base.nodes.ID(o),base.nodes.ID(s),m.ID,mid,base).E_total;
            e2 = common.calcLegCost(base.nodes.ID(s),base.nodes.ID(o),m.ID,0,base).E_total;
            if e1+e2 <= budget, lo=mid; else, hi=mid; end
        end
        effP(g,s) = lo;
    end
end
end

function matrices = shortestTimeMatrices(base,models)
n=height(base.nodes); matrices=zeros(n,n,height(models));
for g=1:height(models)
    D=inf(n); D(1:n+1:end)=0;
    for i=1:n
        for j=1:n
            if i~=j
                x=common.calcLegCost(base.nodes.ID(i),base.nodes.ID(j),models.ID(g),0,base);
                D(i,j)=x.T_total;
            end
        end
    end
    for k=1:n
        D=min(D,D(:,k)+D(k,:));
    end
    matrices(:,:,g)=D;
end
end

function [lowerBound,audit] = fleetWorkloadLowerBound(boxes,models,base,shortestTime,effP,serviceVisits,counts)
% 受限机队工作量松弛（R||Cmax LP 对偶）。对任一 alpha∈[0,1]，
% alpha*m/Q+(1-alpha)*v/V 在每架次上的总和不超过 1；其中质量容量分母
% 采用能量限有效载荷，基础交接按逐服务区最少访问次数计次。
% 因而可把准备及径向往返时间按该容量份额分摊给货箱。再对三类机型
% 的工作量平衡 LP 构造显式对偶可行解，网格未取到最优只会让界更弱。
o=find(base.nodes.ID=="O01",1);
% 每个货箱对应的服务区访问次数（serviceVisits 与 unique 顺序一致）
svcIDs = unique(boxes.ServiceID,'stable');
boxVisits = zeros(height(boxes),1);
for b = 1:height(boxes)
    boxVisits(b) = serviceVisits(boxes.ServiceID(b)==svcIDs);
end
alphas=0:0.05:1;
bestValue=0; bestAlpha=0; bestZ=zeros(1,height(models));
for alpha=alphas
    C=workloadCoefficients(alpha);
    [value,z]=dualGrid(C,counts,400);
    if value>bestValue, bestValue=value; bestAlpha=alpha; bestZ=z; end
end
refineAlphas=max(0,bestAlpha-0.05):0.01:min(1,bestAlpha+0.05);
for alpha=refineAlphas
    C=workloadCoefficients(alpha);
    [value,z]=dualGrid(C,counts,800);
    if value>bestValue, bestValue=value; bestAlpha=alpha; bestZ=z; end
end
lowerBound=bestValue;
audit=table(bestAlpha,bestValue,bestValue/60,bestZ(1),bestZ(2),bestZ(3), ...
    counts(1),counts(2),counts(3), ...
    'VariableNames',{'MassWeightAlpha','LowerBound_s','LowerBound_min', ...
    'DualShare_A','DualShare_B','DualShare_C','DroneCount_A','DroneCount_B','DroneCount_C'});

    function C=workloadCoefficients(alpha)
        C=zeros(height(boxes),height(models));
        for b=1:height(boxes)
            s=find(base.nodes.ID==boxes.ServiceID(b),1);
            same=boxes.ServiceID==boxes.ServiceID(b);
            coverageShare=(alpha*boxes.Mass_kg(b)/sum(boxes.Mass_kg(same))+ ...
                (1-alpha)*boxes.Volume_m3(b)/sum(boxes.Volume_m3(same)));
            for g=1:height(models)
                % 质量容量分母用能量限有效载荷；体积仍用标称容积
                capacityShare=alpha*boxes.Mass_kg(b)/effP(g,s)+ ...
                    (1-alpha)*boxes.Volume_m3(b)/models.MaxVolume(g);
                C(b,g)=models.LoadTimeBox(g)+models.HandoverBox(g)+ ...
                    models.HandoverBase(g)*coverageShare*boxVisits(b) + ...
                    (models.PrepTime(g)+shortestTime(o,s,g)+shortestTime(s,o,g))*capacityShare;
            end
        end
    end
end

function [value,bestZ] = dualGrid(C,counts,N)
% 原 LP：把每箱可分数指派给机型，最小化各机型工作量/实体机数的最大值。
% 对偶：max sum_b min_g(z_g*C_bg/n_g), z>=0, sum(z)=1。
P=C./counts; value=0; bestZ=zeros(1,3);
nb=size(C,1);
z1=linspace(0,1,N);
for i=0:N
    a=i/N;
    m2=N-i+1;
    z2=linspace(0,1-a,m2).';
    z3=1-a-z2;
    Z=[repmat(a,m2,1),z2,z3];
    W=reshape(Z,m2,1,3).*reshape(P,1,nb,3);
    Wmin=min(W,[],3);
    f=sum(Wmin,2);
    [fv,loc]=max(f);
    if fv>value, value=fv; bestZ=Z(loc,:); end
end
end

function assertPayloadSuperadditivity(models)
for g=1:height(models)
    q=(0:floor(models.MaxPayload(g))).';
    leq=models.RangeEmpty(g)-(models.RangeEmpty(g)-models.RangeFull(g))* ...
        (q/models.MaxPayload(g)).^(3/2);
    f=1./leq-1/models.RangeEmpty(g);
    for a=0:numel(q)-1
        for b=0:numel(q)-1-a
            assert(f(a+b+1)+1e-14>=f(a+1)+f(b+1), ...
                '机型 %s 的水平载荷增量不满足超可加性，不能使用逐箱分解。',models.ID(g));
        end
    end
end
end

function [total,edges] = primMST(W,ids)
n=size(W,1); used=false(n,1); used(1)=true; total=0;
from=zeros(n-1,1); to=zeros(n-1,1); cost=zeros(n-1,1);
for k=1:n-1
    best=inf; a=0; b=0;
    for i=find(used).'
        candidates=find(~used).';
        [v,pos]=min(W(i,candidates));
        if v<best, best=v; a=i; b=candidates(pos); end
    end
    assert(isfinite(best),'需求节点图不连通，无法计算 MST。');
    used(b)=true; total=total+best; from(k)=a; to(k)=b; cost(k)=best;
end
edges=table(ids(from),ids(to),cost,'VariableNames',{'NodeA','NodeB','EmptyEnergyLB_kWh'});
end

function [best,indices] = greedyCliqueLowerBound(A)
n=size(A,1); best=0; indices=zeros(0,1);
orders=cell(n+2,1);
[~,orders{1}]=sort(sum(A,2),'descend');
[~,orders{2}]=sort(sum(A,2),'ascend');
for s=1:n, orders{s+2}=[s,setdiff(1:n,s,'stable')]; end
for p=1:numel(orders)
    clique=zeros(0,1);
    for v=orders{p}(:).'
        if isempty(clique) || all(A(v,clique)), clique(end+1,1)=v; end %#ok<AGROW>
    end
    if numel(clique)>best, best=numel(clique); indices=clique; end
end
end

function out = defaults(in,d)
out=in; names=fieldnames(d);
for k=1:numel(names)
    if ~isfield(out,names{k}) || isempty(out.(names{k})), out.(names{k})=d.(names{k}); end
end
end
