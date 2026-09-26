function [Zcorrected, fit] = coreg3cmDem(Z, latVec, lonVec, controlPoints)
%COREG3CM 以控制点实施 DEM 三维共配准（Coreg3CM）。
% controlPoints 每行是 [Lon_deg, Lat_deg, ObservedElev_m]。
% 拟合模型：dH = -dz/dE * DX - dz/dN * DY + DZ。
% 其中 DX 向东为正、DY 向北为正；校正栅格为
% Zcorrected(E,N) = Zraw(E-DX,N-DY) + DZ。

validateattributes(Z,{'numeric'},{'2d','nonempty'});
latVec = double(latVec(:));
lonVec = double(lonVec(:)).';
controlPoints = double(controlPoints);
if size(Z,1) ~= numel(latVec) || size(Z,2) ~= numel(lonVec)
    error('common:coreg3cmDem:GridSizeMismatch','DEM 与经纬度向量尺寸不一致。');
end
if size(controlPoints,2) ~= 3 || size(controlPoints,1) < 3 || ...
        any(~isfinite(controlPoints),'all')
    error('common:coreg3cmDem:InvalidControlPoints', ...
        '控制点必须是至少 3 行的 [经度, 纬度, 实测高程] 有限数值。');
end
if any(diff(latVec)<=0) || any(diff(lonVec)<=0)
    error('common:coreg3cmDem:InvalidGrid','DEM 经纬度必须严格递增。');
end

Z = double(Z);
[dZdLat, dZdLon] = geographicDerivatives(Z,latVec,lonVec);
lon = controlPoints(:,1); lat = controlPoints(:,2);
rawElev = interp2(lonVec,latVec,Z,lon,lat,'linear',NaN);
dLat = interp2(lonVec,latVec,dZdLat,lon,lat,'linear',NaN);
dLon = interp2(lonVec,latVec,dZdLon,lon,lat,'linear',NaN);
if any(~isfinite([rawElev;dLat;dLon]))
    error('common:coreg3cmDem:InvalidControlSample', ...
        '控制点超出 DEM、落在无效像元，或无法计算局部坡度。');
end

% 将纬/经度方向梯度转换为以 m 为单位的北/东向坡度。
phi = deg2rad(lat);
[metrePerDegLat, metrePerDegLon] = metresPerDegree(phi);
gradN = dLat ./ metrePerDegLat;
gradE = dLon ./ metrePerDegLon;
design = [-gradE,-gradN,ones(size(gradE))];
if rank(design) < 3 || rcond(design.'*design) < 1e-12
    error('common:coreg3cmDem:IllConditionedFit', ...
        '控制点坡度信息不足，无法稳定反演 DX、DY、DZ。');
end

observedElev = controlPoints(:,3);
coef = design \ (observedElev-rawElev);
residual = design*coef - (observedElev-rawElev);

% 逐栅格转换米制整体位移为该纬度处的经纬度查询偏移，再线性重采样。
[lonGrid,latGrid] = meshgrid(lonVec,latVec);
[metrePerDegLatGrid, metrePerDegLonGrid] = metresPerDegree(deg2rad(latGrid));
sourceLon = lonGrid - coef(1)./metrePerDegLonGrid;
sourceLat = latGrid - coef(2)./metrePerDegLatGrid;
Zcorrected = interp2(lonVec,latVec,Z,sourceLon,sourceLat,'linear',NaN);
Zcorrected(isfinite(Zcorrected)) = Zcorrected(isfinite(Zcorrected)) + coef(3);
correctedElev = interp2(lonVec,latVec,Zcorrected,lon,lat,'linear',NaN);
postResidual = correctedElev-observedElev;

fit = struct( ...
    'Method',"Coreg3CM", ...
    'DX_m',coef(1), ...
    'DY_m',coef(2), ...
    'DZ_m',coef(3), ...
    'ControlPoints',controlPoints, ...
    'RawElev_m',rawElev, ...
    'SlopeEast_mpm',gradE, ...
    'SlopeNorth_mpm',gradN, ...
    'Slope_deg',rad2deg(atan(hypot(gradE,gradN))), ...
    'Aspect_deg',mod(rad2deg(atan2(-gradE,-gradN)),360), ...
    'Residual_m',residual, ...
    'RMSE_m',sqrt(mean(residual.^2)), ...
    'MAE_m',mean(abs(residual)), ...
    'MaxAbsResidual_m',max(abs(residual)), ...
    'CorrectedElev_m',correctedElev, ...
    'PostResidual_m',postResidual, ...
    'PostRMSE_m',sqrt(mean(postResidual.^2,'omitnan')));
end

function [dZdLat,dZdLon] = geographicDerivatives(Z,latVec,lonVec)
% 对不规则间距也保持正确的中心差分；边界使用单边差分。
dZdLat = nan(size(Z));
dZdLon = nan(size(Z));
for r = 1:numel(latVec)
    if r == 1
        dZdLat(r,:) = (Z(2,:)-Z(1,:)) / (latVec(2)-latVec(1));
    elseif r == numel(latVec)
        dZdLat(r,:) = (Z(end,:)-Z(end-1,:)) / (latVec(end)-latVec(end-1));
    else
        dZdLat(r,:) = (Z(r+1,:)-Z(r-1,:)) / (latVec(r+1)-latVec(r-1));
    end
end
for c = 1:numel(lonVec)
    if c == 1
        dZdLon(:,c) = (Z(:,2)-Z(:,1)) / (lonVec(2)-lonVec(1));
    elseif c == numel(lonVec)
        dZdLon(:,c) = (Z(:,end)-Z(:,end-1)) / (lonVec(end)-lonVec(end-1));
    else
        dZdLon(:,c) = (Z(:,c+1)-Z(:,c-1)) / (lonVec(c+1)-lonVec(c-1));
    end
end
end

function [latMetres,lonMetres] = metresPerDegree(phi)
% WGS84 子午圈/卯酉圈曲率半径转换，支持标量和矩阵纬度。
a = 6378137;
f = 1/298.257223563;
e2 = f*(2-f);
w = 1-e2*sin(phi).^2;
M = a*(1-e2)./w.^(3/2);
N = a./sqrt(w);
latMetres = (pi/180)*M;
lonMetres = (pi/180)*N.*cos(phi);
end
