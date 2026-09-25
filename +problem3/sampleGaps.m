function gaps = sampleGaps(transport,data,step_s)
%SAMPLEGAPS 以点态链路筛选中继需求；最终可行性仍由区间认证决定。
if nargin<3, step_s=30; end
gateway=gatewayPoint(data);
rows=cell(numel(transport.Phases),1);
for i=1:numel(transport.Phases)
    p=transport.Phases(i);
    t=linspace(p.Start_s,p.End_s,max(2,ceil((p.End_s-p.Start_s)/step_s)+1));
    x=zeros(0,3); tt=zeros(0,1);
    for j=1:numel(t)
        xyz=problem3.positionAt(p,t(j));
        state=problem3.linkState(xyz,gateway,"direct",data);
        if ~state.Available
            x(end+1,:)=xyz; tt(end+1,1)=t(j); %#ok<AGROW>
        end
    end
    if ~isempty(tt)
        rows{i}=table(repmat(p.TripID,numel(tt),1),repmat(p.PhaseIndex,numel(tt),1), ...
            tt,x(:,1),x(:,2),x(:,3), ...
            'VariableNames',{'TripID','PhaseIndex','Time_s','Lon','Lat','Alt_m'});
    end
end
rows=rows(~cellfun(@isempty,rows));
if isempty(rows)
    gaps=table(strings(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1),zeros(0,1), ...
        'VariableNames',{'TripID','PhaseIndex','Time_s','Lon','Lat','Alt_m'});
else
    gaps=sortrows(vertcat(rows{:}),'Time_s');
end
end

function p=gatewayPoint(data)
i=find(data.Nodes.ID=="O01",1);
p=[data.Nodes.Lon(i),data.Nodes.Lat(i), ...
    data.Nodes.GroundElev(i)+data.Comm.GatewayAGL_m];
end
