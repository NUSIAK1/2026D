function out = certifyCoverage(transport,relayTrips,data,config)
%CERTIFYCOVERAGE 区间上保守认证每架运输机的连续双向通信。
if ~isfield(config,'CommMaxDepth'), config.CommMaxDepth=30; end
if ~isfield(config,'CommMinInterval_s'), config.CommMinInterval_s=0.001; end
gateway=gatewayPoint(data);
backhaul=false(height(relayTrips),1);
for j=1:height(relayTrips)
    q=[relayTrips.HoverLon_deg(j),relayTrips.HoverLat_deg(j),relayTrips.HoverAlt_m(j)];
    a=problem3.linkState(q,gateway,"backhaul",data);
    backhaul(j)=a.Available;
end
rows=cell(0,1); failure=struct('TripID',"",'Start_s',NaN,'End_s',NaN, ...
    'Phase',"",'Reason',"");
for i=1:numel(transport.Phases)
    problem3.checkDeadline(config);
    p=transport.Phases(i);
    breaks=[p.Start_s;p.End_s];
    for j=1:height(relayTrips)
        a=relayTrips.LinkReady_s(j); b=relayTrips.ServiceEnd_s(j);
        if a>p.Start_s && a<p.End_s, breaks(end+1)=a; end %#ok<AGROW>
        if b>p.Start_s && b<p.End_s, breaks(end+1)=b; end %#ok<AGROW>
    end
    breaks=unique(sort(breaks));
    for k=1:numel(breaks)-1
        [ok,parts,bad]=certifyOne(p,breaks(k),breaks(k+1),0, ...
            relayTrips,backhaul,gateway,data,config);
        if ~ok
            failure=struct('TripID',p.TripID,'Start_s',bad(1), ...
                'End_s',bad(2),'Phase',p.Phase, ...
                'Reason',"区间内无可证明连续可用的直连或中继链路");
            out=struct('Feasible',false,'Failure',failure,'Coverage',table());
            return;
        end
        rows=[rows;parts(:)]; %#ok<AGROW>
    end
end
if isempty(rows)
    out=struct('Feasible',false,'Failure',failure,'Coverage',table()); return;
end
raw=vertcat(rows{:});
merged=raw(1,:);
for i=2:height(raw)
    prev=height(merged);
    if raw.TripID(i)==merged.TripID(prev) && ...
            raw.PhaseIndex(i)==merged.PhaseIndex(prev) && ...
            raw.Mode(i)==merged.Mode(prev) && ...
            raw.RelayTripID(i)==merged.RelayTripID(prev) && ...
            abs(raw.Start_s(i)-merged.End_s(prev))<1e-7
        merged.End_s(prev)=raw.End_s(i);
        merged.WorstMargin_dB(prev)=min(merged.WorstMargin_dB(prev),raw.WorstMargin_dB(i));
    else
        merged=[merged;raw(i,:)]; %#ok<AGROW>
    end
end
out=struct('Feasible',true,'Failure',failure,'Coverage',merged);
end

function [ok,rows,bad]=certifyOne(p,a,b,depth,relays,bh,gw,data,config)
rows=cell(0,1); bad=[a,b];
x0=problem3.positionAt(p,a); x1=problem3.positionAt(p,b);
[yes,margin]=safeInterval(x0,x1,gw,"direct",data);
if yes
    rows={makeRow(p,a,b,"直连","",margin)}; ok=true; return;
end
% 若区间内可观测到直连，先细分以定位直连与中继的切换时刻。
% 因此不会把明显可直连的整段错误标为中继。
if depth<config.CommMaxDepth && b-a>config.CommMinInterval_s
    xm=problem3.positionAt(p,(a+b)/2);
    directMid=problem3.linkState(xm,gw,"direct",data);
    directA=problem3.linkState(x0,gw,"direct",data);
    directB=problem3.linkState(x1,gw,"direct",data);
    if directMid.Available || directA.Available || directB.Available
        mid=(a+b)/2;
        [leftOK,L,bad]=certifyOne(p,a,mid,depth+1,relays,bh,gw,data,config);
        if ~leftOK, ok=false; return; end
        [rightOK,R,bad]=certifyOne(p,mid,b,depth+1,relays,bh,gw,data,config);
        if ~rightOK, ok=false; return; end
        rows=[L;R]; ok=true; return;
    end
end
for j=1:height(relays)
    if ~bh(j) || relays.LinkReady_s(j)>a+1e-9 || ...
            relays.ServiceEnd_s(j)<b-1e-9
        continue;
    end
    q=[relays.HoverLon_deg(j),relays.HoverLat_deg(j),relays.HoverAlt_m(j)];
    [yes,margin]=safeInterval(x0,x1,q,"access",data);
    if yes
        rows={makeRow(p,a,b,"中继",relays.RelayTripID(j),margin)};
        ok=true; return;
    end
end
if depth>=config.CommMaxDepth || b-a<=config.CommMinInterval_s
    ok=false; return;
end
mid=(a+b)/2;
[leftOK,L,bad]=certifyOne(p,a,mid,depth+1,relays,bh,gw,data,config);
if ~leftOK, ok=false; return; end
[rightOK,R,bad]=certifyOne(p,mid,b,depth+1,relays,bh,gw,data,config);
if ~rightOK, ok=false; return; end
rows=[L;R]; ok=true;
end

function row=makeRow(p,a,b,mode,relayID,margin)
row=table(p.TripID,p.PhaseIndex,p.Phase,a,b,mode,string(relayID),true,margin, ...
    'VariableNames',{'TripID','PhaseIndex','Phase','Start_s','End_s', ...
    'Mode','RelayTripID','Certified','WorstMargin_dB'});
