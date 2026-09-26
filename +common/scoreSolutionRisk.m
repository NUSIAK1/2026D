function out = scoreSolutionRisk(solution, nodes, grid, options)
%SCORESOLUTIONRISK 对一个调度方案的所有运输航段做风险打分并汇总。
%   out = common.scoreSolutionRisk(solution, nodes, grid, options)
%
%   solution  含字段 .Trips 的结构体；solution.Trips(k).Stops 为该架次的
%             服务区序列（字符/字符串，可标量或数组）。
%   nodes     table，含 ID、Lon、Lat 三列（O01 与 S001--S015）。
%   grid      风险栅格结构体（见 common.scorePathRisk）。
%   options   传给 scorePathRisk 的采样参数。
%
%   每架次航路 = [O01, Stops..., O01]，逐段打分后按"全线均匀采样"汇总。
%
%   输出 out：
%     R_max / R_mean / R_highfrac   方案级峰值/距离加权均值/高风险占比
%     Len_m / NumLegs / NumTrips    总航程(m) / 航段数 / 架次数
%     Legs     航段明细 table：Trip, From, To, Len_m, R_max, R_mean, R_highfrac
%     AllR     全线采样风险值列向量（用于后续权衡/分布图）

if nargin < 4, options = struct(); end
if ~isfield(options, 'HighThreshold') || isempty(options.HighThreshold)
    options.HighThreshold = 0.5;
end
if ~isfield(options, 'SampleStep_m') || isempty(options.SampleStep_m)
    options.SampleStep_m = 15;
end

id = string(nodes.ID);
lon = double(nodes.Lon);
lat = double(nodes.Lat);
nodeLL = @(nid) deal(lon(id == nid), lat(id == nid)); %#ok<NASGU>

trips = solution.Trips;
nTrip = numel(trips);
legRows = cell(0, 7);
allR = zeros(0, 1);
legCount = 0;

for t = 1:nTrip
    stops = string(trips(t).Stops);
    pathID = ["O01"; stops(:); "O01"];
    for k = 1:(numel(pathID) - 1)
        f = pathID(k); e = pathID(k+1);
        [lonF, latF] = nodeLL(f);
        [lonE, latE] = nodeLL(e);
        sc = common.scorePathRisk([lonF; lonE], [latF; latE], grid, options);
        legCount = legCount + 1;
        legRows(end+1, :) = {t, f, e, sc.Len_m, sc.R_max, sc.R_mean, sc.R_highfrac}; %#ok<AGROW>
        allR = [allR; sc.R(isfinite(sc.R))]; %#ok<AGROW>
    end
end

out = struct();
out.R_max = max(allR);
out.R_mean = mean(allR);
out.R_highfrac = mean(allR > options.HighThreshold);
out.Len_m = sum([legRows{:, 4}]);
out.NumLegs = legCount;
out.NumTrips = nTrip;
out.AllR = allR;
out.Legs = cell2table(legRows, 'VariableNames', ...
    {'Trip', 'From', 'To', 'Len_m', 'R_max', 'R_mean', 'R_highfrac'});
end
