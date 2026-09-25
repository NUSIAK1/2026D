function out = decodeTransport(solution,data)
%DECODETRANSPORT 由组批、路线及派发请求解码实体机、电池和分段轨迹。
n=numel(solution.Trips);
emptyTrip=struct('TripID',"",'BoxIDs',strings(0,1),'Stops',strings(0,1), ...
    'Model',"",'RequestedStart_s',0);
if n==0, error('运输方案无架次。'); end
if ~all(isfield(solution.Trips,fieldnames(emptyTrip)))
    error('运输架次结构缺少字段。');
end
order=sortrows([(1:n)',[solution.Trips.RequestedStart_s]'],2);
droneAvail=zeros(height(data.Drones),1);
batteryAvail=zeros(height(data.Batteries),1);
tripCells=cell(n,1); deliveryCells=cell(n,1); phaseCells=cell(n,1);
droneCells=cell(n,1); batteryCells=cell(n,1);
allOK=true; fail="";
for kk=1:n
    k=order(kk,1);
    tr=solution.Trips(k);
    boxMask=ismember(data.Boxes.BoxID,tr.BoxIDs);
    boxes=data.Boxes(boxMask,:);
    m=find(data.Models.Model==tr.Model,1);
    if isempty(m) || height(boxes)~=numel(tr.BoxIDs) || isempty(tr.Stops) || ...
            numel(unique(tr.Stops))~=numel(tr.Stops) || ...
            ~isequal(sort(unique(boxes.ServiceID)),sort(tr.Stops(:)))
        allOK=false; fail="组批、路线或机型无效"; break;
    end
    mass=sum(boxes.Mass_kg); volume=sum(boxes.Volume_m3);
    if mass>data.Models.MaxPayload_kg(m)+1e-9 || ...
            volume>data.Models.MaxVolume_m3(m)+1e-12
        allOK=false; fail="载荷或体积超限"; break;
    end
    dIdx=find(data.Drones.Model==tr.Model);
    bIdx=find(data.Batteries.Model==tr.Model);
    [dTime,di]=min(droneAvail(dIdx)); di=dIdx(di);
    [bTime,bi]=min(batteryAvail(bIdx)); bi=bIdx(bi);
    start=max([tr.RequestedStart_s,dTime,bTime]);
    cursor=start+data.Models.PrepTime_s(m)+data.Models.LoadTimeBox_s(m)*height(boxes);
    takeoff=cursor;
    energy=0; prev="O01"; payload=mass;
    phases=struct('TripID',{},'PhaseIndex',{},'Phase',{},'Start_s',{}, ...
        'End_s',{},'A',{},'B',{});
    delivered=cell(numel(tr.Stops),1);
    for j=1:numel(tr.Stops)+1
        if j<=numel(tr.Stops), next=tr.Stops(j); else, next="O01"; end
        try
            leg=common.calcLegCost(prev,next,tr.Model,payload,data.FlightBase);
        catch ME
            allOK=false; fail="航段计算失败："+string(ME.message); break;
        end
        iNode=find(data.Nodes.ID==prev,1);
        jNode=find(data.Nodes.ID==next,1);
        pa=[data.Nodes.Lon(iNode),data.Nodes.Lat(iNode),data.Nodes.WorkElev(iNode)];
        pb=[data.Nodes.Lon(jNode),data.Nodes.Lat(jNode),data.Nodes.WorkElev(jNode)];
        c1=pa; c1(3)=leg.Hcruise;
        c2=pb; c2(3)=leg.Hcruise;
        [phases,cursor]=addPhase(phases,tr.TripID,"爬升",cursor,leg.T_up,pa,c1);
        [phases,cursor]=addPhase(phases,tr.TripID,"巡航",cursor,leg.T_cruise,c1,c2);
        [phases,cursor]=addPhase(phases,tr.TripID,"下降",cursor,leg.T_down,c2,pb);
        energy=energy+leg.E_total;
        if j<=numel(tr.Stops)
            use=boxes.ServiceID==next;
            duration=data.Models.HandoverBase_s(m)+data.Models.HandoverBox_s(m)*nnz(use);
            [phases,cursor]=addPhase(phases,tr.TripID,"物资投送",cursor,duration,pb,pb);
            delivered{j}=table(boxes.BoxID(use),repmat(tr.TripID,nnz(use),1), ...
                boxes.ServiceID(use),repmat(cursor,nnz(use),1), ...
                boxes.HardDeadline_s(use),boxes.ExpectedDeadline_s(use),boxes.Priority(use), ...
                'VariableNames',{'BoxID','TripID','ServiceID','Delivery_s', ...
                'HardDeadline_s','ExpectedDeadline_s','Priority'});
            payload=payload-sum(boxes.Mass_kg(use));
        end
        prev=next;
    end
    if ~allOK, break; end
    soc=1-energy/data.Models.BatteryUse_kWh(m);
    if soc<data.Models.ReserveRatio(m)-1e-9
        allOK=false; fail="运输返航 SOC 不足"; break;
    end
    charge=common.chargeTime(soc,data.Batteries.FullChargeTime_s(bi));
    droneAvail(di)=cursor;
    batteryAvail(bi)=cursor+charge;
    tripCells{k}=table(tr.TripID,data.Drones.DroneID(di),tr.Model, ...
        data.Batteries.BatteryID(bi),start,takeoff, ...
        strjoin(tr.Stops,'->'),cursor,energy,100*soc,mass,volume, ...
        'VariableNames',{'TripID','DroneID','Model','BatteryID','Start_s', ...
        'Takeoff_s','Route','Return_s','Energy_kWh','ReturnSOC_pct', ...
        'Mass_kg','Volume_m3'});
    deliveryCells{k}=vertcat(delivered{:});
    phaseCells{k}=phases;
    droneCells{k}=table(data.Drones.DroneID(di),tr.TripID,start,cursor,cursor, ...
        'VariableNames',{'ResourceID','TripID','Start_s','TaskEnd_s','Available_s'});
    batteryCells{k}=table(data.Batteries.BatteryID(bi),tr.TripID,start,cursor,cursor+charge, ...
        'VariableNames',{'ResourceID','TripID','Start_s','TaskEnd_s','Available_s'});
end
if ~allOK
    out=struct('Feasible',false,'Failure',fail);
    return;
end
trips=vertcat(tripCells{:});
deliveries=vertcat(deliveryCells{:});
if height(deliveries)~=height(data.Boxes) || ...
        numel(unique(deliveries.BoxID))~=height(data.Boxes) || ...
        ~isequal(sort(deliveries.BoxID),sort(data.Boxes.BoxID))
    out=struct('Feasible',false,'Failure',"货箱未精确覆盖"); return;
end
if any(deliveries.Delivery_s>deliveries.HardDeadline_s+1e-7)
    out=struct('Feasible',false,'Failure',"医疗或首批硬时限未满足"); return;
end
phases=[phaseCells{:}];
out=struct('Feasible',true,'Failure',"",'Trips',sortrows(trips,'Start_s'), ...
    'Deliveries',sortrows(deliveries,'BoxID'),'Phases',phases, ...
    'DroneTimeline',vertcat(droneCells{:}), ...
    'BatteryTimeline',vertcat(batteryCells{:}));
end

function [phases,cursor]=addPhase(phases,id,kind,cursor,duration,a,b)
if duration>1e-10
    row=struct('TripID',id,'PhaseIndex',numel(phases)+1,'Phase',kind, ...
        'Start_s',cursor,'End_s',cursor+duration,'A',a,'B',b);
    phases(end+1)=row; %#ok<AGROW>
end
cursor=cursor+duration;
end
