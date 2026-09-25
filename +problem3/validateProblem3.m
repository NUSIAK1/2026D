function validation = validateProblem3(solution,data,config)
%VALIDATEPROBLEM3 对完整联合方案逐项独立校核并重算五个目标。
if nargin<3, config=struct(); end
T=solution.Transport;
if isfield(solution.Relay,'RelayTrips'), R=solution.Relay.RelayTrips;
else, R=solution.Relay; end
checks=strings(0,1); passed=false(0,1); details=strings(0,1);
    function add(name,ok,detail)
        checks(end+1,1)=name; passed(end+1,1)=logical(ok); details(end+1,1)=string(detail);
    end
add("运输解码",isfield(T,'Feasible') && T.Feasible,"运输架次解码器可行");
if ~isfield(T,'Feasible') || ~T.Feasible
    validation=struct('Feasible',false,'Checks',table(checks,passed,details, ...
        'VariableNames',{'Check','Passed','Details'}),'Objectives',inf(1,5)); return;
end
boxOK=height(T.Deliveries)==height(data.Boxes) && ...
    isequal(sort(T.Deliveries.BoxID),sort(data.Boxes.BoxID));
add("80箱唯一交付",boxOK,sprintf('%d 条交付',height(T.Deliveries)));
deadlineOK=all(T.Deliveries.Delivery_s<=T.Deliveries.HardDeadline_s+1e-7);
add("医疗和首批时限",deadlineOK,"逐箱交接结束时刻不晚于硬截止");
add("运输实体机唯一与互斥", ...
    all(ismember(T.Trips.DroneID,data.Drones.DroneID)) && ...
    timelineOK(T.DroneTimeline),"实体机占用区间无重叠");
add("运输电池唯一与充电", ...
    all(ismember(T.Trips.BatteryID,data.Batteries.BatteryID)) && ...
    timelineOK(T.BatteryTimeline),"再次投入前充至满电");
modelOK=true; energyOK=true; phaseOK=true;
for k=1:height(T.Trips)
    tr=T.Trips(k,:);
    d=find(data.Drones.DroneID==tr.DroneID,1);
    b=find(data.Batteries.BatteryID==tr.BatteryID,1);
    m=find(data.Models.Model==tr.Model,1);
    modelOK=modelOK && ~isempty(d) && ~isempty(b) && ~isempty(m);
    if ~modelOK, break; end
    modelOK=modelOK && data.Drones.Model(d)==tr.Model && ...
        data.Batteries.Model(b)==tr.Model;
    energyOK=energyOK && tr.ReturnSOC_pct>=100*data.Models.ReserveRatio(m)-1e-7 ...
        && abs(tr.ReturnSOC_pct/100-(1-tr.Energy_kWh/data.Models.BatteryUse_kWh(m)))<1e-7 ...
        && tr.Mass_kg<=data.Models.MaxPayload_kg(m)+1e-9 ...
        && tr.Volume_m3<=data.Models.MaxVolume_m3(m)+1e-12;
    p=T.Phases([T.Phases.TripID]==tr.TripID);
    if isempty(p)
        phaseOK=false;
    else
        phaseOK=phaseOK && abs(p(1).Start_s-tr.Takeoff_s)<1e-7 && ...
            abs(p(end).End_s-tr.Return_s)<1e-7 && ...
            all(abs([p(1:end-1).End_s]-[p(2:end).Start_s])<1e-7);
    end
end
add("机型与能源匹配",modelOK,"实体机和电池型号匹配");
add("运输载荷、体积与能量",energyOK,"SOC 与能耗、载荷及体积一致");
add("运输阶段连续",phaseOK,"起飞至返航各阶段无空档");
relayEnergyOK=true; relayLinkOK=true;
gateway=gatewayPoint(data);
for k=1:height(R)
    row=R(k,:);
    point=[row.HoverLon_deg,row.HoverLat_deg,row.HoverAlt_m];
    try
        c=problem3.relayCost(point,row.Start_s,row.ServiceEnd_s,data);
        relayEnergyOK=relayEnergyOK && c.Feasible && ...
            abs(c.LinkReady_s-row.LinkReady_s)<1e-6 && ...
            abs(c.Return_s-row.Return_s)<1e-6 && ...
            abs(c.Energy_kWh-row.Energy_kWh)<1e-8 && ...
            abs(c.ReturnSOC_pct-row.ReturnSOC_pct)<1e-6;
        link=problem3.linkState(point,gateway,"backhaul",data);
        relayLinkOK=relayLinkOK && link.Available;
    catch
        relayEnergyOK=false; relayLinkOK=false;
    end
end
add("中继能量与周转",relayEnergyOK && timelineOK(solution.Relay.DroneTimeline) ...
    && timelineOK(solution.Relay.ComponentTimeline), ...
    "起降、建链、悬停、返航和充电重算一致");
add("中继回传",relayLinkOK,"每个中继悬停位置可双向回传 G01");
cert=problem3.certifyCoverage(T,R,data,config);
add("连续通信区间认证",cert.Feasible,"全部运输阶段覆盖且端点已验证");
if cert.Feasible
    coverage=cert.Coverage;
    add("保障记录引用",all(coverage.Certified) && ...
        all(ismember(coverage.RelayTripID(coverage.Mode=="中继"),R.RelayTripID)) && ...
        all(coverage.RelayTripID(coverage.Mode=="直连")==""), ...
        "直连优先，所有中继编号有对应架次");
end
late=max(0,(T.Deliveries.Delivery_s-T.Deliveries.ExpectedDeadline_s) ...
    ./T.Deliveries.ExpectedDeadline_s);
timeliness=sum(T.Deliveries.Priority.*late)/sum(data.Boxes.Priority);
if isempty(R), lastRelay=0; else, lastRelay=max(R.Return_s); end
obj=[timeliness,max(max(T.Trips.Return_s),lastRelay), ...
    sum(T.Trips.Energy_kWh)+sum(R.Energy_kWh),height(T.Trips),height(R)];
validation=struct('Feasible',all(passed),'Checks', ...
    table(checks,passed,details,'VariableNames',{'Check','Passed','Details'}), ...
    'Objectives',obj,'Coverage',cert.Coverage);
end

function yes=timelineOK(T)
yes=true;
if isempty(T), return; end
ids=unique(T.ResourceID);
for k=1:numel(ids)
    x=sortrows(T(T.ResourceID==ids(k),:),'Start_s');
    if any(x.Start_s(2:end)<x.Available_s(1:end-1)-1e-7) || ...
            any(x.TaskEnd_s<x.Start_s-1e-7)
        yes=false; return;
    end
end
end

function p=gatewayPoint(data)
i=find(data.Nodes.ID=="O01",1);
p=[data.Nodes.Lon(i),data.Nodes.Lat(i), ...
    data.Nodes.GroundElev(i)+data.Comm.GatewayAGL_m];
end
