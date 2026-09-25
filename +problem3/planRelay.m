function out = planRelay(transport,data,config)
%PLANRELAY 对点态直连缺口构造有实体机及能源组件的中继架次。
if ~isfield(config,'GapSampleStep_s'), config.GapSampleStep_s=30; end
if ~isfield(config,'RelayWindow_s'), config.RelayWindow_s=1800; end
usePre=isfield(config,'RelayPrecompute') && ~isempty(config.RelayPrecompute);
if usePre
    pre=config.RelayPrecompute;
    gaps=pre.Gaps;
    for k=1:height(gaps)
        idx=find(transport.Trips.TripID==gaps.TripID(k),1);
        if isempty(idx), error('预计算通信样本与运输架次编号不一致。'); end
        gaps.Time_s(k)=pre.GapOffsets_s(k)+transport.Trips.Start_s(idx);
    end
    [gaps,ord]=sortrows(gaps,'Time_s');
    cap=pre.Capability(ord,:);
    candidates=pre.CandidatePoints;
    transit=pre.Transit_s; maxService=pre.MaxService_s;
    backTime=pre.BackTime_s; valid=pre.Valid;
else
    gaps=problem3.sampleGaps(transport,data,config.GapSampleStep_s);
end
empty=table(strings(0,1),strings(0,1),strings(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
    zeros(0,1),zeros(0,1),zeros(0,1), ...
    'VariableNames',{'RelayTripID','RelayID','ComponentID','Start_s', ...
    'HoverLon_deg','HoverLat_deg','HoverAlt_m','LinkReady_s', ...
    'ServiceEnd_s','Return_s','Energy_kWh','ReturnSOC_pct'});
if isempty(gaps)
    out=struct('Feasible',true,'Failure',"",'RelayTrips',empty, ...
        'DroneTimeline',table(),'ComponentTimeline',table(),'Gaps',gaps, ...
        'Precompute',[],'CandidatePoints',zeros(0,3), ...
        'Capability',false(0,0));
    return;
end
nG=height(gaps);
if ~usePre
    candidates=makeCandidates(data);
    nC=size(candidates,1);
    gateway=gatewayPoint(data);
    cap=false(nG,nC); transit=nan(nC,1); maxService=nan(nC,1);
    backTime=nan(nC,1); valid=false(nC,1);
    for i=1:nC
        q=candidates(i,:);
        bh=problem3.linkState(q,gateway,"backhaul",data);
        if ~bh.Available, continue; end
        try
            c=problem3.relayCost(q,0,1200,data);
        catch
            continue;
        end
        if c.MaxService_s<=0, continue; end
        transit(i)=c.LinkReady_s; maxService(i)=c.MaxService_s;
        backTime(i)=c.BackTime_s; valid(i)=true;
        for j=1:nG
            p=[gaps.Lon(j),gaps.Lat(j),gaps.Alt_m(j)];
            a=problem3.linkState(p,q,"access",data);
            cap(j,i)=a.Available;
        end
    end
    offsets=zeros(nG,1);
    for k=1:nG
        idx=find(transport.Trips.TripID==gaps.TripID(k),1);
        offsets(k)=gaps.Time_s(k)-transport.Trips.Start_s(idx);
    end
    pre=struct('Gaps',gaps,'GapOffsets_s',offsets,'Capability',cap, ...
        'CandidatePoints',candidates,'Transit_s',transit, ...
        'MaxService_s',maxService,'BackTime_s',backTime,'Valid',valid);
end
if any(~any(cap,2))
    out=struct('Feasible',false,'Failure',"存在候选点无法覆盖的直连缺口", ...
        'Uncovered',gaps(~any(cap,2),:),'Gaps',gaps, ...
        'CandidatePoints',candidates,'Capability',cap,'Precompute',pre); return;
end
[missions,covered]=beamSchedule(cap,gaps,valid,transit,maxService,backTime,data,config);
if ~all(covered)
    out=struct('Feasible',false,'Failure', ...
        sprintf('两架中继的任务和周转时间无法覆盖 %.3f s 起的缺口。', ...
        gaps.Time_s(find(~covered,1))), ...
        'Uncovered',gaps(~covered,:),'Gaps',gaps, ...
        'CandidatePoints',candidates,'Capability',cap,'Precompute',pre); return;
end
rows=cell(numel(missions),1); dRows=rows; cRows=rows;
for k=1:numel(missions)
    m=missions(k); id=string(sprintf('R%03d',k));
    c=problem3.relayCost(candidates(m.Candidate,:),m.Start_s,m.End_s,data);
    if ~c.Feasible
        out=struct('Feasible',false,'Failure',c.Failure,'Gaps',gaps); return;
    end
    did=data.Relay.DroneIDs(m.Drone);
    cid=data.Relay.ComponentIDs(m.Component);
    rows{k}=table(id,did,cid,c.Start_s,c.Point(1),c.Point(2),c.Point(3), ...
        c.LinkReady_s,c.ServiceEnd_s,c.Return_s,c.Energy_kWh,c.ReturnSOC_pct, ...
        'VariableNames',empty.Properties.VariableNames);
    dRows{k}=table(did,id,c.Start_s,c.Return_s, ...
        c.Return_s+data.Relay.TurnTime_s, ...
        'VariableNames',{'ResourceID','TripID','Start_s','TaskEnd_s','Available_s'});
    cRows{k}=table(cid,id,c.Start_s,c.Return_s, ...
        c.Return_s+common.chargeTime(c.ReturnSOC_pct/100,data.Relay.FullChargeTime_s), ...
        'VariableNames',{'ResourceID','TripID','Start_s','TaskEnd_s','Available_s'});
end
out=struct('Feasible',true,'Failure',"",'RelayTrips',vertcat(rows{:}), ...
    'DroneTimeline',vertcat(dRows{:}),'ComponentTimeline',vertcat(cRows{:}), ...
    'Gaps',gaps,'CandidatePoints',candidates,'Capability',cap,'Precompute',pre);
end

function [missions,covered]=beamSchedule(cap,gaps,valid,transit,maxService,backTime,data,config)
nG=height(gaps);
if ~isfield(config,'RelayBeamWidth'), config.RelayBeamWidth=36; end
if ~isfield(config,'RelayWindowChoices_s')
    config.RelayWindowChoices_s=[300,600,900,1500,2400,4000,7000];
end
prototype=struct('Candidate',{},'Drone',{},'Component',{}, ...
    'Start_s',{},'End_s',{});
initial=struct('Covered',false(nG,1),'DAvail',zeros(numel(data.Relay.DroneIDs),1), ...
    'CAvail',zeros(numel(data.Relay.ComponentIDs),1), ...
    'Missions',prototype,'Score',0);
beam={initial}; best=initial;
hoverPower=data.Relay.HoverPower_kW+data.Relay.CommPower_kW;
energyBudget=data.Relay.Use_kWh*(1-data.Relay.ReserveRatio);
for depth=1:16
    next=cell(0,1); solved=cell(0,1);
    for b=1:numel(beam)
        state=beam{b};
        first=find(~state.Covered,1);
        if isempty(first), solved{end+1}=state; continue; end %#ok<AGROW>
        t=gaps.Time_s(first);
        cand=find(valid & cap(first,:).');
        [~,ci]=min(state.CAvail);
        for i=cand(:)'
            for di=1:numel(state.DAvail)
                start=max([0,state.DAvail(di),state.CAvail(ci), ...
                    t-transit(i)-config.GapSampleStep_s]);
                ready=start+transit(i);
                if ready>t+1e-7, continue; end
                for window=config.RelayWindowChoices_s
                    limit=min(t+window,ready+maxService(i)-1e-6);
                    mask=~state.Covered & cap(:,i) & ...
                        gaps.Time_s>=ready-1e-7 & gaps.Time_s<=limit+1e-7;
                    if ~any(mask), continue; end
                    finish=min(max(gaps.Time_s(mask))+config.GapSampleStep_s, ...
                        ready+maxService(i)-1e-6);
                    missionCover=cap(:,i) & gaps.Time_s>=ready-1e-7 & ...
                        gaps.Time_s<=finish+1e-7;
                    child=state;
                    child.Covered=state.Covered | missionCover;
                    ret=finish+backTime(i);
                    duration=finish-ready;
                    e=energyBudget-hoverPower*(maxService(i)-duration)/3600;
                    soc=1-e/data.Relay.Use_kWh;
                    child.DAvail(di)=ret+data.Relay.TurnTime_s;
                    child.CAvail(ci)=ret+common.chargeTime(soc,data.Relay.FullChargeTime_s);
                    m=struct('Candidate',i,'Drone',di,'Component',ci, ...
                        'Start_s',start,'End_s',finish);
                    child.Missions(end+1)=m;
                    nextIdx=find(~child.Covered,1);
                    if isempty(nextIdx)
                        solved{end+1,1}=child; %#ok<AGROW>
                    else
                        child.Score=nextIdx*1e4+nnz(child.Covered)- ...
                            0.0001*sum(child.DAvail);
                        next{end+1,1}=child; %#ok<AGROW>
                        if child.Score>best.Score, best=child; end
                    end
                end
            end
        end
    end
    if ~isempty(solved)
        [~,idx]=min(cellfun(@(x)sum(x.DAvail),solved));
        missions=solved{idx}.Missions; covered=true(nG,1); return;
    end
    if isempty(next), break; end
    scores=cellfun(@(x)x.Score,next);
    [~,ord]=sort(scores,'descend');
    beam=next(ord(1:min(config.RelayBeamWidth,numel(ord))));
end
missions=best.Missions; covered=best.Covered;
end

function candidates=makeCandidates(data)
o=data.Nodes(data.Nodes.ID=="O01",:);
xy=zeros(0,2);
for j=1:15
    n=data.Nodes(data.Nodes.ID==sprintf('S%03d',j),:);
    for f=[0.5,0.75,1]
        xy(end+1,:)=[o.Lon+f*(n.Lon-o.Lon), ...
            o.Lat+f*(n.Lat-o.Lat)]; %#ok<AGROW>
    end
end
% 服务区周围 10 像元八邻域与服务区两两中点提供可移动的中继初始点。
for j=1:15
    n=data.Nodes(data.Nodes.ID==sprintf('S%03d',j),:);
    for dx=[-10,0,10]
        for dy=[-10,0,10]
            xy(end+1,:)=[n.Lon+dx*data.Dem.dLon, ...
                n.Lat+dy*data.Dem.dLat]; %#ok<AGROW>
        end
    end
    for h=j+1:15
        q=data.Nodes(data.Nodes.ID==sprintf('S%03d',h),:);
        xy(end+1,:)=[(n.Lon+q.Lon)/2,(n.Lat+q.Lat)/2]; %#ok<AGROW>
    end
end
rc=round(1+(xy(:,2)-data.Dem.Lat(1))/data.Dem.dLat);
cc=round(1+(xy(:,1)-data.Dem.Lon(1))/data.Dem.dLon);
ok=rc>=1 & rc<=size(data.Dem.Z,1) & cc>=1 & cc<=size(data.Dem.Z,2);
rc=rc(ok); cc=cc(ok);
indices=sub2ind(size(data.Dem.Z),rc,cc);
ok=isfinite(data.Dem.Z(indices));
rc=rc(ok); cc=cc(ok);
coords=unique([cc,rc],'rows','stable');
ground=data.Dem.Z(sub2ind(size(data.Dem.Z),coords(:,2),coords(:,1)));
levels=unique(min(data.Relay.MaxAGL_m,[100,200,300]));
levels=levels(levels>0);
candidates=zeros(size(coords,1)*numel(levels),3);
for k=1:numel(levels)
    rows=(k-1)*size(coords,1)+(1:size(coords,1));
    candidates(rows,:)=[data.Dem.Lon(coords(:,1)), ...
        data.Dem.Lat(coords(:,2)),ground+levels(k)];
end
end

function p=gatewayPoint(data)
i=find(data.Nodes.ID=="O01",1);
p=[data.Nodes.Lon(i),data.Nodes.Lat(i), ...
    data.Nodes.GroundElev(i)+data.Comm.GatewayAGL_m];
end
