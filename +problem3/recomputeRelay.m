function relay = recomputeRelay(relay,data)
%RECOMPUTERELAY 保留旧中继位置与任务请求，按本轮物理数据重算时间和能量。
trips=relay.RelayTrips;
relay.Feasible=true;
dRows=cell(height(trips),1); cRows=dRows;
for k=1:height(trips)
    tr=trips(k,:);
    point=[tr.HoverLon_deg,tr.HoverLat_deg,tr.HoverAlt_m];
    try
        cost=problem3.relayCost(point,tr.Start_s,tr.ServiceEnd_s,data);
    catch ME
        relay.Feasible=false; relay.Failure=string(ME.message); return;
    end
    if ~cost.Feasible, relay.Feasible=false; return; end
    trips.LinkReady_s(k)=cost.LinkReady_s;
    trips.Return_s(k)=cost.Return_s;
    trips.Energy_kWh(k)=cost.Energy_kWh;
    trips.ReturnSOC_pct(k)=cost.ReturnSOC_pct;
    dRows{k}=table(tr.RelayID,tr.RelayTripID,tr.Start_s,cost.Return_s, ...
        cost.Return_s+data.Relay.TurnTime_s, ...
        'VariableNames',{'ResourceID','TripID','Start_s','TaskEnd_s','Available_s'});
    cRows{k}=table(tr.ComponentID,tr.RelayTripID,tr.Start_s,cost.Return_s, ...
        cost.Return_s+common.chargeTime(cost.ReturnSOC_pct/100,data.Relay.FullChargeTime_s), ...
        'VariableNames',{'ResourceID','TripID','Start_s','TaskEnd_s','Available_s'});
end
relay.RelayTrips=trips;
if ~isempty(trips)
    relay.DroneTimeline=vertcat(dRows{:});
    relay.ComponentTimeline=vertcat(cRows{:});
end
end