end

function [yes,margin]=safeInterval(a0,a1,fixed,kind,data)
% 三维距离以三角不等式给出上界，遮挡先按最坏附加损耗。
s0=problem3.linkState(a0,fixed,kind,data);
s1=problem3.linkState(a1,fixed,kind,data);
if s0.UnknownTerrain || s1.UnknownTerrain
    yes=false; margin=-inf; return;
end
moving=pathLengthUpper(a0,a1);
dUpper=(min(s0.Distance_km,s1.Distance_km)*1000+moving+1e-6)/1000;
c=data.Comm;
baseLoss=32.44+20*log10(c.Frequency_MHz)+20*log10(max(dUpper,1e-12));
margin=s0.Threshold_dB-baseLoss-c.ObstacleLoss_dB;
if margin>=1e-8
    yes=sweptValid(a0,a1,fixed,data.Dem,false);
    return;
end
% 无法按最坏遮挡通过时，尝试用扫掠像元的海拔下界证明全程无遮挡。
clear=sweptValid(a0,a1,fixed,data.Dem,true);
margin=s0.Threshold_dB-baseLoss;
yes=clear && margin>=1e-8;
end

function yes=sweptValid(a0,a1,fixed,dem,needClear)
p0=gridCoord(a0,dem); p1=gridCoord(a1,dem); f=gridCoord(fixed,dem);
sz=size(dem.Z);
p=sweptCandidates(f,p0,p1,sz);
if isempty(p), yes=false; return; end
allZ=dem.Z(sub2ind(sz,p(:,1),p(:,2)));
if all(isfinite(allZ)) && ~needClear
    yes=true; return;
end
if all(isfinite(allZ)) && needClear && ...
        max(allZ)<min([fixed(3),a0(3),a1(3)])-1e-7
    yes=true; return;
end
triangle=[f,fixed(3);p0,a0(3);p1,a1(3)];
for k=1:size(p,1)
    row=p(k,1); col=p(k,2);
    clipped=clipCell(triangle,col,row);
    if isempty(clipped), continue; end
    z=dem.Z(row,col);
    if ~isfinite(z), yes=false; return; end
    if needClear && min(clipped(:,3))<=z+1e-7
        yes=false; return;
    end
end
yes=true;
end

function pixels=sweptCandidates(f,p0,p1,sz)
% 闭合像元若与扫掠三角形相交，其中心距三角形不超过半对角线。
v=[f;p0;p1];
cmin=max(1,ceil(min(v(:,1))-0.5));
cmax=min(sz(2),floor(max(v(:,1))+0.5));
rmin=max(1,ceil(min(v(:,2))-0.5));
rmax=min(sz(1),floor(max(v(:,2))+0.5));
if cmin>cmax || rmin>rmax
    pixels=zeros(0,2); return;
end
[C,R]=meshgrid(cmin:cmax,rmin:rmax);
P=[C(:),R(:)];
inside=inpolygon(P(:,1),P(:,2),v(:,1),v(:,2));
d2=inf(size(P,1),1);
for k=1:3
    a=v(k,:); b=v(mod(k,3)+1,:); e=b-a;
    den=dot(e,e);
    if den<1e-20
        q=repmat(a,size(P,1),1);
    else
        u=max(0,min(1,((P(:,1)-a(1))*e(1)+(P(:,2)-a(2))*e(2))/den));
        q=a+u.*e;
    end
    d2=min(d2,sum((P-q).^2,2));
end
% 闭合像元的中心到像元内任一点最多相距半对角线 sqrt(2)/2。
% 用半边长 0.5 会遗漏仅在角部与扫掠面相交的像元。
mask=inside | d2<=sqrt(2)/2+1e-7;
pixels=[R(mask),C(mask)];
end

function poly=clipCell(poly,col,row)
% 视线扫掠三角形与闭合 DEM 像元柱体相交；高度在线性裁剪中精确保留。
limits=[1,col-0.5,1;1,col+0.5,-1;2,row-0.5,1;2,row+0.5,-1];
for k=1:4
    axis=limits(k,1); edge=limits(k,2); signDir=limits(k,3);
    if isempty(poly), return; end
    output=zeros(0,3);
    previous=poly(end,:);
    prevInside=signDir*(previous(axis)-edge)>=-1e-10;
    for j=1:size(poly,1)
        current=poly(j,:);
        currInside=signDir*(current(axis)-edge)>=-1e-10;
        if currInside~=prevInside
            den=current(axis)-previous(axis);
            if abs(den)>1e-15
                t=max(0,min(1,(edge-previous(axis))/den));
                output(end+1,:)=previous+t*(current-previous); %#ok<AGROW>
            end
        end
        if currInside
            output(end+1,:)=current; %#ok<AGROW>
        end
        previous=current; prevInside=currInside;
    end
    poly=output;
end
end

function p=gridCoord(a,dem)
p=[1+(a(1)-dem.Lon(1))/dem.dLon,1+(a(2)-dem.Lat(1))/dem.dLat];
end

function upper=pathLengthUpper(a,b)
% 经纬度线性阶段在球面上的弧长上界，再与垂直位移合成。
R=6371000;
dlat=deg2rad(b(2)-a(2));
dlon=deg2rad(b(1)-a(1));
maxCos=max(cosd(a(2)),cosd(b(2)));
horizontalUpper=R*hypot(dlat,maxCos*dlon);
upper=hypot(horizontalUpper,b(3)-a(3));
end

function p=gatewayPoint(data)
i=find(data.Nodes.ID=="O01",1);
p=[data.Nodes.Lon(i),data.Nodes.Lat(i), ...
    data.Nodes.GroundElev(i)+data.Comm.GatewayAGL_m];
end
