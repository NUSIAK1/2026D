function test_problem3()
%TEST_PROBLEM3 题面参数、边界和全量方案回归测试。
p=common.projectPaths();
d=problem3.loadData(struct('FlightBaseFile',p.FlightBaseFile));
assert(height(d.Nodes)==16 && height(d.Boxes)==80);
assert(height(d.Drones)==8 && height(d.Batteries)==14);
assert(numel(d.Relay.DroneIDs)==2 && numel(d.Relay.ComponentIDs)==6);
assert(abs(common.chargeTime(0.9,1800)-630)<1e-8);
assert(abs(common.chargeTime(1,1800))<1e-8);

% 三类双向链路门限必须与附件参数独立计算值相同。
o=d.Nodes(d.Nodes.ID=="O01",:);
g=[o.Lon,o.Lat,o.GroundElev+d.Comm.GatewayAGL_m];
pt=[o.Lon,o.Lat,o.GroundElev+80];
assert(abs(problem3.linkState(pt,g,"direct",d).Threshold_dB-122)<1e-10);
assert(abs(problem3.linkState(pt,g,"access",d).Threshold_dB-116)<1e-10);
assert(abs(problem3.linkState(pt,g,"backhaul",d).Threshold_dB-126)<1e-10);

% 人工 DEM：无遮挡、遮挡仍可用、遮挡导致中断，以及 NoData。
tiny=d; tiny.Dem.Z=zeros(10,1000);
tiny.Dem.Lat=(0:9)'*0.0001; tiny.Dem.Lon=(0:999)'*0.0001;
tiny.Dem.dLat=0.0001; tiny.Dem.dLon=0.0001;
a=[0.001,0.0004,150]; b=[0.002,0.0004,150];
q=problem3.linkState(a,b,"access",tiny);
assert(q.Available && ~q.Obstructed);
tiny.Dem.Z(5,16)=200;
q=problem3.linkState(a,b,"access",tiny);
assert(q.Available && q.Obstructed);
far=[0.055,0.0004,150];
q=problem3.linkState(a,far,"access",tiny);
assert(~q.Available && q.Obstructed);
tiny.Dem.Z(5,16)=NaN;
q=problem3.linkState(a,b,"access",tiny);
assert(~q.Available && q.UnknownTerrain);

% 扫掠三角形仅从像元角部经过，端点视线均避开该 NoData 像元。
% 认证器必须检查半对角线范围内的闭合像元，不能将整段误判为可用。
tiny.Dem.Z(:)=0; tiny.Dem.Z(6,5)=NaN;
f=[0.0001,0.0001,150];
tiny.Nodes.Lon(tiny.Nodes.ID=="O01")=f(1);
tiny.Nodes.Lat(tiny.Nodes.ID=="O01")=f(2);
tiny.Nodes.GroundElev(tiny.Nodes.ID=="O01")= ...
    f(3)-tiny.Comm.GatewayAGL_m;
p0=[0.0004891439112640089,0.0001370413360711378,150];
p1=[0.00029688994176625734,0.0006116535430723329,150];
phase=struct('TripID',"T1",'PhaseIndex',1,'Phase',"巡航", ...
    'Start_s',0,'End_s',10,'A',p0,'B',p1);
mock=struct('Phases',phase);
assert(problem3.linkState(p0,f,"direct",tiny).Available);
assert(problem3.linkState(p1,f,"direct",tiny).Available);
assert(~problem3.certifyCoverage(mock,table(),tiny,struct()).Feasible);

% 中继高于和低于规定巡航海拔的往返、建链、悬停能耗。
n=d.Nodes(d.Nodes.ID=="S001",:);
row=round(1+(n.Lat-d.Dem.Lat(1))/d.Dem.dLat);
col=round(1+(n.Lon-d.Dem.Lon(1))/d.Dem.dLon);
ground=d.Dem.Z(row,col);
point=[d.Dem.Lon(col),d.Dem.Lat(row),ground+30];
low=problem3.relayCost(point,0,1000,d);
assert(low.Feasible && low.LinkReady_s>0 && low.Return_s>1000);
point(3)=ground+300;
high=problem3.relayCost(point,0,1000,d);
assert(high.Feasible && high.Point(3)>high.CruiseAlt_m);
plus=problem3.relayCost(point,0,1100,d);
assert(abs((plus.Energy_kWh-high.Energy_kWh)- ...
    100*(d.Relay.HoverPower_kW+d.Relay.CommPower_kW)/3600)<1e-8);

% 全数据解从零计算，并再次独立认证连续通信和全部资源约束。
r=problem3.run_problem3(struct('NumRuns',1,'MaxIterations',0, ...
    'TimeLimit_s',180,'ExportFiles',false,'Verbose',false));
assert(~isempty(r.ParetoFront));
rep=r.Representatives.Balanced;
assert(rep.Validation.Feasible && all(rep.Validation.Checks.Passed));
assert(height(rep.Transport.Deliveries)==80);
assert(all(rep.Coverage.Certified));
for k=1:height(rep.Coverage)
    row=rep.Coverage(k,:);
    if row.Mode~="中继", continue; end
    pIdx=find([rep.Transport.Phases.TripID]==row.TripID & ...
        [rep.Transport.Phases.PhaseIndex]==row.PhaseIndex,1);
    pos=problem3.positionAt(rep.Transport.Phases(pIdx), ...
        (row.Start_s+row.End_s)/2);
    assert(~problem3.linkState(pos,g,"direct",d).Available, ...
        '中继保障区间中点可直连，应按直连优先细分。');
end
assert(abs(rep.Validation.Objectives(2)- ...
    max([rep.Transport.Trips.Return_s;rep.Relay.RelayTrips.Return_s]))<1e-7);
fprintf('problem3.tests.test_problem3 全部通过。\n');
end
