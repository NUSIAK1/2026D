function D = euclideanDist(mask)
%EUCLIDEANDIST 二维欧氏距离变换（平方距离，像元单位）。
%   D = common.euclideanDist(mask) 对逻辑掩膜 mask（true=特征）计算每个
%   像元到最近特征像元的欧氏距离平方（单位为像元边长）。算法为可分离的
%   Felzenszwalb–Huttenlocher 一维距离变换，沿行、列各做一次，精确且 O(n)。
%
%   返回 D 与 mask 同尺寸的 double；非特征像元也会得到到最近特征的距离。
%   若 mask 全 false，返回全 Inf。

validateattributes(mask, {'logical'}, {'2d','nonempty'}, mfilename, 'mask', 1);

BIG = 1e30;
f = zeros(size(mask), 'like', double(1));
f(~mask) = BIG;

% 沿行（第 2 维）变换
g = zeros(size(f));
for r = 1:size(f, 1)
    g(r, :) = dt1d(f(r, :));
end

% 沿列（第 1 维）变换
D = zeros(size(g));
for c = 1:size(g, 2)
    D(:, c) = dt1d(g(:, c).');
end

if ~any(mask(:))
    D(:) = Inf;
end
end

function d = dt1d(f)
%DT1D Felzenszwalb–Huttenlocher 一维距离变换。
%   f 为行向量，特征处 0（或有限值），其余为大数 BIG。返回 d(q) =
%   min_i ( (q-i)^2 + f(i) )，q 以 1 为基、i 亦以 1 为基。
n = numel(f);
d = inf(1, n);
v = zeros(1, n);       % 抛物面顶点位置（1 基）
z = inf(1, n + 1);     % z(k)：第 k 条抛物面开始优于前一条的位置
z(1) = -inf;

v(1) = 1;
k = 1;                 % 当前抛物面条数（v(1..k) 有效）
for q = 2:n            % q=1 已作为首个位置预置，避免 2*q-2*v(k)=0 除零
    s = ((f(q) + q*q) - (f(v(k)) + v(k)*v(k))) / (2*q - 2*v(k));
    while s <= z(k)
        k = k - 1;
        s = ((f(q) + q*q) - (f(v(k)) + v(k)*v(k))) / (2*q - 2*v(k));
    end
    k = k + 1;
    v(k) = q;
    z(k) = s;
    z(k + 1) = inf;
end

k = 1;
for q = 1:n
    while z(k + 1) < q
        k = k + 1;
    end
    d(q) = (q - v(k))^2 + f(v(k));
end
end
