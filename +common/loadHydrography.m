function hydro = loadHydrography(options)
%LOADHYDROGRAPHY 读取水体(面)与水系(线)几何数据，返回规范结构。
%   hydro = common.loadHydrography() 从项目标准路径读取 .mat 版数据
%   （与 CSV 同内容），按要素编号分组，输出：
%     hydro.WaterBody  水体(面)多边形：每条记录一个要素
%     hydro.WaterLine  水系(线)折线：每条记录一个要素
%   二者均为 struct 数组，公共字段：
%       FeatureID 要素编号(字符串)  Type 类型  Name 名称  OsmID OSM 编号
%       Lon/Lat   顶点经度/纬度（double 列向量）
%       NumPoints 顶点数
%   其中 WaterLine 额外有 LengthKm（长度, km）。
%
%   读取口径：水体以"水体要素编号"分组（每个要素一个闭合多边形环，
%   环编号均为 1）；水系以"水系要素编号"分组（每个要素一条折线）。

if nargin < 1, options = struct(); end
paths = common.projectPaths();
geo = paths.GeoDataDir;

wbMat = fullfile(geo, '镇龙乡及周边地理数据', '水体（面）', '镇龙乡及周边水体.mat');
wlMat = fullfile(geo, '镇龙乡及周边地理数据', '水系（线）', '镇龙乡及周边水系.mat');
for f = {wbMat, wlMat}
    if ~isfile(f{1}), error('未找到水文数据：%s', f{1}); end
end

wb = load(wbMat);
wl = load(wlMat);
if ~istable(wb.data) || ~istable(wl.data)
    error('水体/水系 .mat 中的变量 data 应为 table。');
end

waterBody = parseWaterBody(wb.data);
waterLine = parseWaterLine(wl.data);

hydro = struct('WaterBody', waterBody, 'WaterLine', waterLine);
fprintf('水文数据读取完成：水体(面) %d 个要素，水系(线) %d 个要素。\n', ...
    numel(waterBody), numel(waterLine));
end

function body = parseWaterBody(T)
v = T.Properties.VariableNames;
cID    = colOf(v, '水体要素编号');
cType  = colOf(v, '水体类型');
cName  = colOf(v, '名称');
cOsm   = colOf(v, 'OSM编号');
cLon   = colOf(v, '经度');
cLat   = colOf(v, '纬度');

ids  = string(T{:, cID});
[uid, ~, ic] = unique(ids, 'stable');
nb = numel(uid);
body = struct('FeatureID', cell(nb,1), 'Type', cell(nb,1), 'Name', cell(nb,1), ...
    'OsmID', cell(nb,1), 'Lon', cell(nb,1), 'Lat', cell(nb,1), 'NumPoints', cell(nb,1));
for k = 1:nb
    m = ic == k;
    body(k).FeatureID = uid(k);
    body(k).Type       = string(T{m(1), cType});
    body(k).Name       = string(T{m(1), cName});
    body(k).OsmID      = string(T{m(1), cOsm});
    body(k).Lon        = double(T{m, cLon});
    body(k).Lat        = double(T{m, cLat});
    body(k).NumPoints  = numel(body(k).Lon);
end
end

function line = parseWaterLine(T)
v = T.Properties.VariableNames;
cID    = colOf(v, '水系要素编号');
cType  = colOf(v, '水系类型');
cName  = colOf(v, '名称');
cOsm   = colOf(v, 'OSM编号');
cLen   = colOf(v, '长度_km');
cLon   = colOf(v, '经度');
cLat   = colOf(v, '纬度');

ids  = string(T{:, cID});
[uid, ~, ic] = unique(ids, 'stable');
nl = numel(uid);
line = struct('FeatureID', cell(nl,1), 'Type', cell(nl,1), 'Name', cell(nl,1), ...
    'OsmID', cell(nl,1), 'LengthKm', cell(nl,1), 'Lon', cell(nl,1), ...
    'Lat', cell(nl,1), 'NumPoints', cell(nl,1));
for k = 1:nl
    m = ic == k;
    line(k).FeatureID = uid(k);
    line(k).Type       = string(T{m(1), cType});
    line(k).Name       = string(T{m(1), cName});
    line(k).OsmID      = string(T{m(1), cOsm});
    line(k).LengthKm   = double(T{m(1), cLen});
    line(k).Lon        = double(T{m, cLon});
    line(k).Lat        = double(T{m, cLat});
    line(k).NumPoints  = numel(line(k).Lon);
end
end

function idx = colOf(varNames, name)
idx = find(strcmp(varNames, name), 1);
if isempty(idx)
    error('common:loadHydrography:MissingColumn', '未找到列：%s', name);
end
end
