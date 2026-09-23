%% compute_terrain_matrices.m
% 计算节点间的基础几何/地形参数矩阵：
%   D            Haversine 水平距离 (m)
%   HterrainMax  航线所经过 DEM 像元的最高地面高程 (m)
%   Hcruise      计划巡航海拔 = HterrainMax + 50 (m)
%   Hup          起点作业海拔 -> 巡航海拔 的爬升高度 (m)
%   Hdown        终点作业海拔 -> 巡航海拔 的下降高度 (m)
%
% 结果会保存到当前目录下的 flightBase.mat，供 calcLegCost.m 调用。
%
% 数据文件（调度中心与服务区.xlsx / 运输无人机数据.xlsx /
% 镇龙乡及周边30米DEM.mat）在当前目录的上层目录中递归搜索。

clear; clc; close all;

%% ========================================================================
% 0. 用户输入区
% ========================================================================
startID = "O01";     % 起点：O01 或 S001~S015
endID   = "S001";    % 终点：O01 或 S001~S015

writeResultXlsx = true;
resultFile  = fullfile('..', '结果', '节点间无人机运输基础参数.xlsx');
baseMatFile = 'flightBase.mat';

%% ========================================================================
% 1. 递归搜索数据文件
% ========================================================================
currentDir = pwd;
rootDir    = fileparts(currentDir);

nodeTarget = '调度中心与服务区.xlsx';
uavTarget  = '运输无人机数据.xlsx';
demTarget  = '镇龙乡及周边30米DEM.mat';

nodeList = dir(fullfile(rootDir, '**', nodeTarget));
uavList  = dir(fullfile(rootDir, '**', uavTarget));
demList  = dir(fullfile(rootDir, '**', demTarget));

if isempty(nodeList), error('未找到：%s', nodeTarget); end
if isempty(uavList),  error('未找到：%s', uavTarget);  end
if isempty(demList),  error('未找到：%s', demTarget);  end

if numel(nodeList) > 1
    warning('发现多个 %s，使用第一个。', nodeTarget);
end
if numel(uavList) > 1
    warning('发现多个 %s，使用第一个。', uavTarget);
end
if numel(demList) > 1
    warning('发现多个 %s，使用第一个。', demTarget);
end

nodeFile = fullfile(nodeList(1).folder, nodeList(1).name);
uavFile  = fullfile(uavList(1).folder,  uavList(1).name);
demFile  = fullfile(demList(1).folder,  demList(1).name);

fprintf('当前工作目录：%s\n', rootDir);
fprintf('节点文件：%s\n', nodeFile);
fprintf('无人机参数：%s\n', uavFile);
fprintf('DEM 文件：%s\n\n', demFile);

%% ========================================================================
% 2. 读取调度中心与服务区数据
% ========================================================================
nodeRaw = readcell(nodeFile, 'Sheet', '数据');

idAll    = string(nodeRaw(:,1));
nodeMask = (idAll == "O01") | startsWith(idAll, "S");

nodeID   = string(nodeRaw(nodeMask, 1));
nodeName = string(nodeRaw(nodeMask, 2));
nodeLon  = cell2mat(nodeRaw(nodeMask, 3));
nodeLat  = cell2mat(nodeRaw(nodeMask, 4));
nodeElev = cell2mat(nodeRaw(nodeMask, 5));

nodePop = zeros(sum(nodeMask),1);
popCell = nodeRaw(nodeMask, 6);
for k = 1:numel(popCell)
    if isnumeric(popCell{k}) && isscalar(popCell{k}) && ~isnan(popCell{k})
        nodePop(k) = popCell{k};
    end
end

nodes = table(nodeID, nodeName, nodeLon, nodeLat, nodeElev, nodePop, ...
    'VariableNames', {'ID','Name','Lon','Lat','GroundElev','Pop'});

% 作业海拔：O01 = 地面海拔；服务区 = 地面海拔 + 30 m
nodes.WorkElev = nodes.GroundElev;
isService = startsWith(nodes.ID, "S");
nodes.WorkElev(isService) = nodes.GroundElev(isService) + 30;

fprintf('成功读取 %d 个任务节点。\n', height(nodes));
disp(nodes);

