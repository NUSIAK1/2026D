function [candidate,geometryChanged,op] = perturbSolution(solution,data,criticalTrip,op)
%PERTURBSOLUTION ALNS 邻域：时序、路线、机型与货箱组批。
candidate=solution;
n=numel(candidate.Trips);
if nargin<3 || criticalTrip=="", criticalTrip=candidate.Trips(randi(n)).TripID; end
i=find([candidate.Trips.TripID]==criticalTrip,1);
if isempty(i), i=randi(n); end
j=randi(n);
geometryChanged=false;
if nargin<4 || isempty(op)
    draw=randi(100);
    if draw<=90
        op=randi(7);
    elseif draw<=93
        op=8;
    elseif draw<=95
        op=9;
    elseif draw<=97
        op=10;
    elseif draw<=99
        op=11;
    else
        op=12;
    end
end
switch op
    case {1,2,3,4,5,6,7}
        if op==1, delta=(rand*2-1)*1000;
        elseif op==2, delta=100+rand*1200;
        elseif op==3, delta=-100-rand*1200;
        elseif op==4, delta=(rand*2-1)*1800;
        elseif op==5, delta=-candidate.Trips(i).RequestedStart_s;
        else, delta=(rand*2-1)*600; end
        if op==6
            candidate.Trips(j).RequestedStart_s=max(0, ...
                candidate.Trips(j).RequestedStart_s+delta);
        elseif op==7
            x=candidate.Trips(i).RequestedStart_s;
            candidate.Trips(i).RequestedStart_s=candidate.Trips(j).RequestedStart_s;
            candidate.Trips(j).RequestedStart_s=x;
        else
            candidate.Trips(i).RequestedStart_s=max(0, ...
                candidate.Trips(i).RequestedStart_s+delta);
        end
    case 8
        if numel(candidate.Trips(i).Stops)>1
            candidate.Trips(i).Stops=flipud(candidate.Trips(i).Stops);
            geometryChanged=true;
        end
    case 9
        candidate.Trips(i).Model=data.Models.Model(randi(height(data.Models)));
        geometryChanged=true;
    case 10
        if n>1 && i~=j && ~isempty(candidate.Trips(i).BoxIDs)
            boxes=candidate.Trips(i).BoxIDs;
            b=boxes(randi(numel(boxes)));
            candidate.Trips(i).BoxIDs(boxes==b)=[];
            candidate.Trips(j).BoxIDs(end+1,1)=b;
            candidate=normalize(candidate,data);
            geometryChanged=true;
        end
    case 11
        if n>1 && i~=j
            candidate.Trips(i).BoxIDs=[candidate.Trips(i).BoxIDs;candidate.Trips(j).BoxIDs];
            candidate.Trips(i).Stops=unique([candidate.Trips(i).Stops;candidate.Trips(j).Stops],'stable');
            candidate.Trips(j)=[];
            candidate=normalize(candidate,data);
            geometryChanged=true;
        end
    case 12
        boxes=candidate.Trips(i).BoxIDs;
        if numel(boxes)>1
            ids=boxes(randperm(numel(boxes),max(1,floor(numel(boxes)/2))));
            candidate.Trips(i).BoxIDs=boxes(~ismember(boxes,ids));
            new=candidate.Trips(i);
            new.BoxIDs=ids; new.RequestedStart_s=max(0,new.RequestedStart_s+150*randn);
            candidate.Trips(end+1)=new;
            candidate=normalize(candidate,data);
            geometryChanged=true;
        end
end
end

function solution=normalize(solution,data)
keep=arrayfun(@(x)~isempty(x.BoxIDs),solution.Trips);
solution.Trips=solution.Trips(keep);
for k=1:numel(solution.Trips)
    tr=solution.Trips(k);
    services=data.Boxes.ServiceID(ismember(data.Boxes.BoxID,tr.BoxIDs));
    order=unique(tr.Stops(:),'stable');
    order=order(ismember(order,services));
    remaining=unique(services(~ismember(services,order)),'stable');
    solution.Trips(k).Stops=[order;remaining];
    solution.Trips(k).TripID=string(sprintf('T%03d',k));
end
end
