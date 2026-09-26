function W = rasterizeWater(hydro, latVec, lonVec, Z)
%RASTERIZEWATER 将水体(面)多边形与水系(线)折线栅格化到 DEM 网格。
%   W = common.rasterizeWater(hydro, latVec, lonVec, Z) 返回结构体 W：
%     W.Any        水体∪水系的联合掩膜（logical）
%     W.Body       仅水体(面)掩膜
%     W.Line       仅水系(线)掩膜
%     W.BodyLevel  水体(面)像元的静水水面高程(m)，等于该要素像元高程的
%                  中位数（湖泊/水库水面近水平）；非水体像元为 NaN。
%
%   口径：DEM 网格为严格规则网格（latVec、lonVec 均递增），像元中心对应
%   (latVec(r), lonVec(c))；像元坐标映射与 common.computeTerrainMatrices
%   一致（col = 1+(lon-lonVec(1))/dLon）。实现不依赖图像处理工具箱。

validateattributes(latVec, {'numeric'}, {'real','vector','increasing'}, mfilename, 'latVec', 2);
validateattributes(lonVec, {'numeric'}, {'real','vector','increasing'}, mfilename, 'lonVec', 3);
validateattributes(Z, {'numeric'}, {'real','2d','nonempty'}, mfilename, 'Z', 4);

nRow = numel(latVec);
nCol = numel(lonVec);
if ~isequal(size(Z), [nRow, nCol])
    error('common:rasterizeWater:SizeMismatch', 'Z 与 latVec/lonVec 尺寸不一致。');
end
dLat = median(diff(latVec(:)));
dLon = median(diff(lonVec(:)));
if ~isscalar(dLat) || ~isscalar(dLon) || dLat <= 0 || dLon <= 0
    error('common:rasterizeWater:BadGrid', 'DEM 经纬度向量必须为严格规则网格。');
end

lon2col = @(lon) 1 + (lon - lonVec(1)) / dLon;
lat2row = @(lat) 1 + (lat - latVec(1)) / dLat;

W.Body  = false(nRow, nCol);
W.Line  = false(nRow, nCol);
W.BodyLevel = nan(nRow, nCol);

%% 水体(面)：逐要素 inpolygon（包围盒内）+ 静水水位
nb = numel(hydro.WaterBody);
for k = 1:nb
    lon = hydro.WaterBody(k).Lon;
    lat = hydro.WaterBody(k).Lat;
    if numel(unique(lon)) < 2 || numel(unique(lat)) < 2
        continue;   % 退化要素跳过
    end
    pc = lon2col(lon);
    pr = lat2row(lat);
    cMin = max(1, floor(min(pc)) - 1); cMax = min(nCol, ceil(max(pc)) + 1);
    rMin = max(1, floor(min(pr)) - 1); rMax = min(nRow, ceil(max(pr)) + 1);
    if cMin > cMax || rMin > rMax, continue; end
    [cc, rr] = meshgrid(cMin:cMax, rMin:rMax);
    inside = inpolygon(cc, rr, pc, pr);
    if ~any(inside(:)), continue; end

    zInside = Z(rMin:rMax, cMin:cMax);
    zInside = zInside(inside);
    zLevel = median(zInside(~isnan(zInside)));
    if isempty(zLevel) || ~isfinite(zLevel)
        zLevel = NaN;
    end

    W.Body(rMin:rMax, cMin:cMax) = W.Body(rMin:rMax, cMin:cMax) | inside;
    sub = W.Body(rMin:rMax, cMin:cMax) & inside;
    lvl = W.BodyLevel(rMin:rMax, cMin:cMax);
    lvl(sub) = zLevel;
    W.BodyLevel(rMin:rMax, cMin:cMax) = lvl;
end

%% 水系(线)：逐段 supercover 遍历
nl = numel(hydro.WaterLine);
for k = 1:nl
    lon = hydro.WaterLine(k).Lon;
    lat = hydro.WaterLine(k).Lat;
    pc = lon2col(lon);
    pr = lat2row(lat);
    for s = 1:(numel(pc) - 1)
        pix = common.traceDemSupercover([pc(s), pr(s)], [pc(s+1), pr(s+1)], [nRow, nCol]);
        W.Line(sub2ind([nRow, nCol], pix(:,1), pix(:,2))) = true;
    end
end

W.Any = W.Body | W.Line;
fprintf('栅格化完成：水体(面)覆盖 %.3f%%，水系(线)覆盖 %.3f%%，联合覆盖 %.3f%%。\n', ...
    100*mean(W.Body(:)), 100*mean(W.Line(:)), 100*mean(W.Any(:)));
end
