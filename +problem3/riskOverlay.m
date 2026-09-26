function riskOverlay(config)
%RISKOVERLAY 问题三：洪涝风险航路叠加分析（增强层，不重跑优化）。
%   problem3.riskOverlay(config)
%
%   读取问题三 Pareto 完整档案，对运输航路沿洪涝风险栅格打分，并额外计算
%   中继无人机悬停点的点风险。输出：
%     结果/问题三_风险航路分析.xlsx   代表方案风险 / 代表方案航段明细 / Pareto风险汇总
%     结果/问题三_风险权衡图.png
%
%   本分析只读既有优化结果，不修改任何求解逻辑与官方提交格式。

if nargin < 1, config = struct(); end
config = applyDefaults(config);
paths = common.projectPaths();

fb = load(config.FlightBaseFile);
nodes = fb.nodes;
s = load(config.RiskMatFile);
risk = s.risk;
arch = load(config.Q3ArchiveFile);
sv = arch.saved;

gridComb   = mkGrid(risk.Scenarios(end).R_combined, risk);
gridStatic = mkGrid(risk.R_static, risk);

cnName = containers.Map(...
    {'TimelinessFirst','MakespanFirst','EnergyFirst','TransportTripsFirst','RelayTripsFirst','Balanced'}, ...
    {'及时性优先','完成时间优先','能耗优先','运输架次优先','中继架次优先','折中方案'});

%% 6 个代表方案
repNames = fieldnames(sv.Representatives);
nRep = numel(repNames);
repRisk = struct();
repRows = cell(nRep, 10);
legRows = cell(0, 8);
for r = 1:nRep
    rep = sv.Representatives.(repNames{r});
    sol = rep.Solution;   % 含 .Trips
    o  = common.scoreSolutionRisk(sol, nodes, gridComb, config);
    o2 = common.scoreSolutionRisk(sol, nodes, gridStatic, config);

    % 中继悬停点风险
    [hLon, hLat] = extractHover(rep.Relay.RelayTrips);
    hR = pointRisk(hLon, hLat, gridComb);
    hRStatic = pointRisk(hLon, hLat, gridStatic);

    nm = cnName(repNames{r});
    repRisk.(repNames{r}) = struct('R_mean', o.R_mean, 'R_max', o.R_max, ...
        'R_highfrac', o.R_highfrac, 'R_mean_static', o2.R_mean, ...
        'Len_m', o.Len_m, 'NumTrips', o.NumTrips, ...
        'RelayHoverR_mean', mean(hR, 'omitnan'), 'RelayHoverR_max', max(hR), ...
        'RelayHoverR_static', mean(hRStatic, 'omitnan'));

    repRows(r, :) = {nm, o.NumTrips, o.Len_m, o.R_mean, o.R_max, o.R_highfrac, ...
        o2.R_mean, mean(hR, 'omitnan'), max(hR), numel(hLon)};
    for k = 1:height(o.Legs)
        legRows(end+1, :) = {nm, o.Legs.Trip(k), o.Legs.From(k), o.Legs.To(k), ...
            o.Legs.Len_m(k), o.Legs.R_max(k), o.Legs.R_mean(k), o.Legs.R_highfrac(k)}; %#ok<AGROW>
    end
end

%% 2 个 Pareto 解
P = sv.ParetoFront;
nP = numel(sv.ParetoSolutions);
pRows = cell(nP, 6);
for i = 1:nP
    sol = sv.ParetoSolutions{i}.Solution;
    o = common.scoreSolutionRisk(sol, nodes, gridComb, config);
    pRows(i, :) = {P.SolutionID(i), o.NumTrips, o.Len_m, o.R_mean, o.R_max, o.R_highfrac};
end

%% 表格
repT = cell2table(repRows, 'VariableNames', ...
    {'代表方案','运输架次数','总航程_m','R_mean','R_max','R_highfrac', ...
     'R_mean_static','中继悬停R_mean','中继悬停R_max','中继悬停点数'});
legT = cell2table(legRows, 'VariableNames', ...
    {'Representative','Trip','From','To','Len_m','R_max','R_mean','R_highfrac'});
pT = cell2table(pRows, 'VariableNames', ...
    {'SolutionID','运输架次数','总航程_m','R_mean','R_max','R_highfrac'});

if isfile(config.Q3OutXlsx), delete(config.Q3OutXlsx); end
writetable(repT, config.Q3OutXlsx, 'Sheet', '代表方案风险');
writetable(legT, config.Q3OutXlsx, 'Sheet', '代表方案航段明细');
writetable(pT, config.Q3OutXlsx, 'Sheet', 'Pareto风险汇总');
fprintf('已写出：%s\n', config.Q3OutXlsx);

