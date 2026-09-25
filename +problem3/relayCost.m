function info = relayCost(point,start_s,end_s,data)
%RELAYCOST 中继 O01 往返、建链、悬停及能源周转的统一计算。
r=data.Relay;
o=find(data.Nodes.ID=="O01",1);
origin=[data.Nodes.Lon(o),data.Nodes.Lat(o),data.Nodes.WorkElev(o)];
sz=size(data.Dem.Z);
p0=[1+(origin(1)-data.Dem.Lon(1))/data.Dem.dLon, ...
    1+(origin(2)-data.Dem.Lat(1))/data.Dem.dLat];
p1=[1+(point(1)-data.Dem.Lon(1))/data.Dem.dLon, ...
    1+(point(2)-data.Dem.Lat(1))/data.Dem.dLat];
if any(~isfinite(p1)) || p1(1)<0.5 || p1(1)>sz(2)+0.5 || ...
        p1(2)<0.5 || p1(2)>sz(1)+0.5
    error('中继候选点超出 DEM。');
end
pix=common.traceDemSupercover(p0,p1,sz);
terrain=common.maxDemOnPath(data.Dem.Z,pix,"O01","中继点");
row=min(sz(1),max(1,round(p1(2))));
col=min(sz(2),max(1,round(p1(1))));
ground=data.Dem.Z(row,col);
agl=point(3)-ground;
if ~isfinite(ground) || agl<=0 || agl>r.MaxAGL_m+1e-9
    error('中继悬停离地高度无效。');
end
hc=terrain+50;
du=horizontalDistance(origin,point);
upOut=max(0,hc-origin(3))+max(0,point(3)-hc);
downOut=max(0,hc-point(3));
upBack=max(0,hc-point(3));
downBack=max(0,hc-origin(3))+max(0,point(3)-hc);
tOut=upOut/r.ClimbSpeed_mps+du/r.CruiseSpeed_mps+downOut/r.DescSpeed_mps;
tBack=upBack/r.ClimbSpeed_mps+du/r.CruiseSpeed_mps+downBack/r.DescSpeed_mps;
ready=start_s+r.PrepTime_s+tOut+r.LinkTime_s;
if end_s<ready-1e-8
    info=struct('Feasible',false,'Failure',"服务结束早于建链完成"); return;
end
eTravel=r.CruisePower_kW*(2*du/r.CruiseSpeed_mps)/3600+ ...
    r.Mass_kg*9.81*(upOut+upBack)/(3.6e6*r.ClimbEfficiency);
eHover=(r.HoverPower_kW+r.CommPower_kW)* ...
    (r.LinkTime_s+end_s-ready)/3600;
energy=eTravel+eHover;
soc=1-energy/r.Use_kWh;
info=struct('Feasible',soc>=r.ReserveRatio-1e-9, ...
    'Failure',"",'Point',point,'Ground_m',ground,'CruiseAlt_m',hc, ...
    'Start_s',start_s,'OutTime_s',tOut,'LinkReady_s',ready, ...
    'ServiceEnd_s',end_s,'BackTime_s',tBack,'Return_s',end_s+tBack, ...
    'Energy_kWh',energy,'ReturnSOC_pct',100*soc, ...
    'MaxService_s',max(0,(r.Use_kWh*(1-r.ReserveRatio)-eTravel)*3600/ ...
    (r.HoverPower_kW+r.CommPower_kW)-r.LinkTime_s));
if ~info.Feasible, info.Failure="中继返航 SOC 不足"; end
end

function d=horizontalDistance(a,b)
R=6371000; p1=deg2rad(a(2)); p2=deg2rad(b(2));
v=sin((p2-p1)/2)^2+cos(p1)*cos(p2)*sin(deg2rad(b(1)-a(1))/2)^2;
d=2*R*asin(min(1,sqrt(max(0,v))));
end
