function riskOverlay(config)
%RISKOVERLAY 问题二：洪涝风险航路叠加分析（增强层，不重跑优化）。
%   problem2.riskOverlay(config)
%
%   读取问题二 Pareto 完整档案，对每个解的运输航路沿洪涝风险栅格打分，
%   输出：
%     结果/问题二_风险航路分析.xlsx   Pareto风险汇总 / 代表方案风险 /
%                                     代表方案航段明细 / 高风险航段Top
%     结果/问题二_风险权衡图.png       风险 vs 能耗、风险 vs 完成时间散点
%
%   代表方案以"问题二_多目标调度分析.xlsx → 代表方案汇总"的 ParetoIndex
%   为准（TimelinessFirst/MakespanFirst/EnergyFirst/TripCountFirst/Balanced）。
%   本分析只读既有优化结果，不修改任何求解逻辑与官方提交格式。

if nargin < 1, config = struct(); end
config = applyDefaults(config);
paths = common.projectPaths();

fb = load(config.FlightBaseFile);
nodes = fb.nodes;
s = load(config.RiskMatFile);
risk = s.risk;
arch = load(config.Q2ArchiveFile);
pa = arch.paretoArchive;

gridComb   = mkGrid(risk.Scenarios(end).R_combined, risk);
gridStatic = mkGrid(risk.R_static, risk);

P = pa.ParetoFront;
nS = numel(pa.ParetoSolutions);
if height(P) ~= nS
    error('ParetoFront 行数与 ParetoSolutions 数量不一致（%d vs %d）。', height(P), nS);
end

% 代表方案映射（按目标值精确匹配到 ParetoFront 行，ParetoIndex 非行号不可直接索引）
repSum = readtable(config.Q2AnalysisFile, 'Sheet', '代表方案汇总', 'VariableNamingRule', 'preserve');
repName = string(repSum.Representative(:)).';
repMapEn = ["TimelinessFirst","MakespanFirst","EnergyFirst","TripCountFirst","Balanced"];
repMapCn = ["及时性优先","完成时间优先","能耗优先","架次数优先","折中方案"];
repCn = repMapCn(arrayfun(@(x) find(repMapEn == x, 1), repName));

repIdx = zeros(1, numel(repName));
for r = 1:numel(repName)
    m = find(abs(P.Makespan_s - repSum.Makespan_s(r)) < 1e-4 & ...
             abs(P.Energy_kWh - repSum.Energy_kWh(r)) < 1e-6, 1);
    if isempty(m)
        error('无法在 ParetoFront 中定位代表方案 %s（Makespan=%.3f）。', repName(r), repSum.Makespan_s(r));
    end
    repIdx(r) = m;
end

Rmean = nan(nS,1); Rmax = nan(nS,1); Rhf = nan(nS,1);
RmeanS = nan(nS,1); Len = nan(nS,1);
allLegs = cell(0, 4);   % SolutionID, From, To, R_max
repLegs = cell(0, 8);   % Representative, Trip, From, To, Len_m, R_max, R_mean, R_highfrac

fprintf('对问题二 %d 个 Pareto 解做风险航路打分...\n', nS);
for i = 1:nS
    sol = pa.ParetoSolutions{i};
    o  = common.scoreSolutionRisk(sol, nodes, gridComb, config);
    o2 = common.scoreSolutionRisk(sol, nodes, gridStatic, config);
    Rmean(i) = o.R_mean; Rmax(i) = o.R_max; Rhf(i) = o.R_highfrac;
    RmeanS(i) = o2.R_mean; Len(i) = o.Len_m;

    sid = P.SolutionID(i);
    for r = 1:height(o.Legs)
        allLegs(end+1, :) = {sid, o.Legs.From(r), o.Legs.To(r), o.Legs.R_max(r)}; %#ok<AGROW>
    end
    repPos = find(repIdx == i, 1);
    if ~isempty(repPos)
        nm = repCn(repPos);
        for r = 1:height(o.Legs)
            repLegs(end+1, :) = {nm, o.Legs.Trip(r), o.Legs.From(r), o.Legs.To(r), ...
                o.Legs.Len_m(r), o.Legs.R_max(r), o.Legs.R_mean(r), o.Legs.R_highfrac(r)}; %#ok<AGROW>
        end
    end
end

T = P;
T.R_mean = Rmean; T.R_max = Rmax; T.R_highfrac = Rhf;
T.R_mean_static = RmeanS; T.Len_m = Len;

% 代表方案汇总行
repT = T(repIdx, :);
repT.Name = cellstr(repCn(:));

