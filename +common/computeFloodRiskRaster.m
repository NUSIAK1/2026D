function risk = computeFloodRiskRaster(options)
%COMPUTEFLOODRISKRASTER 构建洪涝风险栅格（DEM + 水体 + 水系）。
%   risk = common.computeFloodRiskRaster(options)
%
%   在 Coreg3CM 校正后的 30 m DEM 同一网格上，合成三个归一化到 [0,1] 的
%   风险因子，并按水位抬升情景输出淹没因子与综合风险：
%     1) 地形易积水因子 R_terr  = 0.5*R_slope + 0.5*R_tpi
%          R_slope：坡度（越平越易积水）
%          R_tpi  ：地形位置指数 TPI（越低于邻域越易汇水）
%     2) 水系邻近因子 R_prox  = exp(-dist/d0)（距水体/水系越近风险越高）
%     3) 淹没扩散因子 R_inund(Δh)：以水体/水系为源、水位抬升 Δh 的
%          连通淹没（优先队列洪泛），风险 = min(1, 淹没深度/D0)
%     综合 R_combined(Δh) = w1*R_terr + w2*R_prox + w3*R_inund(Δh)
%
%   物理口径不变：本函数只生成派生风险图层，不修改巡航海拔、能耗、通信
%   等任何题目规则，也不进入 Q2/Q3 优化目标。
%
%   options 可选字段（默认值见 applyDefaults）：
%     FlightBaseFile      缓存 flightBase.mat（默认项目标准路径）
%     Scenarios           水位抬升情景 (m)，默认 [0.5 1.0 2.0]
%     Weights             [w_terr w_prox w_inund]，默认 [1/3 1/3 1/3]
%     SlopeRef_deg        坡度风险参考角，默认 30
%     TpiScale_m          TPI 归一化尺度 (m)，默认 15
%     TpiWindow           TPI 邻域窗口边长（像元），默认 11
%     ProximityScale_m    邻近衰减距离 (m)，默认 300
%     InundDepthScale_m   淹没深度饱和尺度 (m)，默认 2
%     RiskMatFile         输出 .mat 路径
%     TiffDir             TIFF 输出目录
%     FigFile             因子多面板图 PNG 路径
%     ShowFigure          是否显示图窗，默认 true
%
%   risk 结构体（也写入 RiskMatFile）：
%     Z_m / Lat / Lon / dLat_deg / dLon_deg / epsgCode
%     waterMask / waterBodyMask / waterLineMask
%     slope_deg / tpi_m / R_terr / R_prox / rise_m / R_static
%     Scenarios(s).Rise_m / .R_inund / .R_combined
%     Params / Metadata

if nargin < 1, options = struct(); end
options = applyDefaults(options);
paths = common.projectPaths();

%% 1. 网格底座：复用已 Coreg3CM 校正的 DEM（与 supercover 同格）
fb = load(options.FlightBaseFile);
dem = fb.dem;
Z = dem.Z;
latVec = dem.Lat(:);
lonVec = dem.Lon(:);
nRow = numel(latVec);
nCol = numel(lonVec);
bad = isnan(Z);

fprintf('风险栅格网格：%d × %d（EPSG:%d，%.0f m）。\n', nRow, nCol, dem.epsgCode, dem.dLat*111320);
fprintf('有效高程 %.2f ~ %.2f m，NaN 占比 %.4f。\n', min(Z(:),[],'omitnan'), max(Z(:),[],'omitnan'), mean(bad(:)));

%% 2. 水文要素与栅格化
hydro = common.loadHydrography();
W = common.rasterizeWater(hydro, latVec, lonVec, Z);

%% 3. 地形因子：坡度 + TPI
dLat_m = dem.dLat * 111320;
dLon_m = dem.dLon * 111320 * cosd(mean(latVec));
Zfill = fillmissing(Z, 'nearest', 2);
Zfill = fillmissing(Zfill, 'nearest', 1);

[dzdx, dzdy] = gradient(Zfill, dLon_m, dLat_m);
slope_deg = atand(hypot(dzdx, dzdy));
R_slope = max(0, 1 - slope_deg / options.SlopeRef_deg);

win = options.TpiWindow;
boxmean = conv2(Zfill, ones(win)/(win*win), 'same');
tpi_m = Zfill - boxmean;
R_tpi = 1 ./ (1 + exp(tpi_m / options.TpiScale_m));

R_terr = 0.5*R_slope + 0.5*R_tpi;

