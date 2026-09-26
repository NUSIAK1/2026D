function sparse = compressGaps(gaps,sampleStep_s,planningStep_s)
%COMPRESSGAPS 保留每个失联片段的两端和内部代表点；最终仍作连续认证。
% 密集直连筛选为 sampleStep_s；仅压缩中继搜索状态，不能作为验收依据。
if isempty(gaps) || planningStep_s<=sampleStep_s, sparse=gaps; return; end
keep=false(height(gaps),1);
[~,~,group]=unique(gaps(:,{'TripID','PhaseIndex'}),'rows');
for k=1:max(group)
    ids=find(group==k);
    [~,ord]=sort(gaps.Time_s(ids)); ids=ids(ord);
    t=gaps.Time_s(ids);
    starts=[1;find(diff(t)>sampleStep_s+1e-6)+1];
    ends=[starts(2:end)-1;numel(t)];
    for j=1:numel(starts)
        first=starts(j); last=ends(j); previous=first;
        keep(ids([first,last]))=true;
        for h=first+1:last-1
            if t(h)-t(previous)>=planningStep_s
                keep(ids(h))=true; previous=h;
            end
        end
    end
end
sparse=gaps(keep,:);
end
