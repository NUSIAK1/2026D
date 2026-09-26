function writeNorthUpGeoTiff(R, lonVec, latVec, tiffFile)
%WRITENORTHUPGEOTIFF 将风险栅格写为北向上的 uint16 TIFF + 世界文件(.tfw)。
%   common.writeNorthUpGeoTiff(R, lonVec, latVec, tiffFile)
%   R 为 numel(latVec)×numel(lonVec)，值域 [0,1]（NaN 视为无数据，写 0）。
%   写入规则网格的北向上 TIFF（首行=最北），并生成同名 .tfw 世界文件，
%   使 QGIS/ArcGIS 可直接按 EPSG:4326 定位。
%
%   说明：本函数仅用 base MATLAB 的 imwrite，不依赖 Mapping 工具箱。
%   数值缩放：uint16 = round(65535*R)，0 兼作"无数据/最低风险"。

validateattributes(R, {'numeric'}, {'real','2d','nonempty'}, mfilename, 'R', 1);
validateattributes(lonVec, {'numeric'}, {'real','vector','increasing'}, mfilename, 'lonVec', 2);
validateattributes(latVec, {'numeric'}, {'real','vector','increasing'}, mfilename, 'latVec', 3);

if ~isequal(size(R), [numel(latVec), numel(lonVec)])
    error('common:writeNorthUpGeoTiff:SizeMismatch', 'R 与 latVec/lonVec 尺寸不一致。');
end

dLon = median(diff(lonVec(:)));
dLat = median(diff(latVec(:)));

% 北向上：首行 = 最北 = latVec(end)
img = flipud(R);
img = max(0, min(1, img));
img(isnan(img)) = 0;
img16 = uint16(round(65535 * img));
imwrite(img16, tiffFile, 'tiff');

% 世界文件 .tfw（6 行，单位：度）
[dir, base, ~] = fileparts(tiffFile);
tfwFile = fullfile(dir, [base, '.tfw']);
lines = {
    sprintf('%.12f', dLon);   % A：像元宽度（经度步长）
    '0.000000000000';         % D：绕 y 轴旋转
    '0.000000000000';         % B：绕 x 轴旋转
    sprintf('%.12f', -dLat);  % E：像元高度（北向上为负）
    sprintf('%.12f', lonVec(1)); % C：左上像元中心经度
    sprintf('%.12f', latVec(end)) % F：左上像元中心纬度
    };
fid = fopen(tfwFile, 'w', 'n', 'UTF-8');
if fid < 0, error('无法写入世界文件：%s', tfwFile); end
for k = 1:numel(lines)
    fprintf(fid, '%s\n', lines{k});
end
fclose(fid);

fprintf('已写出北向上 TIFF：%s\n', tiffFile);
fprintf('已写出世界文件：%s\n', tfwFile);
end
