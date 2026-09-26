function [pixels,tLo,tHi] = communicationRay(a,b,dem)
%COMMUNICATIONRAY 矢量化闭合像元通信射线，返回每个像元的精确参数区间。
% 与 common.traceDemSupercover 的边界事件/闭合接触口径相同。
ca=1+(a(1)-dem.Lon(1))/dem.dLon;
cb=1+(b(1)-dem.Lon(1))/dem.dLon;
ra=1+(a(2)-dem.Lat(1))/dem.dLat;
rb=1+(b(2)-dem.Lat(1))/dem.dLat;
sz=size(dem.Z);
if any(~isfinite([ca,cb,ra,rb])) || min([ca,cb])<0.5-1e-8 || ...
        max([ca,cb])>sz(2)+0.5+1e-8 || min([ra,rb])<0.5-1e-8 || ...
        max([ra,rb])>sz(1)+0.5+1e-8
    error('通信射线超出 DEM 覆盖范围。');
end
tol=1e-9; eventTol=1e-12;
ends=snap([ca,ra;cb,rb],tol); delta=ends(2,:)-ends(1,:);
events=[0;1];
for axis=1:2
    if abs(delta(axis))<=tol, continue; end
    lo=min(ends(:,axis)); hi=max(ends(:,axis));
    boundaries=(ceil(lo-0.5):floor(hi-0.5)).'+0.5;
    t=(boundaries-ends(1,axis))/delta(axis);
    events=[events;t(t>eventTol & t<1-eventTol)]; %#ok<AGROW>
end
events=sort(events);
keep=false(size(events)); keep(1)=true; previous=events(1);
for k=2:numel(events)
    if events(k)-previous>eventTol, keep(k)=true; previous=events(k); end
end
events=events(keep); events(1)=0; events(end)=1;
t=[events;(events(1:end-1)+events(2:end))/2];
points=snap(ends(1,:)+t.*delta,tol);
cmin=ceil(points(:,1)-0.5-tol); cmax=floor(points(:,1)+0.5+tol);
rmin=ceil(points(:,2)-0.5-tol); rmax=floor(points(:,2)+0.5+tol);
pixels=unique([rmin,cmin;rmin,cmax;rmax,cmin;rmax,cmax],'rows');
pixels=pixels(pixels(:,1)>=1 & pixels(:,1)<=sz(1) & ...
    pixels(:,2)>=1 & pixels(:,2)<=sz(2),:);
assert(~isempty(pixels),'通信射线未接触有效 DEM 像元。');
dx=cb-ca; dy=rb-ra;
tLo=zeros(size(pixels,1),1); tHi=ones(size(pixels,1),1);
if abs(dx)>1e-12
    x1=(pixels(:,2)-0.5-ca)/dx; x2=(pixels(:,2)+0.5-ca)/dx;
    tLo=max(tLo,min(x1,x2)); tHi=min(tHi,max(x1,x2));
end
if abs(dy)>1e-12
    y1=(pixels(:,1)-0.5-ra)/dy; y2=(pixels(:,1)+0.5-ra)/dy;
    tLo=max(tLo,min(y1,y2)); tHi=min(tHi,max(y1,y2));
end
tLo=max(0,min(1,tLo)); tHi=max(0,min(1,tHi));
end

function values=snap(values,tol)
nearest=round(2*values)/2;
use=abs(values-nearest)<=tol;
values(use)=nearest(use);
end