%% 高风险航段 Top
legT = cell2table(allLegs, 'VariableNames', {'SolutionID', 'From', 'To', 'R_max'});
[~, ord] = sort([legT.R_max], 'descend');
topLegs = legT(ord(1:min(30, height(legT))), :);

%% 导出 xlsx
if isfile(config.Q2OutXlsx), delete(config.Q2OutXlsx); end
writetable(T, config.Q2OutXlsx, 'Sheet', 'Pareto风险汇总');
writetable(repT, config.Q2OutXlsx, 'Sheet', '代表方案风险');
writetable(cell2table(repLegs, 'VariableNames', ...
    {'Representative','Trip','From','To','Len_m','R_max','R_mean','R_highfrac'}), ...
    config.Q2OutXlsx, 'Sheet', '代表方案航段明细');
writetable(topLegs, config.Q2OutXlsx, 'Sheet', '高风险航段Top');
fprintf('已写出：%s\n', config.Q2OutXlsx);

%% 权衡图
plotTradeoff(T, repIdx, repCn, config);
fprintf('已写出：%s\n', config.Q2FigFile);

%% 关键结论
fprintf('\n===== 问题二风险航路结论 =====\n');
fprintf('55 个 Pareto 解的 R_mean 范围：%.4f ~ %.4f（极差 %.4f）\n', ...
    min(Rmean), max(Rmean), max(Rmean) - min(Rmean));
fprintf('代表方案风险：\n');
disp(repT(:, {'Name','Makespan_s','Energy_kWh','TripCount','R_mean','R_max','R_highfrac'}));
fprintf('说明：R_mean 几乎不随调度变化，表明风险主要由 O01 出发走廊的几何决定，\n');
fprintf('      属于"结构性暴露"，调度顺序难以规避；规避需绕避高风险区（风险感知重规划）。\n');
end

function g = mkGrid(R, risk)
g = struct('R', R, 'Lat', risk.Lat, 'Lon', risk.Lon, ...
    'dLat_deg', risk.dLat_deg, 'dLon_deg', risk.dLon_deg);
end

function plotTradeoff(T, repIdx, repName, config)
f = figure('Color', 'w', 'Position', [60 60 1400 560], 'Visible', 'off');

subplot(1, 2, 1);
scatter(T.Energy_kWh, T.R_mean, 26, T.TripCount, 'filled', 'MarkerEdgeColor', [0 0 0], ...
    'MarkerFaceAlpha', 0.55); hold on;
scatter(T.Energy_kWh(repIdx), T.R_mean(repIdx), 140, 'r', 'p', 'filled');
text(T.Energy_kWh(repIdx), T.R_mean(repIdx), "  " + repName(:), 'FontSize', 9);
xlabel('总能耗 Energy (kWh)'); ylabel('综合风险 R_{mean}');
title('风险 vs 能耗'); colorbar; grid on;

subplot(1, 2, 2);
scatter(T.Makespan_s, T.R_mean, 26, T.TripCount, 'filled', 'MarkerEdgeColor', [0 0 0], ...
    'MarkerFaceAlpha', 0.55); hold on;
scatter(T.Makespan_s(repIdx), T.R_mean(repIdx), 140, 'r', 'p', 'filled');
text(T.Makespan_s(repIdx), T.R_mean(repIdx), "  " + repName(:), 'FontSize', 9);
xlabel('完成时间 Makespan (s)'); ylabel('综合风险 R_{mean}');
title('风险 vs 完成时间'); colorbar; grid on;

sgtitle('问题二 Pareto 前沿的洪涝风险增强层（红菱形=代表方案，颜色=架次数）');
exportgraphics(f, config.Q2FigFile, 'Resolution', 150);
close(f);
end

function config = applyDefaults(config)
paths = common.projectPaths();
defaults = struct( ...
    'FlightBaseFile', paths.FlightBaseFile, ...
    'RiskMatFile', fullfile(paths.ResultDir, '洪涝风险栅格.mat'), ...
    'Q2ArchiveFile', fullfile(paths.ResultDir, '问题二_Pareto完整档案.mat'), ...
    'Q2AnalysisFile', fullfile(paths.ResultDir, '问题二_多目标调度分析.xlsx'), ...
    'Q2OutXlsx', fullfile(paths.ResultDir, '问题二_风险航路分析.xlsx'), ...
    'Q2FigFile', fullfile(paths.ResultDir, '问题二_风险权衡图.png'), ...
    'SampleStep_m', 15, 'HighThreshold', 0.5);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(config, names{k}) || isempty(config.(names{k}))
        config.(names{k}) = defaults.(names{k});
    end
end
end
