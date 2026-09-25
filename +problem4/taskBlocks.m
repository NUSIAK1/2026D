function blocks = taskBlocks(rep)
%TASKBLOCKS 运输同架次及中继同架次的服务区构成不可拆连通分量。
services=compose('S%03d',(1:15)');
parent=1:numel(services);
trips=rep.Transport.Trips;
relay=rep.Relay.RelayTrips;
coverage=rep.Coverage;
tripStops=cell(height(trips),1);
for k=1:height(trips)
    stop=split(string(trips.Route(k)),'->');
    stop=stop(stop~="");
    assert(~isempty(stop) && all(ismember(stop,services)), ...
        '运输架次 %s 的服务区路线无效。',trips.TripID(k));
    tripStops{k}=stop;
    unite(stop);
end
for k=1:height(relay)
    refs=unique(coverage.TripID(coverage.Mode=="中继" & ...
        coverage.RelayTripID==relay.RelayTripID(k)));
    assert(~isempty(refs),'中继架次 %s 没有保障记录。',relay.RelayTripID(k));
    stops=strings(0,1);
    for j=1:numel(refs)
        ix=find(trips.TripID==refs(j),1);
        assert(~isempty(ix),'保障记录引用未知运输架次。');
        stops=[stops;tripStops{ix}]; %#ok<AGROW>
    end
    unite(unique(stops));
end
root=zeros(numel(services),1);
for k=1:numel(services), root(k)=findRoot(k); end
uniqueRoots=unique(root,'stable');
blocks=struct('BlockID',{},'Services',{},'TripIDs',{},'RelayTripIDs',{});
for b=1:numel(uniqueRoots)
    members=services(root==uniqueRoots(b));
    tripIDs=strings(0,1);
    for k=1:height(trips)
        if ismember(tripStops{k}(1),members)
            assert(all(ismember(tripStops{k},members)));
            tripIDs(end+1,1)=trips.TripID(k); %#ok<AGROW>
        end
    end
    relayIDs=strings(0,1);
    for k=1:height(relay)
        refs=coverage.TripID(coverage.Mode=="中继" & ...
            coverage.RelayTripID==relay.RelayTripID(k));
        if any(ismember(refs,tripIDs))
            assert(all(ismember(refs,tripIDs)), ...
                '中继任务跨越不可拆任务块。');
            relayIDs(end+1,1)=relay.RelayTripID(k); %#ok<AGROW>
        end
    end
    blocks(b)=struct('BlockID',"B"+b,'Services',{members}, ...
        'TripIDs',{tripIDs},'RelayTripIDs',{relayIDs}); %#ok<AGROW>
end
    function r=findRoot(i)
        r=i;
        while parent(r)~=r, r=parent(r); end
        while parent(i)~=i
            next=parent(i); parent(i)=r; i=next;
        end
    end
    function unite(ids)
        if isempty(ids), return; end
        [found,idx]=ismember(ids,services);
        assert(all(found));
        a=findRoot(idx(1));
        for t=2:numel(idx)
            c=findRoot(idx(t));
            parent(c)=a;
        end
    end
end
