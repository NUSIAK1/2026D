function seeds = loadSeeds(config,data)
%LOADSEEDS 从问题二正式提交簿构造可重排程的运输初始解。
labels=["及时性优先","完成时间优先","能耗优先","架次数优先","折中方案"];
% 输入与输出独立；独立优化入口必须显式指定问题二来源。
if ~isfield(config,'SeedResultDir'), config.SeedResultDir=config.ResultDir; end
seeds={};
for i=1:numel(labels)
    file=fullfile(config.SeedResultDir,"问题二_结果提交_"+labels(i)+".xlsx");
    if ~isfile(file), continue; end
    try
        tr=readcell(file,'Sheet','Q2_运输架次');
        de=readcell(file,'Sheet','Q2_逐箱交付');
        tr=tr(2:end,:); de=de(2:end,:);
        tr=tr(~ismissing(string(tr(:,1))) & string(tr(:,1))~="",:);
        de=de(~ismissing(string(de(:,1))) & string(de(:,1))~="",:);
        assert(size(de,1)==height(data.Boxes) && ...
            isequal(sort(string(de(:,1))),sort(data.Boxes.BoxID)), ...
            '逐箱记录未精确覆盖原始货箱。');
        trips=repmat(struct('TripID',"",'BoxIDs',strings(0,1), ...
            'Stops',strings(0,1),'Model',"",'RequestedStart_s',0),size(tr,1),1);
        for k=1:size(tr,1)
            id=string(tr{k,1});
            boxIDs=string(de(string(de(:,2))==id,1));
            assert(~isempty(boxIDs),'架次没有对应货箱。');
            trips(k).TripID=id;
            trips(k).BoxIDs=boxIDs;
            trips(k).Stops=split(string(tr{k,6}),"->");
            trips(k).Model=string(tr{k,3});
            trips(k).RequestedStart_s=double(tr{k,5});
        end
        solution=struct('Trips',trips,'Source',labels(i));
        seeds{end+1}=solution; %#ok<AGROW>
    catch ME
        warning('忽略问题二初始解 %s：%s',file,ME.message);
    end
end
if ~isempty(seeds)
    % 从组批出发构造单服务区路线，作为与问题二排程不同的独立候选。
    source=seeds{1}; newTrips=source.Trips([]);
    for k=1:numel(source.Trips)
        tr=source.Trips(k);
        for j=1:numel(tr.Stops)
            b=data.Boxes(ismember(data.Boxes.BoxID,tr.BoxIDs) & ...
                data.Boxes.ServiceID==tr.Stops(j),:);
            if isempty(b), continue; end
            x=tr; x.BoxIDs=b.BoxID; x.Stops=tr.Stops(j);
            x.TripID=string(sprintf('T%03d',numel(newTrips)+1));
            newTrips(end+1,1)=x; %#ok<AGROW>
        end
    end
    seeds{end+1}=struct('Trips',newTrips,'Source',"单服务区重排程");
end
if isempty(seeds)
    error('未找到可读取的问题二提交簿；需要先运行问题二或提供初始解。');
end
end
