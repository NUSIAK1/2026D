function result = solveProblem4(config)
%SOLVEPROBLEM4 固定问题三主方案，精确枚举分区及独立最少资源。
if nargin<1, config=struct(); end
p=common.projectPaths();
config=defaults(config,p);
input=problem4.loadInput(config);
blocks=problem4.taskBlocks(input.Rep);
assert(numel(blocks)>=3,'不足三个不可拆任务块，无法划为三组。');
[types,inventory,physical]=resourceCatalog(input.Data);
allBlocks=1:numel(blocks);
baseline=evaluate("K1_BASE",{allBlocks},blocks,input.Rep,input.Data,types,inventory);
candidate=struct([]);
for K=[2,3]
    parts=enumeratePartitions(numel(blocks),K);
    assert(~isempty(parts),'未找到 %d 组分区。',K);
    for j=1:numel(parts)
        label=sprintf('K%d_%02d',K,j);
        item=evaluate(string(label),parts{j},blocks,input.Rep,input.Data,types,inventory);
        item.K=K;
        item.Allocation=mapPhysical(item.Allocation,item.Resource,types,physical,inventory);
        if isempty(candidate), candidate=item; else, candidate(end+1)=item; end %#ok<AGROW>
    end
end
summary=table(); resources=table(); groups=table(); assignments=table();
for k=1:numel(candidate)
    item=candidate(k);
    totals=zeros(1,numel(types));
    for j=1:numel(types)
        totals(j)=sum(item.Resource.Required(item.Resource.Type==types(j)));
    end
    deficit=max(totals-inventory,0);
    score=[sum(deficit./inventory),sum(totals./inventory),item.WorkCV];
    item.Totals=totals; item.Deficit=deficit; item.Score=score;
    item.Extra=totals-baseline.Totals;
    assert(all(item.Extra>=0),'分组后资源需求低于不分组需求。');
    candidate(k)=item;
    row=table(item.ID,item.K,string(item.Signature),score(1),score(2), ...
        score(3),sum(deficit),sum(item.Extra),false,false, ...
        'VariableNames',{'PartitionID','K','Groups','DeficitScore', ...
        'ScaleScore','WorkCV','ShortfallTotal','ExtraTotal', ...
        'IsPareto','IsSelected'});
    summary=[summary;row]; %#ok<AGROW>
    resources=[resources;item.Resource]; %#ok<AGROW>
    groups=[groups;item.Group]; %#ok<AGROW>
    assignments=[assignments;item.Allocation]; %#ok<AGROW>
