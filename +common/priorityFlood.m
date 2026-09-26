function [Hmin, src, reached] = priorityFlood(Z, seedIdx, seedLevel)
%PRIORITYFLOOD 多源最小最大路径(瓶颈)洪泛，返回"连通所需水位"与"来源水位"。
%   [Hmin, src, reached] = common.priorityFlood(Z, seedIdx, seedLevel)
%
%   对每个像元 c 计算：
%     Hmin(c) = min_{种子 s, 路径 s->c} max_{路径上所有像元 u} Z(u)
%   即"从任意种子连通到 c 所需跨越的最高地形（= 恰好淹没到 c 的水位）"。
%   路径代价取 max 而非求和，因此是 8 邻域上的瓶颈最短路，用桶式优先队列
%   （Dial 式）实现，键值量化为 0.1 m 整数。
%
%   输入：
%     Z          nRow×nCol 高程(m)，NaN 视为不可通行（不参与、不连通）。
%     seedIdx     种子像元线性索引列向量（须落在 Z 的有限值上）。
%     seedLevel   每个种子的"初始水位"(m)，通常 = Z(seedIdx)；
%                 对湖泊/水库可用其中位高程表示静水水面。
%
%   输出（均为 nRow×nCol，NaN 处保持 NaN/Inf）：
%     Hmin        连通所需水位(m)，不可达为 Inf。
%     src         达成 Hmin 的那个种子的初始水位(m)，不可达为 NaN。
%     reached     是否被某种子连通（logical）。
%
%   说明：本函数不修改 Z，不填洼，仅做连通性；用于淹没扩散与封闭洼地
%   填充两类场景（洼地填充时种子取边界像元即可）。

validateattributes(Z, {'numeric'}, {'real','2d','nonempty'}, mfilename, 'Z', 1);
validateattributes(seedIdx, {'numeric'}, {'real','integer','vector','positive'}, mfilename, 'seedIdx', 2);
validateattributes(seedLevel, {'numeric'}, {'real','vector','numel',numel(seedIdx)}, mfilename, 'seedLevel', 3);

[nRow, nCol] = size(Z);
n = nRow * nCol;

Zlin = double(Z(:));
invalid = ~isfinite(Zlin);
Zlin(invalid) = 0;               % 仅用于量化，不会进入队列

% 0.1 m 量化，整数层级
Zq = round(Zlin * 10);
seedLevQ = round(double(seedLevel(:)) * 10);
minLev = min(Zq(~invalid));
maxLev = max(Zq(~invalid));
if isempty(minLev), error('common:priorityFlood:NoValidCells','Z 无有效像元。'); end
if any(~isfinite(seedLevel(:))) || any(seedLevQ < minLev) || any(seedLevQ > maxLev)
    error('common:priorityFlood:BadSeedLevel','种子水位必须为有限值且落在 Z 有效范围内。');
end
numLev = maxLev - minLev + 1;

% 桶式优先队列：buckets{k} 存层级 = minLev-1+k 的线性索引
buckets = cell(numLev, 1);
done    = invalid;               % 无效像元视作已处理，永不入队
HminQ   = inf(n, 1);
srcQ    = nan(n, 1);

lidx = @(lev) lev - minLev + 1;

% 种子入队（初始键 = 自身水位）
for s = 1:numel(seedIdx)
    i = seedIdx(s);
    if i < 1 || i > n || isnan(i), error('common:priorityFlood:BadSeedIndex','种子索引越界。'); end
    if invalid(i), error('common:priorityFlood:SeedOnNaN','种子落在 NaN 像元上。'); end
    lev = seedLevQ(s);
    buckets{lidx(lev)}(end+1,1) = i; %#ok<AGROW>
    HminQ(i) = lev;
    srcQ(i)  = lev;
end

curLev = min(seedLevQ);          % 键只会从最小种子水位往上走

% 8 邻域偏移（列主序线性索引）：dr, dc
dr = [-1 -1 -1  0  0  1  1  1];
dc = [-1  0  1 -1  1 -1  0  1];

while true
    % 定位下一个非空桶
    while curLev <= maxLev && isempty(buckets{lidx(curLev)})
        curLev = curLev + 1;
    end
    if curLev > maxLev, break; end

    b = buckets{lidx(curLev)};
    buckets{lidx(curLev)} = zeros(0,1);

    for t = 1:numel(b)
        i = b(t);
        if done(i), continue; end
        done(i) = true;
        w = HminQ(i);
        s = srcQ(i);
        r = i - nRow * floor((i - 1) / nRow);   % 行号 1..nRow
        c = floor((i - 1) / nRow) + 1;          % 列号 1..nCol

        for k = 1:8
            nr = r + dr(k);
            nc = c + dc(k);
            if nr < 1 || nr > nRow || nc < 1 || nc > nCol, continue; end
            j = i + dr(k) + dc(k) * nRow;
            if done(j), continue; end
            nw = max(w, Zq(j));
            if nw < HminQ(j)
                HminQ(j) = nw;
                srcQ(j)  = s;
                buckets{lidx(nw)}(end+1,1) = j; %#ok<AGROW>
            end
        end
    end
end

% 还原到米与 nRow×nCol 形状
Hmin = reshape(HminQ, nRow, nCol) / 10;
src  = reshape(srcQ,  nRow, nCol) / 10;
Hmin(invalid) = Inf;
src(invalid)  = NaN;
reached = isfinite(Hmin);
end
