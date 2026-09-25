function [solutions,outcomes,status] = updateParetoArchive( ...
        solutions,outcomes,solution,outcome,maxSize)
%UPDATEPARETOARCHIVE 维护四目标可行非支配解档案。

status = "infeasible";
if ~outcome.Feasible, return; end
obj = outcome.Objectives;
remove = false(1,numel(outcomes));
for k = 1:numel(outcomes)
    old = outcomes{k}.Objectives;
    if all(abs(old-obj) <= 1e-9)
        status = "duplicate";
        return;
    end
    if all(old <= obj+1e-9) && any(old < obj-1e-9)
        status = "dominated";
        return;
    end
    if all(obj <= old+1e-9) && any(obj < old-1e-9)
        remove(k) = true;
    end
end
solutions(remove) = []; outcomes(remove) = [];
solutions{end+1} = solution; outcomes{end+1} = outcome;
status = "added";
if numel(outcomes) <= maxSize, return; end

allObj = zeros(numel(outcomes),4);
for k = 1:numel(outcomes)
    allObj(k,:) = outcomes{k}.Objectives;
end
drop = crowdingDrop(allObj);
if drop == numel(outcomes), status = "pruned"; end
solutions(drop) = []; outcomes(drop) = [];
end

function drop = crowdingDrop(obj)
% 保留每个目标的极值点，删除拥挤距离最小的内部点。
n = size(obj,1);
protected = false(n,1);
crowd = zeros(n,1);
for j = 1:size(obj,2)
    [v,ix] = sort(obj(:,j));
    protected(ix(1)) = true;
    protected(ix(end)) = true;
    span = v(end)-v(1);
    if span < 1e-12, continue; end
    crowd(ix(2:end-1)) = crowd(ix(2:end-1)) + ...
        (v(3:end)-v(1:end-2))/span;
end
candidate = find(~protected);
if isempty(candidate), candidate = (1:n).'; end
[~,p] = min(crowd(candidate));
drop = candidate(p);
end
