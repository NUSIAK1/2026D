function dem = loadCoreg3CMDem(demFile, controlPointFile)
%LOADCOREG3CMDEM 读取原始 DEM，并以节点实测高程进行 Coreg3CM 校正。
if ~isfile(demFile), error('未找到 DEM 数据：%s。',demFile); end
if ~isfile(controlPointFile), error('未找到控制点文件：%s。',controlPointFile); end

raw = load(demFile);
required = {'dem','latitude','longitude','nodata','epsg_code','transform'};
for k = 1:numel(required)
    if ~isfield(raw,required{k}), error('DEM MAT 文件缺少变量：%s',required{k}); end
end
Z = double(raw.dem);
nodataVal = double(raw.nodata(1));
Z(Z==nodataVal) = NaN;
lat = double(raw.latitude(:));
lon = double(raw.longitude(:)).';
if lat(1)>lat(end), lat=flipud(lat); Z=flipud(Z); end
if lon(1)>lon(end), lon=fliplr(lon); Z=fliplr(Z); end

nodeRaw = readcell(controlPointFile,'Sheet','数据');
ids = string(nodeRaw(:,1));
mask = (ids=="O01") | startsWith(ids,"S");
controlPoints = [cell2mat(nodeRaw(mask,3)),cell2mat(nodeRaw(mask,4)), ...
    cell2mat(nodeRaw(mask,5))];
if size(controlPoints,1) ~= 16
    error('common:loadCoreg3CMDem:InvalidControls', ...
        '控制点文件必须唯一识别 O01 和 15 个服务区。');
end
[Z,fit] = common.coreg3cmDem(Z,lat,lon,controlPoints);
dem = struct('Z',Z,'Lat',lat,'Lon',lon, ...
    'dLat',mean(diff(lat)),'dLon',mean(diff(lon)), ...
    'epsgCode',double(raw.epsg_code(1)),'nodataVal',nodataVal, ...
    'transform',double(raw.transform(:)).','SourceFile',string(demFile), ...
    'ControlPointFile',string(controlPointFile),'Coreg3CM',fit);
end
