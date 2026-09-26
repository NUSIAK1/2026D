function [relay,cert] = planCertifiedRelay(transport,data,config)
%PLANCERTIFIEDRELAY 将连续认证的失败区间反馈给中继规划，修复采样间隙。
if ~isfield(config,'MaxCoverageRepairs'), config.MaxCoverageRepairs=4; end
cert=struct('Feasible',false,'Coverage',table());
extra=table();
for attempt=0:config.MaxCoverageRepairs
    problem3.checkDeadline(config);
    relay=problem3.planRelay(transport,data,config);
    if ~relay.Feasible, return; end
    cert=problem3.certifyCoverage(transport,relay.RelayTrips,data,config);
    if cert.Feasible, return; end
    bad=cert.Failure;
    indices=find([transport.Phases.TripID]==bad.TripID & ...
        [transport.Phases.Start_s]<=bad.Start_s+1e-8 & ...
        [transport.Phases.End_s]>=bad.End_s-1e-8);
    if isempty(indices), return; end
    p=transport.Phases(indices(1));
    times=unique([bad.Start_s;(bad.Start_s+bad.End_s)/2;bad.End_s]);
    xyz=zeros(numel(times),3);
    for j=1:numel(times), xyz(j,:)=problem3.positionAt(p,times(j)); end
    added=table(repmat(p.TripID,numel(times),1), ...
        repmat(p.PhaseIndex,numel(times),1),times,xyz(:,1),xyz(:,2),xyz(:,3), ...
        'VariableNames',{'TripID','PhaseIndex','Time_s','Lon','Lat','Alt_m'});
    extra=[extra;added]; %#ok<AGROW>
    if attempt==config.MaxCoverageRepairs
        relay.Feasible=false;
        relay.Failure="连续通信认证失败："+bad.Reason;
        relay.Uncovered=extra(end-numel(times)+1:end,:);
        return;
    end
    if ~isempty(relay.Precompute)
        pre=relay.Precompute;
        cap=false(height(added),size(pre.CandidatePoints,1));
        for j=find(pre.Valid).'
            problem3.checkDeadline(config);
            cap(:,j)=problem3.linkAvailableBatch(xyz,pre.CandidatePoints(j,:),"access",data);
        end
        trip=find(transport.Trips.TripID==p.TripID,1);
        pre.Gaps=[pre.Gaps;added];
        pre.GapOffsets_s=[pre.GapOffsets_s;times-transport.Trips.Start_s(trip)];
        pre.Capability=[pre.Capability;cap];
        config.RelayPrecompute=pre;
    else
        config.ExtraGapPoints=extra;
        if isfield(config,'RelayPrecompute'), config=rmfield(config,'RelayPrecompute'); end
    end
end
end