%% ========================================================================
% 3. 读取运输无人机参数（只提取 A/B/C 三行）
% ========================================================================
uavRaw = readcell(uavFile, 'Sheet', '数据');
uavIDAll = string(uavRaw(:,1));

isNumericPayload = false(size(uavRaw,1),1);
for r = 1:size(uavRaw,1)
    x = uavRaw{r,4};
    isNumericPayload(r) = isnumeric(x) && isscalar(x) && ~isempty(x) && ~isnan(x);
end

uavMask = ismember(uavIDAll, ["A","B","C"]) & isNumericPayload;
if nnz(uavMask) ~= 3
    error('未能唯一识别 A/B/C 三类机型参数，识别到 %d 行。', nnz(uavMask));
end

uavID        = string(uavRaw(uavMask,1));
uavName      = string(uavRaw(uavMask,2));
emptyMass    = cell2mat(uavRaw(uavMask,3));
maxPayload   = cell2mat(uavRaw(uavMask,4));
maxVolume    = cell2mat(uavRaw(uavMask,5));
vCruise      = cell2mat(uavRaw(uavMask,6));
rangeEmpty   = cell2mat(uavRaw(uavMask,7));
rangeFull    = cell2mat(uavRaw(uavMask,8));
batteryUse   = cell2mat(uavRaw(uavMask,9));
reservePct   = cell2mat(uavRaw(uavMask,10));
prepTime     = cell2mat(uavRaw(uavMask,11));
loadTimeBox  = cell2mat(uavRaw(uavMask,12));
handoverBase = cell2mat(uavRaw(uavMask,13));
handoverBox  = cell2mat(uavRaw(uavMask,14));
vClimb       = cell2mat(uavRaw(uavMask,15));
vDesc        = cell2mat(uavRaw(uavMask,16));
etaClimb     = cell2mat(uavRaw(uavMask,17));
etaDesc      = cell2mat(uavRaw(uavMask,18));

uav = table(uavID,uavName,emptyMass,maxPayload,maxVolume,vCruise, ...
    rangeEmpty,rangeFull,batteryUse,reservePct,prepTime,loadTimeBox, ...
    handoverBase,handoverBox,vClimb,vDesc,etaClimb,etaDesc, ...
    'VariableNames', {'ID','Name','EmptyMass','MaxPayload','MaxVolume', ...
    'VCruise','RangeEmpty','RangeFull','BatteryUse','ReservePct', ...
    'PrepTime','LoadTimeBox','HandoverBase','HandoverBox', ...
    'VClimb','VDesc','EtaClimb','EtaDesc'});

fprintf('\n成功读取三种运输无人机参数：\n');
disp(uav);

%% ========================================================================
% 4. 读取 DEM
% ========================================================================
DEMdata = load(demFile);

requiredVars = {'dem','latitude','longitude','nodata','epsg_code','transform'};
for k = 1:numel(requiredVars)
    if ~isfield(DEMdata, requiredVars{k})
        error('DEM MAT 文件缺少变量：%s', requiredVars{k});
    end
end

Z         = double(DEMdata.dem);
latVec    = double(DEMdata.latitude(:));
lonVec    = double(DEMdata.longitude(:)).';
nodataVal = double(DEMdata.nodata(1));
epsgCode  = double(DEMdata.epsg_code(1));
transform = double(DEMdata.transform(:)).';

Z(Z == nodataVal) = NaN;

[nRow,nCol] = size(Z);

if numel(latVec) ~= nRow, error('latitude 数量与 dem 行数不一致。'); end
if numel(lonVec) ~= nCol, error('longitude 数量与 dem 列数不一致。'); end

if latVec(1) > latVec(end)
    latVec = flipud(latVec);
    Z      = flipud(Z);
end
if lonVec(1) > lonVec(end)
    lonVec = fliplr(lonVec);
    Z      = fliplr(Z);
end

