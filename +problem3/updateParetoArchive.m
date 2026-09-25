function [solutions,outcomes,status] = updateParetoArchive( ...
        solutions,outcomes,solution,outcome,maxSize)
%UPDATEPARETOARCHIVE 仅保存五目标全部可行的非支配解。
status="infeasible";
if ~outcome.Feasible, return; end
obj=outcome.Objectives;
remove=false(1,numel(outcomes));
for k=1:numel(outcomes)
    old=outcomes{k}.Objectives;
    if all(abs(old-obj)<=1e-8)
        status="duplicate"; return;
    end
    if all(old<=obj+1e-8) && any(old<obj-1e-8)
        status="dominated"; return;
    end
    if all(obj<=old+1e-8) && any(obj<old-1e-8)
        remove(k)=true;
    end
end
solutions(remove)=[]; outcomes(remove)=[];
solutions{end+1}=solution; outcomes{end+1}=outcome;
status="added";
if numel(outcomes)<=maxSize, return; end
obj=zeros(numel(outcomes),5);
for k=1:numel(outcomes), obj(k,:)=outcomes{k}.Objectives; end
n=size(obj,1); keep=false(n,1); crowd=zeros(n,1);
for j=1:5
    [v,ix]=sort(obj(:,j));
    keep(ix(1))=true;
    span=v(end)-v(1);
    if span>1e-12
        crowd(ix(2:end-1))=crowd(ix(2:end-1))+(v(3:end)-v(1:end-2))/span;
    end
end
candidate=find(~keep);
if isempty(candidate), candidate=(1:n)'; end
[~,ix]=min(crowd(candidate)); drop=candidate(ix);
if drop==n, status="pruned"; end
solutions(drop)=[]; outcomes(drop)=[];
end
