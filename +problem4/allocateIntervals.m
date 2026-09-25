function allocation = allocateIntervals(tripID,start_s,available_s,tolerance_s)
%ALLOCATEINTERVALS 半开区间最优着色。返回峰值、证据及每任务槽位。
if nargin<4, tolerance_s=1e-7; end
tripID=string(tripID(:)); start_s=double(start_s(:));
available_s=double(available_s(:));
n=numel(tripID);
assert(numel(start_s)==n && numel(available_s)==n && ...
    all(isfinite(start_s)) && all(isfinite(available_s)) && ...
    all(available_s>=start_s-tolerance_s), ...
    '资源占用区间无效。');
assert(numel(unique(tripID))==n,'资源任务编号重复。');
slot=zeros(n,1); slotFree=zeros(0,1); peak=0;
peakTime=NaN; witness=strings(0,1);
[~,order]=sortrows([start_s,(1:n)']);
for h=1:n
    i=order(h);
    reusable=find(slotFree<=start_s(i)+tolerance_s,1);
    if isempty(reusable)
        slotFree(end+1,1)=available_s(i); %#ok<AGROW>
        reusable=numel(slotFree);
    else
        slotFree(reusable)=available_s(i);
    end
    slot(i)=reusable;
    active=start_s<=start_s(i)+tolerance_s & ...
        available_s>start_s(i)+tolerance_s;
    if nnz(active)>peak
        peak=nnz(active); peakTime=start_s(i); witness=tripID(active);
    end
end
assert(numel(slotFree)==peak,'区间着色数与同时占用峰值不一致。');
allocation=struct('Slot',slot,'Required',peak,'PeakTime_s',peakTime, ...
    'WitnessTrips',witness);
end