%% 权衡图
plotTradeoff(repRisk, repNames, cnName, config);
fprintf('已写出：%s\n', config.Q3FigFile);

fprintf('\n===== 问题三风险航路结论 =====\n');
disp(repT);
end

function g = mkGrid(R, risk)
g = struct('R', R, 'Lat', risk.Lat, 'Lon', risk.Lon, ...
    'dLat_deg', risk.dLat_deg, 'dLon_deg', risk.dLon_deg);
end

function [lon, lat] = extractHover(relayTrips)
% 从 RelayTrips 提取悬停经纬度（兼容 table 与 struct 数组）。
lon = []; lat = [];
if istable(relayTrips)
    vn = string(relayTrips.Properties.VariableNames);
    iLon = find(contains(vn, '经度') | contains(vn, 'Lon') | contains(vn, 'lon'), 1);
    iLat = find(contains(vn, '纬度') | contains(vn, 'Lat') | contains(vn, 'lat'), 1);
    if isempty(iLon) || isempty(iLat), return; end
    lon = double(relayTrips{:, iLon});
    lat = double(relayTrips{:, iLat});
elseif isstruct(relayTrips) && numel(relayTrips) > 0
    fn = fieldnames(relayTrips);
    iLon = find(contains(string(fn), '经度') | contains(string(fn), 'Lon') | contains(string(fn), 'lon'), 1);
    iLat = find(contains(string(fn), '纬度') | contains(string(fn), 'Lat') | contains(string(fn), 'lat'), 1);
    if isempty(iLon) || isempty(iLat), return; end
    lon = double([relayTrips.(fn{iLon})]);
    lat = double([relayTrips.(fn{iLat})]);
end
end

function r = pointRisk(lon, lat, grid)
% 采样若干点的风险值。
R = grid.R; latVec = double(grid.Lat(:)); lonVec = double(grid.Lon(:));
dLat = grid.dLat_deg; dLon = grid.dLon_deg;
[nRow, nCol] = size(R);
if isempty(lon)
    r = []; return;
end
ci = round(1 + (double(lon(:)) - lonVec(1)) / dLon);
ri = round(1 + (double(lat(:)) - latVec(1)) / dLat);
inGrid = ci >= 1 & ci <= nCol & ri >= 1 & ri <= nRow;
r = nan(numel(ci), 1);
r(inGrid) = R(sub2ind([nRow, nCol], ri(inGrid), ci(inGrid)));
end

function plotTradeoff(repRisk, repNames, cnName, config)
f = figure('Color', 'w', 'Position', [60 60 1400 560], 'Visible', 'off');
n = numel(repNames);
Rmean = zeros(1, n); Rrelay = zeros(1, n); labels = cell(1, n);
for k = 1:n
    rr = repRisk.(repNames{k});
    Rmean(k) = rr.R_mean;
    Rrelay(k) = rr.RelayHoverR_mean;
    labels{k} = cnName(repNames{k});
end

subplot(1, 2, 1);
bar(Rmean, 'FaceColor', [0.85 0.33 0.1]);
set(gca, 'XTick', 1:n, 'XTickLabel', labels, 'XTickLabelRotation', 30);
ylabel('运输航线综合风险 R_{mean}'); title('运输航路风险（增强层）'); grid on;
ylim([0 max(Rmean)*1.2]);

subplot(1, 2, 2);
bar(Rrelay, 'FaceColor', [0.2 0.5 0.8]);
set(gca, 'XTick', 1:n, 'XTickLabel', labels, 'XTickLabelRotation', 30);
ylabel('中继悬停点平均风险'); title('中继悬停位置风险'); grid on;
ylim([0 max(Rrelay)*1.2]);

sgtitle('问题三代表方案的洪涝风险增强层');
exportgraphics(f, config.Q3FigFile, 'Resolution', 150);
close(f);
end

function config = applyDefaults(config)
paths = common.projectPaths();
defaults = struct( ...
    'FlightBaseFile', paths.FlightBaseFile, ...
    'RiskMatFile', fullfile(paths.ResultDir, '洪涝风险栅格.mat'), ...
    'Q3ArchiveFile', fullfile(paths.ResultDir, '问题三_Pareto完整档案.mat'), ...
    'Q3OutXlsx', fullfile(paths.ResultDir, '问题三_风险航路分析.xlsx'), ...
    'Q3FigFile', fullfile(paths.ResultDir, '问题三_风险权衡图.png'), ...
    'SampleStep_m', 15, 'HighThreshold', 0.5);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(config, names{k}) || isempty(config.(names{k}))
        config.(names{k}) = defaults.(names{k});
    end
end
end