%% 4. 邻近因子：欧氏距离到水体/水系
D2 = common.euclideanDist(W.Any);
cell_m = sqrt(dLat_m * dLon_m);
dist_m = sqrt(D2) * cell_m;
R_prox = exp(-dist_m / options.ProximityScale_m);

%% 5. 淹没因子：多源优先队列洪泛（水源水位=静水/河流水面）
seedLevel = Z;
seedLevel(W.Body) = W.BodyLevel(W.Body);   % 湖泊/水库→静水水面（中位数）
seeds = find(W.Any);
levels = seedLevel(seeds);
ok = isfinite(levels);
[Hmin, src] = common.priorityFlood(Z, seeds(ok), levels(ok));
rise_m = Hmin - src;                        % 连通所需水位抬升

scen = options.Scenarios(:).';
nScen = numel(scen);
R_inund = cell(1, nScen);
for s = 1:nScen
    dh = scen(s);
    R = zeros(nRow, nCol);
    R(W.Any) = 1;                            % 水体本身=最高风险
    flooded = (~W.Any) & (rise_m <= dh);
    depth = src + dh - Z;
    R(flooded) = min(1, max(0, depth(flooded)) / options.InundDepthScale_m);
    R_inund{s} = R;
end

%% 6. 综合风险
w = options.Weights;
% 无洪水基线：与综合风险同权重、仅令淹没项=0，保证 R_combined = R_static + 洪水贡献
R_static = w(1)*R_terr + w(2)*R_prox;
R_combined = cell(1, nScen);
for s = 1:nScen
    R_combined{s} = w(1)*R_terr + w(2)*R_prox + w(3)*R_inund{s};
end

%% 7. NaN 掩膜（无效像元不参与风险）
R_slope(bad) = NaN; R_tpi(bad) = NaN; R_terr(bad) = NaN;
R_prox(bad) = NaN;  R_static(bad) = NaN;
for s = 1:nScen
    R_inund{s}(bad) = NaN;
    R_combined{s}(bad) = NaN;
end
rise_m(bad) = NaN;

%% 8. 组装与保存
risk = struct();
risk.Z_m = Z; risk.Lat = latVec; risk.Lon = lonVec;
risk.dLat_deg = dem.dLat; risk.dLon_deg = dem.dLon;
risk.epsgCode = dem.epsgCode; risk.nodataVal = dem.nodataVal;
risk.waterMask = W.Any; risk.waterBodyMask = W.Body; risk.waterLineMask = W.Line;
risk.slope_deg = slope_deg; risk.tpi_m = tpi_m;
risk.R_slope = R_slope; risk.R_tpi = R_tpi;
risk.R_terr = R_terr; risk.R_prox = R_prox;
risk.rise_m = rise_m; risk.R_static = R_static;
risk.Scenarios = struct('Rise_m', num2cell(scen), 'R_inund', R_inund, 'R_combined', R_combined);
risk.Params = struct('Scenarios', scen, 'Weights', w, ...
    'SlopeRef_deg', options.SlopeRef_deg, 'TpiScale_m', options.TpiScale_m, ...
    'TpiWindow', options.TpiWindow, 'ProximityScale_m', options.ProximityScale_m, ...
    'InundDepthScale_m', options.InundDepthScale_m);
risk.Metadata = struct('GeneratedBy', mfilename, 'GeneratedAt', char(datetime('now')), ...
    'DEMFile', dem.SourceFile, 'WaterBodyCount', numel(hydro.WaterBody), ...
    'WaterLineCount', numel(hydro.WaterLine));

save(options.RiskMatFile, 'risk');
fprintf('风险栅格已保存：%s\n', options.RiskMatFile);

%% 9. 导出 TIFF（北向上 + 世界文件）
if ~isempty(options.TiffDir)
    if ~isfolder(options.TiffDir), mkdir(options.TiffDir); end
    common.writeNorthUpGeoTiff(R_terr, lonVec, latVec, fullfile(options.TiffDir, '洪涝风险栅格_地形.tif'));
    common.writeNorthUpGeoTiff(R_prox, lonVec, latVec, fullfile(options.TiffDir, '洪涝风险栅格_邻近.tif'));
    common.writeNorthUpGeoTiff(R_static, lonVec, latVec, fullfile(options.TiffDir, '洪涝风险栅格_静态.tif'));
    for s = 1:nScen
        tag = sprintf('%.1fm', scen(s));
        common.writeNorthUpGeoTiff(R_inund{s}, lonVec, latVec, fullfile(options.TiffDir, ['洪涝风险栅格_淹没_' tag '.tif']));
        common.writeNorthUpGeoTiff(R_combined{s}, lonVec, latVec, fullfile(options.TiffDir, ['洪涝风险栅格_综合_' tag '.tif']));
    end
