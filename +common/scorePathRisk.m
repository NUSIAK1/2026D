function s = scorePathRisk(lonPath, latPath, grid, options)
%SCOREPATHRISK 对一条折线航路沿风险栅格打分。
%   s = common.scorePathRisk(lonPath, latPath, grid, options)
%
%   输入：
%     lonPath, latPath  折线顶点经纬度(度)，double 列向量，长度一致。
%     grid              风险栅格结构体，字段：R(nRow×nCol 风险值)、
%                       Lat(nRow×1 递增)、Lon(1×nCol 递增)、dLat_deg、dLon_deg。
%     options           可选：SampleStep_m(默认15)、HighThreshold(默认0.5)。
%
%   方法：沿线每 SampleStep_m 均匀插值采样，映射到风险栅格取 R 值，跳过
%   NaN 像元。由于采样沿航路均匀分布，算术平均即距离加权平均。
%
%   输出 s 字段：
%     R_max       峰值风险
%     R_mean      距离加权平均风险
%     R_highfrac  高风险(R>HighThreshold)采样占比
%     Len_m       航路总长(m)
%     Nsamples    采样数
%     Nvalid      有效(非 NaN)采样数
%     R           逐采样点风险值列向量（无效处 NaN）

if nargin < 4, options = struct(); end
options = applyDefaults(options);

R = grid.R;
latVec = double(grid.Lat(:));
lonVec = double(grid.Lon(:));
dLat = grid.dLat_deg;
dLon = grid.dLon_deg;
[nRow, nCol] = size(R);

lonPath = double(lonPath(:));
latPath = double(latPath(:));
if numel(lonPath) ~= numel(latPath) || numel(lonPath) < 2
    error('common:scorePathRisk:BadPath', '航路顶点经度/纬度长度需一致且至少 2 点。');
end

sampLon = zeros(0, 1);
sampLat = zeros(0, 1);
Len_m = 0;
for k = 1:(numel(lonPath) - 1)
    seg = haversineM(latPath(k), lonPath(k), latPath(k+1), lonPath(k+1));
    Len_m = Len_m + seg;
    n = max(2, ceil(seg / options.SampleStep_m));
    t = linspace(0, 1, n).';
    sampLon = [sampLon; lonPath(k) + t*(lonPath(k+1) - lonPath(k))]; %#ok<AGROW>
    sampLat = [sampLat; latPath(k) + t*(latPath(k+1) - latPath(k))]; %#ok<AGROW>
end

col = 1 + (sampLon - lonVec(1)) / dLon;
row = 1 + (sampLat - latVec(1)) / dLat;
ci = round(col);
ri = round(row);
inGrid = ci >= 1 & ci <= nCol & ri >= 1 & ri <= nRow;

v = nan(numel(ci), 1);
lin = sub2ind([nRow, nCol], ri(inGrid), ci(inGrid));
v(inGrid) = R(lin);
valid = isfinite(v);

s.R_max = max(v(valid));
s.R_mean = mean(v(valid));
s.R_highfrac = mean(v(valid) > options.HighThreshold);
s.Len_m = Len_m;
s.Nsamples = numel(v);
s.Nvalid = sum(valid);
s.R = v;
end

function options = applyDefaults(options)
defaults = struct('SampleStep_m', 15, 'HighThreshold', 0.5);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(options, names{k}) || isempty(options.(names{k}))
        options.(names{k}) = defaults.(names{k});
    end
end
end

function d = haversineM(lat1, lon1, lat2, lon2)
% 球面 Haversine 距离(m)。
R = 6371000;
phi1 = deg2rad(lat1); phi2 = deg2rad(lat2);
dphi = deg2rad(lat2 - lat1); dlam = deg2rad(lon2 - lon1);
a = sin(dphi/2)^2 + cos(phi1)*cos(phi2)*sin(dlam/2)^2;
d = 2*R*atan2(sqrt(a), sqrt(1 - a));
end
