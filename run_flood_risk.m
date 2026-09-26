function risk = run_flood_risk(config)
%RUN_FLOOD_RISK 洪涝风险栅格构建入口（问题二/三"增强层"的图层底座）。
%   risk = run_flood_risk(config) 调用 common.computeFloodRiskRaster 生成：
%     结果/洪涝风险栅格.mat          精确浮点栅格（Q2/Q3 叠置打分用）
%     结果/洪涝风险栅格/             *.tif + *.tfw（GIS 可视化）
%     结果/洪涝风险栅格_因子图.png   多面板因子图（论文用）
%
%   config 可覆盖 computeFloodRiskRaster 的 options；默认批处理不弹图窗。

if nargin < 1, config = struct(); end
if ~isfield(config, 'ShowFigure') || isempty(config.ShowFigure)
    config.ShowFigure = false;
end

risk = common.computeFloodRiskRaster(config);

%% 简要汇总
fprintf('\n===== 洪涝风险栅格汇总 =====\n');
fprintf('网格 %d × %d，EPSG:%d，~30 m。\n', numel(risk.Lat), numel(risk.Lon), risk.epsgCode);
fprintf('R_terr  : %.3f ~ %.3f（中位 %.3f）\n', ...
    min(risk.R_terr(:),[],'omitnan'), max(risk.R_terr(:),[],'omitnan'), median(risk.R_terr(:),'omitnan'));
fprintf('R_prox  : %.3f ~ %.3f（中位 %.3f）\n', ...
    min(risk.R_prox(:),[],'omitnan'), max(risk.R_prox(:),[],'omitnan'), median(risk.R_prox(:),'omitnan'));
for s = 1:numel(risk.Scenarios)
    sc = risk.Scenarios(s);
    fprintf('Δh=%.1fm : 淹没面积 %.1f%% | R_combined %.3f ~ %.3f（中位 %.3f）\n', ...
        sc.Rise_m, 100*mean(sc.R_inund(:) > 0, 'omitnan'), ...
        min(sc.R_combined(:),[],'omitnan'), max(sc.R_combined(:),[],'omitnan'), ...
        median(sc.R_combined(:),'omitnan'));
end
fprintf('===== 完成 =====\n');
end
