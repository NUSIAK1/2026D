function pixels = traceDemSupercover(p0,p1,gridSize)
%TRACEDEMSUPERCOVER 二维 Amanatides--Woo 闭合像元完整遍历。
%   pixels = common.traceDemSupercover(p0,p1,[nRow,nCol]) 返回线段 p0 到
%   p1 接触的全部有效 DEM 像元，格式为 N×2 的 [row,col]。p0、p1 的
%   坐标顺序为 [col,row]；整数为像元中心、半整数为像元边界。
%
%   本实现采用闭合像元口径：沿公共边界、穿越角点及端点接触的相邻
%   像元均计入。遍历按 Amanatides--Woo 的栅格边界事件推进；相邻事件
%   间取内部点，事件处取所有闭合接触像元，从而避免固定步长采样漏格。

coordTol = 1e-9;
eventTol = 1e-12;

validateattributes(p0,{'numeric'},{'real','finite','vector','numel',2}, ...
    mfilename,'p0',1);
validateattributes(p1,{'numeric'},{'real','finite','vector','numel',2}, ...
    mfilename,'p1',2);
validateattributes(gridSize,{'numeric'},{'real','finite','integer','vector','numel',2,'positive'}, ...
    mfilename,'gridSize',3);

p0 = snapHalf(double(reshape(p0,1,2)),coordTol);
p1 = snapHalf(double(reshape(p1,1,2)),coordTol);
nRow = double(gridSize(1));
nCol = double(gridSize(2));
delta = p1-p0;

% t=0、t=1 与所有行/列边界交点构成 Amanatides--Woo 事件序列。
tEvents = [0; 1; boundaryEvents(p0(1),delta(1),coordTol,eventTol); ...
                    boundaryEvents(p0(2),delta(2),coordTol,eventTol)];
tEvents = mergeEvents(tEvents,eventTol);

pixels = zeros(0,2);
for k = 1:numel(tEvents)
    point = snapHalf(p0 + tEvents(k)*delta,coordTol);
    pixels = [pixels; cellsTouchingPoint(point,nRow,nCol,coordTol)]; %#ok<AGROW>

    if k < numel(tEvents)
        midT = (tEvents(k)+tEvents(k+1))/2;
        midPoint = snapHalf(p0 + midT*delta,coordTol);
        pixels = [pixels; cellsTouchingPoint(midPoint,nRow,nCol,coordTol)]; %#ok<AGROW>
    end
end

pixels = unique(pixels,'rows','stable');
if isempty(pixels)
    error('common:traceDemSupercover:NoValidPixels', ...
        '线段未接触任何有效 DEM 像元。');
end
end

function values = boundaryEvents(startCoord,deltaCoord,coordTol,eventTol)
if abs(deltaCoord) <= coordTol
    values = zeros(0,1);
    return;
end

direction = sign(deltaCoord);
if direction > 0
    boundary = floor(startCoord-0.5) + 1.5;
else
    boundary = ceil(startCoord-0.5) - 0.5;
end

values = zeros(0,1);
while true
    t = (boundary-startCoord)/deltaCoord;
    if t >= 1-eventTol
        break;
    end
    if t > eventTol
        values(end+1,1) = t; %#ok<AGROW>
    end
    boundary = boundary + direction;
end
end

function values = mergeEvents(values,eventTol)
values = sort(values(:));
merged = values(1);
for k = 2:numel(values)
    if abs(values(k)-merged(end)) > eventTol
        merged(end+1,1) = values(k); %#ok<AGROW>
    end
end
merged(1) = 0;
merged(end) = 1;
values = merged;
end

function pixels = cellsTouchingPoint(point,nRow,nCol,coordTol)
colMin = ceil(point(1)-0.5-coordTol);
colMax = floor(point(1)+0.5+coordTol);
rowMin = ceil(point(2)-0.5-coordTol);
rowMax = floor(point(2)+0.5+coordTol);

cols = max(1,colMin):min(nCol,colMax);
rows = max(1,rowMin):min(nRow,rowMax);
if isempty(rows) || isempty(cols)
    pixels = zeros(0,2);
    return;
end

[colGrid,rowGrid] = meshgrid(cols,rows);
pixels = [rowGrid(:),colGrid(:)];
end

function values = snapHalf(values,coordTol)
nearestHalf = round(2*values)/2;
mask = abs(values-nearestHalf) <= coordTol;
values(mask) = nearestHalf(mask);
end
