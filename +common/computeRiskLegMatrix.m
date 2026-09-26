function riskLeg = computeRiskLegMatrix(options)
%COMPUTERISKLEGMATRIX 计算 16×16 节点间风险航路矩阵（增强层核心产物）。
%   riskLeg = common.computeRiskLegMatrix(options)
%
%   与 common.computeTerrainMatrices 产出的"节点间无人机运输基础参数"并列，
%   本函数在洪涝风险栅格上计算任意节点对之间直飞航段的风险，输出：
%     R_mean       距离加权平均综合风险
%     R_max        峰值综合风险
%     R_highfrac   高风险(R>0.5)采样占比
%     R_mean_static 静态(无洪水)情景平均风险
%   矩阵对称（直飞航段风险与方向无关）。
%
%   导出：
%     结果/节点间风险航路矩阵.mat / .xlsx
%     结果/风险航路图.png（风险栅格 + 节点间航段按风险着色）
%
%   口径：航段为两节点间直线，风险按 common.scorePathRisk 沿线均匀采样；
%   综合风险取 Scenarios(end)（最高水位情景），静态风险取 R_static。

if nargin < 1, options = struct(); end
options = applyDefaults(options);
paths = common.projectPaths();

fb = load(options.FlightBaseFile);
nodes = fb.nodes;
s = load(options.RiskMatFile);
risk = s.risk;

grid   = mkGrid(risk.Scenarios(end).R_combined, risk);
gridS  = mkGrid(risk.R_static, risk);

n = height(nodes);
Rmean = nan(n); Rmax = nan(n); Rhf = nan(n); RmeanS = nan(n);
for i = 1:n
    for j = i+1:n
        sc = common.scorePathRisk([nodes.Lon(i); nodes.Lon(j)], ...
            [nodes.Lat(i); nodes.Lat(j)], grid, options);
        Rmean(i,j) = sc.R_mean; Rmean(j,i) = sc.R_mean;
        Rmax(i,j)  = sc.R_max;  Rmax(j,i)  = sc.R_max;
        Rhf(i,j)   = sc.R_highfrac; Rhf(j,i) = sc.R_highfrac;
        sc2 = common.scorePathRisk([nodes.Lon(i); nodes.Lon(j)], ...
            [nodes.Lat(i); nodes.Lat(j)], gridS, options);
        RmeanS(i,j) = sc2.R_mean; RmeanS(j,i) = sc2.R_mean;
    end
end

riskLeg = struct();
riskLeg.nodes = nodes;
riskLeg.R_mean = Rmean;
riskLeg.R_max = Rmax;
riskLeg.R_highfrac = Rhf;
riskLeg.R_mean_static = RmeanS;
riskLeg.ScenarioRise_m = risk.Scenarios(end).Rise_m;
riskLeg.HighThreshold = options.HighThreshold;

%% 导出 xlsx
varNames = cellstr(nodes.ID);
rowNames = cellstr(nodes.ID);
if isfile(options.MatrixXlsx), delete(options.MatrixXlsx); end
writetable(array2table(Rmean, 'VariableNames', varNames, 'RowNames', rowNames), ...
    options.MatrixXlsx, 'Sheet', 'RiskMean', 'WriteRowNames', true);
writetable(array2table(Rmax, 'VariableNames', varNames, 'RowNames', rowNames), ...
    options.MatrixXlsx, 'Sheet', 'RiskMax', 'WriteRowNames', true);
writetable(array2table(Rhf, 'VariableNames', varNames, 'RowNames', rowNames), ...
    options.MatrixXlsx, 'Sheet', 'RiskHighFrac', 'WriteRowNames', true);
writetable(array2table(RmeanS, 'VariableNames', varNames, 'RowNames', rowNames), ...
    options.MatrixXlsx, 'Sheet', 'RiskMeanStatic', 'WriteRowNames', true);
meta = {
    '风险栅格', options.RiskMatFile;
    '综合情景水位抬升_m', risk.Scenarios(end).Rise_m;
    '高风险阈值', options.HighThreshold;
    '航段口径', '两节点间直线，沿线均匀采样';
    '风险对称性', '直飞航段风险与方向无关，矩阵对称'
    };
writecell(meta, options.MatrixXlsx, 'Sheet', 'Metadata');
fprintf('风险航路矩阵已写出：%s\n', options.MatrixXlsx);

save(options.MatrixMat, 'riskLeg');
fprintf('风险航路矩阵已保存：%s\n', options.MatrixMat);

%% 风险航路图
if ~isempty(options.FigFile)
    plotRiskRoutes(riskLeg, risk, nodes, options);
    fprintf('风险航路图已写出：%s\n', options.FigFile);
end
end

function g = mkGrid(R, risk)
g = struct('R', R, 'Lat', risk.Lat, 'Lon', risk.Lon, ...
    'dLat_deg', risk.dLat_deg, 'dLon_deg', risk.dLon_deg);
end

function plotRiskRoutes(riskLeg, risk, nodes, options)
latVec = risk.Lat; lonVec = risk.Lon;
f = figure('Color', 'w', 'Position', [60 60 1000 880], 'Visible', 'off');
imagesc(lonVec, latVec, risk.Scenarios(end).R_combined, [0 1]); axis xy; hold on;
colormap(turbo); cb = colorbar; ylabel(cb, '综合风险 R');

n = height(nodes);
rvals = []; pairs = [];
for i = 1:n
    for j = i+1:n
        rvals(end+1) = riskLeg.R_mean(i,j); %#ok<AGROW>
        pairs(end+1, :) = [i j]; %#ok<AGROW>
    end
end
rmin = min(rvals); rmax = max(rvals);
cmap = turbo(256);
for q = 1:numel(rvals)
    ci = round(1 + 255*(rvals(q)-rmin)/max(1e-12, rmax-rmin));
    ci = max(1, min(256, ci));
    plot([nodes.Lon(pairs(q,1)), nodes.Lon(pairs(q,2))], ...
        [nodes.Lat(pairs(q,1)), nodes.Lat(pairs(q,2))], '-', ...
        'Color', cmap(ci,:), 'LineWidth', 1.5);
end
plot(nodes.Lon, nodes.Lat, 'ks', 'MarkerFaceColor', 'w', 'MarkerSize', 5);
text(nodes.Lon, nodes.Lat, "  " + nodes.ID, 'FontSize', 7, 'FontWeight', 'bold');
title(sprintf('节点间风险航路（综合风险 R，Δh=%+.1f m）', risk.Scenarios(end).Rise_m));
xlabel('经度 (°)'); ylabel('纬度 (°)'); grid on;
exportgraphics(f, options.FigFile, 'Resolution', 150);
close(f);
end

function options = applyDefaults(options)
paths = common.projectPaths();
defaults = struct( ...
    'FlightBaseFile', paths.FlightBaseFile, ...
    'RiskMatFile', fullfile(paths.ResultDir, '洪涝风险栅格.mat'), ...
    'MatrixMat', fullfile(paths.ResultDir, '节点间风险航路矩阵.mat'), ...
    'MatrixXlsx', fullfile(paths.ResultDir, '节点间风险航路矩阵.xlsx'), ...
    'FigFile', fullfile(paths.ResultDir, '风险航路图.png'), ...
    'SampleStep_m', 15, 'HighThreshold', 0.5);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(options, names{k}) || isempty(options.(names{k}))
        options.(names{k}) = defaults.(names{k});
    end
end
end
