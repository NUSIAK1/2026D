function data = loadData(config)
%LOADDATA 按官方编号读取问题三输入，保留原始文件不写回。
paths = common.projectPaths();
if ~isfield(config,'FlightBaseFile'), config.FlightBaseFile = paths.FlightBaseFile; end
if ~isfield(config,'DemandFile'), config.DemandFile = paths.DemandFile; end
if ~isfield(config,'TransportUavFile'), config.TransportUavFile = paths.TransportUavFile; end
if ~isfield(config,'RelayUavFile'), config.RelayUavFile = fullfile(paths.BaseDataDir,'中继无人机数据.xlsx'); end
if ~isfield(config,'CommFile'), config.CommFile = fullfile(paths.BaseDataDir,'通信链路参数.xlsx'); end
if ~isfield(config,'DemFile'), config.DemFile = paths.DemFile; end
if ~isfile(config.FlightBaseFile)
    error('缺少 flightBase.mat；请先运行 common.computeTerrainMatrices。');
end
base = load(config.FlightBaseFile);
assert(height(base.nodes)==16 && all(ismember(["O01";compose('S%03d',(1:15)')],base.nodes.ID)), ...
    '节点编号或数量不符。');
raw = readcell(config.DemandFile,'Sheet','逐箱货箱清单');
ids = string(raw(:,1));
mask = startsWith(ids,'S') & contains(ids,'-') & ~ismissing(ids);
rows = raw(mask,:);
assert(size(rows,1)==80,'逐箱清单须恰有 80 箱。');
boxes = table(string(rows(:,1)),string(rows(:,2)),string(rows(:,3)), ...
    cell2mat(rows(:,4)),cell2mat(rows(:,5)),string(rows(:,6))=="是", ...
    localNum(rows(:,7)),localNum(rows(:,8)),cell2mat(rows(:,9)), ...
    'VariableNames',{'BoxID','ServiceID','Material','Mass_kg','Volume_m3', ...
    'IsFirst','FirstDeadline_s','ExpectedDeadline_s','Priority'});
boxes.IsMedical = boxes.Material=="医疗物资";
boxes.HardDeadline_s = inf(height(boxes),1);
boxes.HardDeadline_s(boxes.IsMedical) = boxes.ExpectedDeadline_s(boxes.IsMedical);
boxes.HardDeadline_s(boxes.IsFirst) = min(boxes.HardDeadline_s(boxes.IsFirst), ...
    boxes.FirstDeadline_s(boxes.IsFirst));
assert(numel(unique(boxes.BoxID))==80 && all(ismember(boxes.ServiceID,base.nodes.ID)) ...
    && all(isfinite(boxes.ExpectedDeadline_s) & boxes.ExpectedDeadline_s>0) ...
    && all(isfinite(boxes.Priority) & boxes.Priority>0), ...
    '货箱编号、归属、期望时间或优先系数异常。');
assert(all(isfinite(boxes.HardDeadline_s(boxes.IsFirst | boxes.IsMedical))), ...
    '首批或医疗硬截止时刻缺失。');

raw = readcell(config.TransportUavFile,'Sheet','数据');
modelMask = ismember(string(raw(:,1)),["A","B","C"]) & ...
    cellfun(@(x)isnumeric(x)&&isscalar(x)&&isfinite(x),raw(:,4));
mr = raw(modelMask,:);
assert(size(mr,1)==3,'运输机型数据异常。');
models = table(string(mr(:,1)),cell2mat(mr(:,4)),cell2mat(mr(:,5)), ...
    cell2mat(mr(:,9)),cell2mat(mr(:,10))/100,cell2mat(mr(:,11)), ...
    cell2mat(mr(:,12)),cell2mat(mr(:,13)),cell2mat(mr(:,14)), ...
    'VariableNames',{'Model','MaxPayload_kg','MaxVolume_m3','BatteryUse_kWh', ...
    'ReserveRatio','PrepTime_s','LoadTimeBox_s','HandoverBase_s','HandoverBox_s'});
droneMask = startsWith(string(raw(:,1)),"U");
drones = table(string(raw(droneMask,1)),string(raw(droneMask,2)), ...
    'VariableNames',{'DroneID','Model'});
assert(height(drones)==8 && numel(unique(drones.DroneID))==8,'运输实体机清单异常。');
batteryRows = raw(ismember(string(raw(:,1)),["A","B","C"]) & ...
    cellfun(@(x)isnumeric(x)&&isscalar(x)&&isfinite(x),raw(:,2)),:);
bID = strings(0,1); bModel = strings(0,1); bFull = zeros(0,1);
for i=1:size(batteryRows,1)
    for k=1:batteryRows{i,2}
        bID(end+1,1) = sprintf('BAT-%s%02d',string(batteryRows{i,1}),k); %#ok<AGROW>
        bModel(end+1,1) = string(batteryRows{i,1}); %#ok<AGROW>
        bFull(end+1,1) = batteryRows{i,3}; %#ok<AGROW>
    end
end
batteries = table(bID,bModel,bFull,'VariableNames', ...
    {'BatteryID','Model','FullChargeTime_s'});

raw = readcell(config.RelayUavFile,'Sheet','数据');
rr = raw(find(string(raw(:,1))=="R" & ...
    cellfun(@(x)isnumeric(x)&&isscalar(x)&&isfinite(x),raw(:,5)),1),:);
assert(size(rr,1)==1,'中继机型 R 参数异常。');
relay = struct('Model',"R",'Mass_kg',rr{5},'CruiseSpeed_mps',rr{6}, ...
    'CruisePower_kW',rr{7},'Use_kWh',rr{8},'ReserveRatio',rr{9}/100, ...
    'PrepTime_s',rr{10},'LinkTime_s',rr{11},'TurnTime_s',rr{12}, ...
    'ClimbSpeed_mps',rr{13},'DescSpeed_mps',rr{14},'ClimbEfficiency',rr{15}, ...
    'HoverPower_kW',rr{17},'CommPower_kW',rr{18},'MaxAGL_m',rr{19});
relayIDs = string(raw(startsWith(string(raw(:,1)),"R0"),1));
assert(numel(relayIDs)==2 && numel(unique(relayIDs))==2,'中继实体机清单异常。');
stockRow = find(string(raw(:,1))=="R" & ...
    cellfun(@(x)isnumeric(x)&&isscalar(x)&&isfinite(x),raw(:,2)),1);
assert(~isempty(stockRow),'中继能源组件库存缺失。');
relay.ComponentCount = raw{stockRow,2};
relay.FullChargeTime_s = raw{stockRow,3};
relay.DroneIDs = relayIDs;
relay.ComponentIDs = string(compose('RC%02d',(1:relay.ComponentCount)'));

raw = readcell(config.CommFile,'Sheet','数据');
header = string(raw(2,:));
symCol = find(header=="符号",1); valCol = find(header=="参数值",1);
assert(~isempty(symCol) && ~isempty(valCol),'通信表符号或参数值表头缺失。');
comm = struct();
comm.Frequency_MHz = getParam(raw,symCol,valCol,"传播参数","f");
comm.SystemLoss_dB = getParam(raw,symCol,valCol,"传播参数","Lsys");
comm.ObstacleLoss_dB = getParam(raw,symCol,valCol,"传播参数","Lobs");
comm.Sensitivity_dBm = getParam(raw,symCol,valCol,"接收参数","Psens");
comm.FadeMargin_dB = getParam(raw,symCol,valCol,"接收参数","M");
comm.GatewayAGL_m = getParam(raw,symCol,valCol,"固定网关 G01","hG");
names = ["运输无人机","中继接入端","中继回传端","固定网关 G01"];
for i=1:4
    comm.Tx_dBm(i) = getParam(raw,symCol,valCol,names(i),"Pt");
    comm.Gain_dBi(i) = getParam(raw,symCol,valCol,names(i),"G");
end

demRaw = load(config.DemFile);
assert(double(demRaw.epsg_code(1))==4326,'DEM 必须为 EPSG:4326。');
Z = double(demRaw.dem);
Z(Z==double(demRaw.nodata(1)))=NaN;
lat=double(demRaw.latitude(:)); lon=double(demRaw.longitude(:));
if lat(1)>lat(end), lat=flipud(lat); Z=flipud(Z); end
if lon(1)>lon(end), lon=flipud(lon); Z=fliplr(Z); end
assert(numel(lat)==size(Z,1) && numel(lon)==size(Z,2),'DEM 坐标与矩阵尺寸不符。');
dem = struct('Z',Z,'Lat',lat,'Lon',lon,'dLat',mean(diff(lat)), ...
    'dLon',mean(diff(lon)));

data = struct('FlightBase',base,'Nodes',base.nodes,'Boxes',boxes, ...
    'Models',models,'Drones',drones,'Batteries',batteries, ...
    'Relay',relay,'Comm',comm,'Dem',dem);
end

function values = localNum(c)
values = nan(numel(c),1);
for i=1:numel(c)
    if isnumeric(c{i}) && isscalar(c{i}) && isfinite(c{i})
        values(i)=c{i};
    end
end
end

function x = getParam(raw,symCol,valCol,category,symbol)
row = find(string(raw(:,1))==category & string(raw(:,symCol))==symbol);
assert(numel(row)==1 && isnumeric(raw{row,valCol}) && isfinite(raw{row,valCol}), ...
    '通信参数 %s/%s 缺失或重复。',category,symbol);
x = raw{row,valCol};
end
