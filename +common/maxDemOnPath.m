function hTerrain = maxDemOnPath(Z,pixels,startID,endID)
%MAXDEMONPATH 返回航段闭合 supercover 像元中的最高原始 DEM 高程。
%   遇到越界、NoData（应预先转换为 NaN）、NaN 或 Inf 时直接报错，
%   不用端点高程或其他值替代未知沿途地形。

validateattributes(Z,{'numeric'},{'real','2d','nonempty'},mfilename,'Z',1);
validateattributes(pixels,{'numeric'},{'real','finite','2d','ncols',2,'nonempty'}, ...
    mfilename,'pixels',2);

if any(abs(pixels(:)-round(pixels(:))) > 1e-12)
    error('common:maxDemOnPath:InvalidPixels','像元行列号必须为整数。');
end

startID = string(startID);
endID = string(endID);
if ~isscalar(startID) || ~isscalar(endID)
    error('common:maxDemOnPath:InvalidNodeID','起终点编号必须为标量文本。');
end

pixels = round(double(pixels));
[nRow,nCol] = size(Z);
isOut = pixels(:,1) < 1 | pixels(:,1) > nRow | ...
        pixels(:,2) < 1 | pixels(:,2) > nCol;
if any(isOut)
    bad = pixels(find(isOut,1),:);
    error('common:maxDemOnPath:PixelOutOfRange', ...
        '航段 %s -> %s 的 DEM 像元 [%d,%d] 超出栅格范围。', ...
        startID,endID,bad(1),bad(2));
end

linearIndex = sub2ind([nRow,nCol],pixels(:,1),pixels(:,2));
zPath = double(Z(linearIndex));
if any(~isfinite(zPath))
    bad = pixels(find(~isfinite(zPath),1),:);
    error('common:maxDemOnPath:InvalidElevation', ...
        ['航段 %s -> %s 接触到无效 DEM 高程像元 [%d,%d]；' ...
         'NoData、NaN 和 Inf 不允许用端点高程替代。'], ...
        startID,endID,bad(1),bad(2));
end

hTerrain = max(zPath);
end