fprintf('\nDEM读取完成：%d × %d 像元，EPSG=%d\n', nRow, nCol, epsgCode);
fprintf('经度范围：%.8f° ~ %.8f°\n', min(lonVec), max(lonVec));
fprintf('纬度范围：%.8f° ~ %.8f°\n', min(latVec), max(latVec));
fprintf('有效高程范围：%.3f m ~ %.3f m\n', ...
    min(Z(:),[],'omitnan'), max(Z(:),[],'omitnan'));

%% ========================================================================
% 5. 计算全部节点对的距离 / 最高地面高程 / 巡航海拔 / 爬升 / 下降
% ========================================================================
n = height(nodes);

D           = zeros(n,n);
HterrainMax = zeros(n,n);
Hcruise     = zeros(n,n);
Hstart      = repmat(nodes.WorkElev,1,n);
Hend        = repmat(nodes.WorkElev',n,1);

R = 6371000;

for i = 1:n
    for j = i:n

        if i == j
            D(i,j)           = 0;
            HterrainMax(i,j) = nodes.GroundElev(i);
            Hcruise(i,j)     = nodes.WorkElev(i);
            continue;
        end

        % 5.1 Haversine 距离
        phi1 = deg2rad(nodes.Lat(i));
        phi2 = deg2rad(nodes.Lat(j));
        dphi = deg2rad(nodes.Lat(j) - nodes.Lat(i));
        dlam = deg2rad(nodes.Lon(j) - nodes.Lon(i));

        a = sin(dphi/2)^2 + cos(phi1)*cos(phi2)*sin(dlam/2)^2;
        a = max(0,min(1,a));
        c = 2*atan2(sqrt(a),sqrt(1-a));
        dij = R*c;

        D(i,j) = dij;
        D(j,i) = dij;

        % 5.2 经纬度 -> DEM 行列号
        col1 = interp1(lonVec,1:nCol,nodes.Lon(i),'linear');
        col2 = interp1(lonVec,1:nCol,nodes.Lon(j),'linear');
        row1 = interp1(latVec,1:nRow,nodes.Lat(i),'linear');
        row2 = interp1(latVec,1:nRow,nodes.Lat(j),'linear');

        if any(isnan([row1,row2,col1,col2]))
            error('节点 %s 或 %s 超出 DEM 范围。',nodes.ID(i),nodes.ID(j));
        end

        % 5.3 栅格化两点直线，直接读原始 DEM 像元
        deltaPix   = max(abs(row2-row1),abs(col2-col1));
        nSamplePix = max(2,ceil(4*deltaPix)+1);

        rowPath = round(linspace(row1,row2,nSamplePix));
        colPath = round(linspace(col1,col2,nSamplePix));
        rowPath = max(1,min(nRow,rowPath));
        colPath = max(1,min(nCol,colPath));

        linearIndex = sub2ind([nRow,nCol],rowPath,colPath);
        linearIndex = unique(linearIndex,'stable');

        zPath = Z(linearIndex);
        zPath = zPath(~isnan(zPath));

        if isempty(zPath)
            hTerrain = max(nodes.GroundElev(i),nodes.GroundElev(j));
        else
            hTerrain = max(zPath);
        end

        HterrainMax(i,j) = hTerrain;
        HterrainMax(j,i) = hTerrain;

        hCruise          = hTerrain + 50;
        Hcruise(i,j)     = hCruise;
        Hcruise(j,i)     = hCruise;
    end
end

Hup   = max(0, Hcruise - Hstart);
Hdown = max(0, Hcruise - Hend);

Hup(1:n+1:end)   = 0;
Hdown(1:n+1:end) = 0;

fprintf('\n矩阵 D / HterrainMax / Hcruise / Hup / Hdown 计算完毕。\n');

%% ========================================================================
% 6. 打印用户指定节点对的结果
% ========================================================================
idx1 = find(nodes.ID == startID,1);
idx2 = find(nodes.ID == endID,1);
if isempty(idx1), error('未找到起点编号：%s',startID); end
if isempty(idx2), error('未找到终点编号：%s',endID);   end

fprintf('\n============================================================\n');
fprintf('指定航段几何/地形参数\n');
fprintf('============================================================\n');
fprintf('起点：%s  %s\n', nodes.ID(idx1), nodes.Name(idx1));
fprintf('终点：%s  %s\n', nodes.ID(idx2), nodes.Name(idx2));

fprintf('水平球面距离        ：%.2f m\n', D(idx1,idx2));
fprintf('航线DEM最高地面高程 ：%.2f m\n', HterrainMax(idx1,idx2));
fprintf('计划巡航海拔        ：%.2f m（= 最高地面高程 + 50 m）\n', ...
    Hcruise(idx1,idx2));
fprintf('起点地面海拔        ：%.2f m\n', nodes.GroundElev(idx1));
fprintf('起点作业海拔        ：%.2f m\n', nodes.WorkElev(idx1));
fprintf('终点地面海拔        ：%.2f m\n', nodes.GroundElev(idx2));
fprintf('终点作业海拔        ：%.2f m\n', nodes.WorkElev(idx2));
fprintf('爬升高度 Hup        ：%.2f m\n', Hup(idx1,idx2));
fprintf('下降高度 Hdown      ：%.2f m\n', Hdown(idx1,idx2));

%% ========================================================================
% 7. 保存基础矩阵，供 calcLegCost.m 调用
% ========================================================================
save(baseMatFile, 'nodes', 'uav', ...
     'D', 'HterrainMax', 'Hcruise', 'Hup', 'Hdown', ...
     'epsgCode', 'nodataVal', 'transform', 'demFile');
fprintf('\n基础数据已保存到：%s\n', fullfile(pwd, baseMatFile));

%% ========================================================================
% 8. 可视化指定航段（可选）
% ========================================================================
figure('Name','指定节点航段与DEM','Color','w');
imagesc(lonVec,latVec,Z);
set(gca,'YDir','normal'); axis xy; hold on;

plot([nodes.Lon(idx1),nodes.Lon(idx2)], ...
     [nodes.Lat(idx1),nodes.Lat(idx2)], 'r-','LineWidth',2);
plot(nodes.Lon(idx1),nodes.Lat(idx1),'ko','MarkerFaceColor','w','MarkerSize',7);
plot(nodes.Lon(idx2),nodes.Lat(idx2),'ks','MarkerFaceColor','w','MarkerSize',7);
text(nodes.Lon(idx1),nodes.Lat(idx1),"  "+nodes.ID(idx1),'FontWeight','bold');
text(nodes.Lon(idx2),nodes.Lat(idx2),"  "+nodes.ID(idx2),'FontWeight','bold');

xlabel('经度 (°)'); ylabel('纬度 (°)');
title(sprintf('%s \\rightarrow %s 航段与30 m DEM', ...
    nodes.ID(idx1),nodes.ID(idx2)));
cb = colorbar; ylabel(cb,'地面高程 (m)');
grid on; hold off;

%% ========================================================================
% 9. 将全部矩阵写入 xlsx（可选）
% ========================================================================
if writeResultXlsx
    if isfile(resultFile), delete(resultFile); end

    varNames = cellstr(nodes.ID);
    rowNames = cellstr(nodes.ID);

    writetable(array2table(D,           'VariableNames',varNames,'RowNames',rowNames), ...
        resultFile,'Sheet','Distance_m',     'WriteRowNames',true);
    writetable(array2table(HterrainMax, 'VariableNames',varNames,'RowNames',rowNames), ...
        resultFile,'Sheet','TerrainMax_m',   'WriteRowNames',true);
    writetable(array2table(Hcruise,     'VariableNames',varNames,'RowNames',rowNames), ...
        resultFile,'Sheet','CruiseAltitude_m','WriteRowNames',true);
    writetable(array2table(Hup,         'VariableNames',varNames,'RowNames',rowNames), ...
        resultFile,'Sheet','Climb_m',        'WriteRowNames',true);
    writetable(array2table(Hdown,       'VariableNames',varNames,'RowNames',rowNames), ...
        resultFile,'Sheet','Descent_m',      'WriteRowNames',true);

    meta = {
        'DEM file', demFile;
        'EPSG',     epsgCode;
        'NoData',   nodataVal;
        'Transform', mat2str(transform,12)
        };
    writecell(meta, resultFile, 'Sheet', 'Metadata');

    fprintf('矩阵结果已写入：%s\n', resultFile);
end