end
chosen=zeros(1,2);
for kk=1:2
    K=kk+1; indices=find(summary.K==K);
    obj=summary{indices,{'DeficitScore','ScaleScore','WorkCV'}};
    for a=1:numel(indices)
        dominated=false;
        for b=1:numel(indices)
            if b~=a && all(obj(b,:)<=obj(a,:)+1e-12) && ...
                    any(obj(b,:)<obj(a,:)-1e-12)
                dominated=true; break;
            end
        end
        summary.IsPareto(indices(a))=~dominated;
    end
    [~,order]=sortrows([obj,(1:numel(indices))']);
    chosen(kk)=indices(order(1));
    summary.IsSelected(chosen(kk))=true;
end
baselineTable=table(types',baseline.Totals',inventory', ...
    'VariableNames',{'Type','NoPartitionRequired','Inventory'});
result=struct('Config',config,'SourceFile',input.ArchiveFile, ...
    'Blocks',{blocks},'Candidates',candidate,'Summary',summary, ...
    'Resources',resources,'Groups',groups,'Assignments',assignments, ...
    'Baseline',baselineTable,'Selected2',candidate(chosen(1)), ...
    'Selected3',candidate(chosen(2)),'SourceCheck',input.SourceCheck, ...
    'BaselineCheck',input.BaselineCheck,'OutputFiles',struct());
result.Validation=problem4.validateProblem4(result,input.Rep,input.Data);
assert(result.Validation.Feasible,'问题四独立校核失败：%s', ...
    strjoin(result.Validation.Checks.Check(~result.Validation.Checks.Passed),','));
if config.ExportFiles
    result.OutputFiles=problem4.exportResults(result,input);
end
end

function config=defaults(config,p)
fields={'ResultDir','TemplateFile','ArchiveFile','SubmissionFile','ExportFiles','ExportFigures'};
values={p.ResultDir,p.TemplateFile, ...
    fullfile(p.ResultDir,'问题三_Pareto完整档案.mat'), ...
    fullfile(p.ResultDir,'问题三_结果提交_折中方案.xlsx'),true,true};
for i=1:numel(fields)
    if ~isfield(config,fields{i}) || isempty(config.(fields{i}))
        config.(fields{i})=values{i};
    end
end
end

function [types,inventory,physical]=resourceCatalog(data)
types=["A_U","B_U","C_U","A_BAT","B_BAT","C_BAT","R_U","R_COMP"];
inventory=[sum(data.Drones.Model=="A"),sum(data.Drones.Model=="B"), ...
    sum(data.Drones.Model=="C"),sum(data.Batteries.Model=="A"), ...
    sum(data.Batteries.Model=="B"),sum(data.Batteries.Model=="C"), ...
    numel(data.Relay.DroneIDs),numel(data.Relay.ComponentIDs)];
assert(all(inventory>0),'原始资源库存必须为正。');
physical=cell(1,numel(types));
for j=1:3
    model=extractBefore(types(j),'_');
    physical{j}=data.Drones.DroneID(data.Drones.Model==model);
    physical{j+3}=data.Batteries.BatteryID(data.Batteries.Model==model);
end
physical{7}=data.Relay.DroneIDs;
physical{8}=data.Relay.ComponentIDs;
end

function parts=enumeratePartitions(n,K)
parts=cell(0,1);
labels=ones(1,n);
visit(2,1);
    function visit(pos,largest)
        if pos>n
            if largest~=K, return; end
            groups=cell(1,K);
            for z=1:K, groups{z}=find(labels==z); end
            parts{end+1,1}=groups; %#ok<AGROW>
            return;
        end
        for z=1:min(largest+1,K)
            labels(pos)=z;
            visit(pos+1,max(largest,z));
        end
    end
end

function item=evaluate(id,part,blocks,rep,data,types,inventory)
T=rep.Transport.Trips; R=rep.Relay.RelayTrips;
D=rep.Transport.Deliveries;
resources=table(); groupTable=table(); allocation=table();
signature=strings(1,numel(part));
for g=1:numel(part)
    selected=part{g};
    services=vertcat(blocks(selected).Services);
    tripIDs=vertcat(blocks(selected).TripIDs);
    relayIDs=vertcat(blocks(selected).RelayTripIDs);
    assert(~isempty(services) && numel(unique(services))==numel(services));
    signature(g)=strjoin(services,',');
    ti=T(ismember(T.TripID,tripIDs),:);
    ri=R(ismember(R.RelayTripID,relayIDs),:);
    di=D(ismember(D.TripID,tripIDs),:);
    assert(height(ti)==numel(tripIDs) && height(ri)==numel(relayIDs));
    workload=sum(ti.Return_s-ti.Start_s)+sum(ri.Return_s-ri.Start_s);
    mass=sum(data.Boxes.Mass_kg(ismember(data.Boxes.BoxID,di.BoxID)));
    energy=sum(ti.Energy_kWh)+sum(ri.Energy_kWh);
    groupTable=[groupTable;table(id,g,string(strjoin(services,',')), ...
        numel(services),height(ti),height(ri),height(di),mass,energy,workload, ...
        'VariableNames',{'PartitionID','GroupID','Services', ...
        'ServiceCount','TransportTrips','RelayTrips','BoxCount', ...
        'Mass_kg','Energy_kWh','Work_s'})]; %#ok<AGROW>
    for j=1:numel(types)
        typ=types(j);
        if j<=3, x=ti(ti.Model==extractBefore(typ,'_'),:);
        elseif j<=6, x=ti(ti.Model==extractBefore(typ,'_'),:);
        else, x=ri; end
        if j<=3
            tid=x.TripID; start=x.Start_s; finish=x.Return_s;
            original=x.DroneID;
        elseif j<=6
            m=find(data.Models.Model==extractBefore(typ,'_'),1);
            fullCharge=data.Batteries.FullChargeTime_s(find(data.Batteries.Model==data.Models.Model(m),1));
            tid=x.TripID; start=x.Start_s;
            finish=x.Return_s+common.chargeTime(x.ReturnSOC_pct/100,fullCharge);
            original=x.BatteryID;
            old=rep.Transport.BatteryTimeline;
            for q=1:height(x)
                ix=find(old.TripID==x.TripID(q),1);
                assert(~isempty(ix) && abs(old.Available_s(ix)-finish(q))<1e-6, ...
                    '运输电池充电时间与问题三档案不一致。');
            end
        elseif j==7
            tid=x.RelayTripID; start=x.Start_s;
            finish=x.Return_s+data.Relay.TurnTime_s;
            original=x.RelayID;
        else
            tid=x.RelayTripID; start=x.Start_s;
            finish=x.Return_s+common.chargeTime( ...
                x.ReturnSOC_pct/100,data.Relay.FullChargeTime_s);
            original=x.ComponentID;
        end
        a=problem4.allocateIntervals(tid,start,finish);
        resources=[resources;table(id,g,typ,a.Required,inventory(j), ...
            a.PeakTime_s,string(strjoin(a.WitnessTrips,',')), ...
            'VariableNames',{'PartitionID','GroupID','Type','Required', ...
            'Inventory','Peak_s','WitnessTrips'})]; %#ok<AGROW>
        n=numel(tid);
        if n>0
            rows=table(repmat(id,n,1),repmat(g,n,1),repmat(typ,n,1), ...
                string(tid),double(start),double(finish),a.Slot, ...
                string(original),strings(n,1),strings(n,1), ...
                'VariableNames',{'PartitionID','GroupID','Type','TripID', ...
                'Start_s','Available_s','Slot','OriginalResourceID', ...
                'AssignedResourceID','InventoryStatus'});
            allocation=[allocation;rows]; %#ok<AGROW>
        end
    end
end
totals=zeros(1,numel(types));
for j=1:numel(types), totals(j)=sum(resources.Required(resources.Type==types(j))); end
work=groupTable.Work_s;
if mean(work)==0, cv=0; else, cv=std(work,1)/mean(work); end
item=struct('ID',id,'K',numel(part),'Partition',{part}, ...
    'Signature',strjoin(signature,' | '),'Resource',resources, ...
    'Group',groupTable,'Allocation',allocation,'Totals',totals, ...
    'Deficit',max(totals-inventory,0),'Extra',zeros(size(totals)), ...
    'Score',zeros(1,3),'WorkCV',cv);
end

function allocations=mapPhysical(allocations,resource,types,physical,inventory)
for j=1:numel(types)
    used=0;
    rows=resource(resource.Type==types(j),:);
    for k=1:height(rows)
        needed=rows.Required(k);
        for slot=1:needed
            used=used+1;
            mask=allocations.Type==types(j) & ...
                allocations.GroupID==rows.GroupID(k) & allocations.Slot==slot;
            if used<=inventory(j)
                assigned=string(physical{j}(used)); status="现有库存";
            else
                assigned="ADD-"+types(j)+"-"+sprintf('%02d',used-inventory(j));
                status="需增配";
            end
            allocations.AssignedResourceID(mask)=assigned;
            allocations.InventoryStatus(mask)=status;
        end
    end
end
assert(all(allocations.AssignedResourceID~=""));
end
