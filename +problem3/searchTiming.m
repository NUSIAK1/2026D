function result = searchTiming(seed,data,config)
%SEARCHTIMING 在运输硬时限内联合调整出发顺序和中继时序。
if ~isfield(config,'TimingIterations'), config.TimingIterations=2500; end
if ~isfield(config,'RandomSeed'), config.RandomSeed=2026; end
if ~isfield(config,'TimeLimit_s'), config.TimeLimit_s=3600; end
if ~isfield(config,'RelayBeamWidth'), config.RelayBeamWidth=36; end
rng(config.RandomSeed,'twister');
base=problem3.decodeTransport(seed,data);
if ~base.Feasible
    result=struct('Feasible',false,'Failure',base.Failure,'Iterations',0); return;
end
clock=tic;
first=problem3.planCertifiedRelay(base,data,config);
if first.Feasible
    initialCert=problem3.certifyCoverage(base,first.RelayTrips,data,config);
    if initialCert.Feasible
        result=struct('Feasible',true,'Solution',seed,'Transport',base, ...
            'Relay',first,'Coverage',initialCert.Coverage,'Iterations',0, ...
            'PointFeasibleCount',1,'Accepted',0,'Elapsed_s',0,'Failure',"");
        return;
    end
end
pre=first.Precompute;
config.RelayPrecompute=pre;
current=seed; currentRelay=first;
best=seed; bestTransport=base; bestRelay=first;
bestScore=score(first);
accepted=0; feasiblePoint=0; it=0;
for it=1:config.TimingIterations
    if toc(clock)>=config.TimeLimit_s, break; end
    if mod(it,150)==1 && it>1
        current=best; currentRelay=bestRelay;
    end
    trial=mutate(current,currentRelay);
    if isequaln(trial,current), continue; end
    transport=problem3.decodeTransport(trial,data);
    if ~transport.Feasible, continue; end
    relay=problem3.planCertifiedRelay(transport,data,config);
    s=score(relay);
    if s>bestScore+1e-9
        best=trial; bestTransport=transport; bestRelay=relay; bestScore=s;
        if isfield(config,'Verbose') && config.Verbose
            fprintf('[Q3] 时序迭代 %d：最早未覆盖 %.1f s，剩余 %d 点。\n', ...
                it,uncoveredTime(relay),uncoveredCount(relay));
        end
    end
    temperature=0.05*(1-it/config.TimingIterations)+0.001;
    if s>=score(currentRelay) || rand<temperature
        current=trial; currentRelay=relay; accepted=accepted+1;
    end
    if relay.Feasible
        feasiblePoint=feasiblePoint+1;
        cert=problem3.certifyCoverage(transport,relay.RelayTrips,data,config);
        if cert.Feasible
            result=struct('Feasible',true,'Solution',trial,'Transport',transport, ...
                'Relay',relay,'Coverage',cert.Coverage,'Iterations',it, ...
                'PointFeasibleCount',feasiblePoint,'Accepted',accepted, ...
                'Elapsed_s',toc(clock),'Failure',"");
            return;
        end
    end
end
result=struct('Feasible',false,'Solution',best,'Transport',bestTransport, ...
    'Relay',bestRelay,'Coverage',table(),'Iterations',it, ...
    'PointFeasibleCount',feasiblePoint,'Accepted',accepted, ...
    'Elapsed_s',toc(clock),'Failure',bestRelay.Failure);
end

function s=score(relay)
if relay.Feasible, s=1e10; return; end
if ~isfield(relay,'Uncovered') || isempty(relay.Uncovered)
    s=-1e9; return;
end
s=relay.Uncovered.Time_s(1)-0.1*height(relay.Uncovered);
end

function t=uncoveredTime(relay)
if relay.Feasible, t=inf; else, t=relay.Uncovered.Time_s(1); end
end

function n=uncoveredCount(relay)
if relay.Feasible, n=0; else, n=height(relay.Uncovered); end
end

function trial=mutate(solution,relay)
trial=solution; n=numel(trial.Trips);
if isfield(relay,'Uncovered') && ~isempty(relay.Uncovered)
    targetID=relay.Uncovered.TripID(1);
    target=find([trial.Trips.TripID]==targetID,1);
else
    target=randi(n);
end
if isempty(target), target=randi(n); end
j=randi(n); op=randi(7);
switch op
    case 1
        trial.Trips(target).RequestedStart_s=max(0, ...
            trial.Trips(target).RequestedStart_s+(rand*2-1)*900);
    case 2
        trial.Trips(target).RequestedStart_s=max(0, ...
            trial.Trips(target).RequestedStart_s+100+rand*900);
    case 3
        trial.Trips(target).RequestedStart_s=max(0, ...
            trial.Trips(target).RequestedStart_s-100-rand*900);
    case 4
        tmp=trial.Trips(target).RequestedStart_s;
        trial.Trips(target).RequestedStart_s=trial.Trips(j).RequestedStart_s;
        trial.Trips(j).RequestedStart_s=tmp;
    case 5
        trial.Trips(j).RequestedStart_s=max(0, ...
            trial.Trips(j).RequestedStart_s+(rand*2-1)*1400);
    case 6
        trial.Trips(target).RequestedStart_s=max(0,trial.Trips(j).RequestedStart_s-30+60*rand);
    otherwise
        for k=1:n
            if rand<0.2
                trial.Trips(k).RequestedStart_s=max(0, ...
                    trial.Trips(k).RequestedStart_s+300*randn);
            end
        end
end
end
