function available = linkAvailableBatch(points,fixed,kind,data)
%LINKAVAILABLEBATCH 与逐点链路同口径；距离排除与最坏遮挡界加速密集采样。
if isempty(points), available=false(0,1); return; end
[points,~,restore]=unique(points,'rows');
switch string(kind)
    case "direct", ia=1; ib=4;
    case "access", ia=1; ib=2;
    case "backhaul", ia=3; ib=4;
    otherwise, error('未知链路类型。');
end
c=data.Comm;
threshold=min(c.Tx_dBm([ia,ib]))+c.Gain_dBi(ia)+c.Gain_dBi(ib) ...
    -c.SystemLoss_dB-c.Sensitivity_dBm-c.FadeMargin_dB;
h=sin(deg2rad(points(:,2)-fixed(2))/2).^2+ ...
    cosd(points(:,2))*cosd(fixed(2)).*sin(deg2rad(points(:,1)-fixed(1))/2).^2;
distance=hypot(2*6371000*asin(min(1,sqrt(max(0,h)))),points(:,3)-fixed(3))/1000;
loss=32.44+20*log10(c.Frequency_MHz)+20*log10(max(distance,1e-12));
available=false(size(points,1),1);
possible=loss<=threshold+1e-9;
% 仅当整块射线包围矩形在 DEM 内且没有 NoData，才使用最坏遮挡快速通过。
xy=[points(possible,1:2);fixed(1:2)]; dem=data.Dem; sz=size(dem.Z);
cc=1+(xy(:,1)-dem.Lon(1))/dem.dLon;
rr=1+(xy(:,2)-dem.Lat(1))/dem.dLat;
inBounds=all(isfinite([cc;rr])) && min(cc)>=0.5 && max(cc)<=sz(2)+0.5 ...
    && min(rr)>=0.5 && max(rr)<=sz(1)+0.5;
if inBounds
    cs=max(1,ceil(min(cc)-0.5)):min(sz(2),floor(max(cc)+0.5));
    rs=max(1,ceil(min(rr)-0.5)):min(sz(1),floor(max(rr)+0.5));
    if all(isfinite(dem.Z(rs,cs)),'all')
        available=loss+c.ObstacleLoss_dB<=threshold+1e-9;
    end
end
for k=find(possible & ~available).'
    state=problem3.linkState(points(k,:),fixed,kind,data);
    available(k)=state.Available;
end
available=available(restore);
end
