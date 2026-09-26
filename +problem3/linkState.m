function state = linkState(a,b,kind,data)
%LINKSTATE 单时刻双向链路预算及闭合 DEM 像元遮挡判定。
% a,b = [经度,纬度,绝对海拔]；kind 为 direct/access/backhaul。
switch string(kind)
    case "direct", ia=1; ib=4;
    case "access", ia=1; ib=2;
    case "backhaul", ia=3; ib=4;
    otherwise, error('未知链路类型 %s。',kind);
end
c=data.Comm;
thresholdAB = c.Tx_dBm(ia)+c.Gain_dBi(ia)+c.Gain_dBi(ib) ...
    -c.SystemLoss_dB-c.Sensitivity_dBm-c.FadeMargin_dB;
thresholdBA = c.Tx_dBm(ib)+c.Gain_dBi(ib)+c.Gain_dBi(ia) ...
    -c.SystemLoss_dB-c.Sensitivity_dBm-c.FadeMargin_dB;
threshold=min(thresholdAB,thresholdBA);
[d0]=pointDistance(a,b)/1000;
unobstructedLoss=32.44+20*log10(c.Frequency_MHz)+20*log10(max(d0,1e-12));
if unobstructedLoss>threshold+1e-9
    state=struct('Available',false,'UnknownTerrain',false,'Obstructed',false, ...
        'Margin_dB',threshold-unobstructedLoss,'Threshold_dB',threshold, ...
        'Distance_km',d0);
    return;
end
[pixels,tLo,tHi] = problem3.communicationRay(a,b,data.Dem);
z=data.Dem.Z(sub2ind(size(data.Dem.Z),pixels(:,1),pixels(:,2)));
if any(~isfinite(z))
    state=struct('Available',false,'UnknownTerrain',true,'Obstructed',false, ...
        'Margin_dB',-inf,'Threshold_dB',threshold,'Distance_km',NaN);
    return;
end
heightLo=min(a(3)+(b(3)-a(3))*tLo,a(3)+(b(3)-a(3))*tHi);
blocked=any(z>=heightLo-1e-9);
d=d0;
loss=unobstructedLoss ...
    +double(blocked)*c.ObstacleLoss_dB;
state=struct('Available',loss<=threshold+1e-9, ...
    'UnknownTerrain',false,'Obstructed',blocked, ...
    'Margin_dB',threshold-loss,'Threshold_dB',threshold, ...
    'Distance_km',d);
end

function d=pointDistance(a,b)
R=6371000;
p1=deg2rad(a(2)); p2=deg2rad(b(2));
dp=p2-p1; dl=deg2rad(b(1)-a(1));
h=sin(dp/2)^2+cos(p1)*cos(p2)*sin(dl/2)^2;
horizontal=2*R*asin(min(1,sqrt(max(0,h))));
d=hypot(horizontal,b(3)-a(3));
end