end

%% 10. 因子多面板图
if ~isempty(options.FigFile)
    plotRiskFigure(risk, hydro, fb, options);
    fprintf('因子图已保存：%s\n', options.FigFile);
end

fprintf('\n洪涝风险栅格构建完成。\n');
end

function plotRiskFigure(risk, hydro, fb, options)
nScen = numel(risk.Scenarios);
last = risk.Scenarios(nScen);
nodes = fb.nodes;
latVec = risk.Lat; lonVec = risk.Lon;

f = figure('Color', 'w', 'Position', [40 40 1680 900], 'Visible', ternary(options.ShowFigure, 'on', 'off'));

panel = @(p, R, tt) drawPanel(p, R, lonVec, latVec, tt);

ax = subplot(2, 3, 1);
imagesc(lonVec, latVec, risk.Z_m); axis xy; hold on;
title('地面高程 DEM'); colorbar; colormap(ax, 'parula');
overlayHydro(ax, hydro, nodes);

panel(2, risk.R_terr, '地形易积水因子 R_{terr}');
panel(3, risk.R_prox, '水系邻近因子 R_{prox}');
panel(4, last.R_inund, sprintf('淹没因子 R_{inund} (%+.1f m)', last.Rise_m));
panel(5, last.R_combined, sprintf('综合风险 R (%+.1f m)', last.Rise_m));
panel(6, risk.R_static, '静态综合风险（无洪水）');

sgtitle('山区洪涝风险栅格（DEM + 水体 + 水系，30 m）');
exportgraphics(f, options.FigFile, 'Resolution', 150);
if ~options.ShowFigure, close(f); end
end

function drawPanel(p, R, lonVec, latVec, tt)
ax = subplot(2, 3, p);
imagesc(lonVec, latVec, R, [0 1]); axis xy; hold on;
colormap(ax, 'turbo'); colorbar; title(tt);
end

function overlayHydro(ax, hydro, nodes)
for k = 1:numel(hydro.WaterBody)
    plot(ax, hydro.WaterBody(k).Lon, hydro.WaterBody(k).Lat, '-', 'Color', [0.1 0.4 0.8], 'LineWidth', 0.4);
end
for k = 1:numel(hydro.WaterLine)
    plot(ax, hydro.WaterLine(k).Lon, hydro.WaterLine(k).Lat, '-', 'Color', [0.1 0.5 0.9], 'LineWidth', 0.4);
end
plot(ax, nodes.Lon, nodes.Lat, 'rs', 'MarkerFaceColor', 'r', 'MarkerSize', 4);
text(ax, nodes.Lon, nodes.Lat, "  " + nodes.ID, 'FontSize', 6, 'Color', 'r');
end

function options = applyDefaults(options)
if ~isstruct(options) || ~isscalar(options)
    error('options 必须是标量结构体。');
end
paths = common.projectPaths();
defaults = struct( ...
    'FlightBaseFile', paths.FlightBaseFile, ...
    'Scenarios', [0.5 1.0 2.0], ...
    'Weights', [1/3 1/3 1/3], ...
    'SlopeRef_deg', 30, ...
    'TpiScale_m', 15, ...
    'TpiWindow', 11, ...
    'ProximityScale_m', 300, ...
    'InundDepthScale_m', 2, ...
    'RiskMatFile', fullfile(paths.ResultDir, '洪涝风险栅格.mat'), ...
    'TiffDir', fullfile(paths.ResultDir, '洪涝风险栅格'), ...
    'FigFile', fullfile(paths.ResultDir, '洪涝风险栅格_因子图.png'), ...
    'ShowFigure', true);
names = fieldnames(defaults);
for k = 1:numel(names)
    if ~isfield(options, names{k}) || isempty(options.(names{k}))
        options.(names{k}) = defaults.(names{k});
    end
end
if ~isvector(options.Scenarios) || any(~isfinite(options.Scenarios)) || any(options.Scenarios < 0)
    error('Scenarios 必须为非负有限向量。');
end
if ~isvector(options.Weights) || numel(options.Weights) ~= 3 || any(options.Weights < 0)
    error('Weights 必须为 3 元非负向量。');
end
options.Weights = reshape(double(options.Weights), 1, 3);
end

function r = ternary(cond, a, b)
if cond, r = a; else, r = b; end
end
