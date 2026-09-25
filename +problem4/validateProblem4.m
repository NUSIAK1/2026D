function report=validateProblem4(result,rep,data)
%VALIDATEPROBLEM4 独立复查分区、任务继承、占用区间与最少资源。
checks=strings(0,1); passed=false(0,1); details=strings(0,1);
    function add(label,ok,detail)
        checks(end+1,1)=label; passed(end+1,1)=logical(ok); %#ok<AGROW>
        details(end+1,1)=detail; %#ok<AGROW>
    end
add("问题三基线",result.SourceCheck.Feasible && ...
    result.BaselineCheck.Feasible,"档案与提交簿一致，原方案独立校核通过");
T=rep.Transport.Trips; R=rep.Relay.RelayTrips; D=rep.Transport.Deliveries;
services=compose('S%03d',(1:15)');
assert(height(T)==22 && height(R)==3 && height(D)==80);
types=result.Baseline.Type;
for c=1:numel(result.Candidates)
    item=result.Candidates(c); pid=item.ID;
    groups=item.Group;
    serviceList=strings(0,1); tripGroup=containers.Map('KeyType','char','ValueType','double');
    relayGroup=containers.Map('KeyType','char','ValueType','double');
    for g=1:height(groups)
        ss=split(groups.Services(g),',');
        serviceList=[serviceList;ss]; %#ok<AGROW>
        tripIDs=strings(0,1);
        for j=1:height(T)
            route=split(T.Route(j),'->');
            if any(ismember(route,ss))
                assert(all(ismember(route,ss)), ...
                    '分区 %s 的运输架次跨组。',pid);
                tripIDs(end+1,1)=T.TripID(j); %#ok<AGROW>
                tripGroup(char(T.TripID(j)))=g;
            end
        end
        relayIDs=strings(0,1);
        for j=1:height(R)
            refs=rep.Coverage.TripID(rep.Coverage.Mode=="中继" & ...
                rep.Coverage.RelayTripID==R.RelayTripID(j));
            if any(ismember(refs,tripIDs))
                assert(all(ismember(refs,tripIDs)), ...
                    '分区 %s 的中继保障关系跨组。',pid);
                relayIDs(end+1,1)=R.RelayTripID(j); %#ok<AGROW>
                relayGroup(char(R.RelayTripID(j)))=g;
            end
        end
        boxMask=ismember(D.TripID,tripIDs);
        mass=sum(data.Boxes.Mass_kg(ismember(data.Boxes.BoxID,D.BoxID(boxMask))));
        ti=T(ismember(T.TripID,tripIDs),:);
        ri=R(ismember(R.RelayTripID,relayIDs),:);
        work=sum(ti.Return_s-ti.Start_s)+sum(ri.Return_s-ri.Start_s);
        add(pid+" 组"+g+"工作量", ...
            groups.TransportTrips(g)==height(ti) && ...
            groups.RelayTrips(g)==height(ri) && ...
            groups.BoxCount(g)==nnz(boxMask) && ...
            abs(groups.Mass_kg(g)-mass)<1e-8 && ...
            abs(groups.Work_s(g)-work)<1e-7, ...
            "组内架次、货箱、质量与作业时间重算一致");
    end
    add(pid+" 服务区覆盖",numel(serviceList)==15 && ...
        isequal(sort(serviceList),sort(services)) && height(groups)==item.K, ...
        "15 个服务区恰好入组一次");
    add(pid+" 任务继承",tripGroup.Count==height(T) && ...
        relayGroup.Count==height(R),"原运输和中继架次完整且唯一归组");
    A=item.Allocation; Q=item.Resource;
    for j=1:numel(types)
        typ=types(j);
        counts=Q.Required(Q.Type==typ);
        add(pid+" "+typ+"配置",sum(counts)==item.Totals(j) && ...
            item.Deficit(j)==max(0,item.Totals(j)-result.Baseline.Inventory(j)) && ...
            item.Extra(j)==item.Totals(j)-result.Baseline.NoPartitionRequired(j), ...
            "数量、缺口和分区增量一致");
    end
    for j=1:height(Q)
        q=Q(j,:);
        a=A(A.GroupID==q.GroupID & A.Type==q.Type,:);
        required=q.Required;
        if required==0
            ok=isempty(a) && isnan(q.Peak_s);
        else
            witness=problem4.allocateIntervals(a.TripID,a.Start_s,a.Available_s);
            ok=witness.Required==required && ...
                numel(unique(a.AssignedResourceID))==required && ...
                abs(witness.PeakTime_s-q.Peak_s)<1e-7;
            ids=unique(a.AssignedResourceID);
            for m=1:numel(ids)
                own=sortrows(a(a.AssignedResourceID==ids(m),:),'Start_s');
                ok=ok && ~any(own.Start_s(2:end)< ...
                    own.Available_s(1:end-1)-1e-7);
            end
            for m=1:height(a)
                if startsWith(q.Type,"R_")
                    ix=find(R.RelayTripID==a.TripID(m),1);
                    ok=ok && ~isempty(ix) && ...
                        relayGroup(char(a.TripID(m)))==q.GroupID;
                    if q.Type=="R_U"
                        expected=R.Return_s(ix)+data.Relay.TurnTime_s;
                        original=R.RelayID(ix);
                    else
                        expected=R.Return_s(ix)+common.chargeTime( ...
                            R.ReturnSOC_pct(ix)/100,data.Relay.FullChargeTime_s);
                        original=R.ComponentID(ix);
                    end
                else
                    ix=find(T.TripID==a.TripID(m),1);
                    ok=ok && ~isempty(ix) && ...
                        tripGroup(char(a.TripID(m)))==q.GroupID && ...
                        T.Model(ix)==extractBefore(q.Type,'_');
                    if endsWith(q.Type,'_U')
                        expected=T.Return_s(ix); original=T.DroneID(ix);
                    else
                        bi=find(data.Batteries.Model==T.Model(ix),1);
                        expected=T.Return_s(ix)+common.chargeTime( ...
                            T.ReturnSOC_pct(ix)/100, ...
                            data.Batteries.FullChargeTime_s(bi));
                        original=T.BatteryID(ix);
                    end
                end
                ok=ok && abs(a.Start_s(m)- ...
                    getStart(a.TripID(m),T,R))<1e-7 && ...
                    abs(a.Available_s(m)-expected)<1e-6 && ...
                    a.OriginalResourceID(m)==original;
            end
        end
        add(pid+" G"+q.GroupID+" "+q.Type,ok, ...
            "最少槽位数等于占用峰值，任务时间与原档案一致");
    end
    ids=unique(A.AssignedResourceID);
    independent=true;
    for j=1:numel(ids)
        x=A(A.AssignedResourceID==ids(j),:);
        if numel(unique(x.GroupID))~=1 || numel(unique(x.Type))~=1
            independent=false; break;
        end
    end
    add(pid+" 资源独立",independent,"各实体资源只属于一个组和一种类型");
end
report=struct('Feasible',all(passed),'Checks', ...
    table(checks,passed,details, ...
    'VariableNames',{'Check','Passed','Details'}));
end

function start=getStart(id,T,R)
if startsWith(id,'T'), start=T.Start_s(T.TripID==id);
else, start=R.Start_s(R.RelayTripID==id); end
end
