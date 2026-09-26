function test_demTraversal()
%TEST_DEMTRAVERSAL Amanatides--Woo 闭合像元遍历与 DEM 高程校核。

testOrdinaryAndAxisAlignedLines();
testBoundaryCornerAndEndpointCoverage();
testSinglePixelReverseAndEdgeClipping();
testInvalidElevationFails();
testCoreg3CMRecovery();
testProjectTerrainMatrix();

fprintf('test_demTraversal: 全部测试通过。\n');
end

function testOrdinaryAndAxisAlignedLines()
assertPixels(common.traceDemSupercover([1,1],[3,2],[4,4]), ...
    [1,1;1,2;2,2;2,3]);
assertPixels(common.traceDemSupercover([1.2,2],[3.8,2],[4,4]), ...
    [2,1;2,2;2,3;2,4]);
assertPixels(common.traceDemSupercover([2,1.2],[2,3.8],[4,4]), ...
    [1,2;2,2;3,2;4,2]);
end

function testBoundaryCornerAndEndpointCoverage()
assertPixels(common.traceDemSupercover([1.2,1.5],[3.8,1.5],[4,4]), ...
    [1,1;1,2;1,3;1,4;2,1;2,2;2,3;2,4]);
assertPixels(common.traceDemSupercover([1,1],[2,2],[4,4]), ...
    [1,1;1,2;2,1;2,2]);
assertPixels(common.traceDemSupercover([1.5,1],[2,1],[4,4]), ...
    [1,1;1,2]);
end

function testSinglePixelReverseAndEdgeClipping()
pixels = common.traceDemSupercover([2.1,2.2],[2.4,2.45],[4,4]);
assertPixels(pixels,[2,2]);
reversePixels = common.traceDemSupercover([2.4,2.45],[2.1,2.2],[4,4]);
assertPixels(reversePixels,pixels);
assertPixels(common.traceDemSupercover([0.5,1],[0.5,3],[4,4]), ...
    [1,1;2,1;3,1]);
end

function testInvalidElevationFails()
Z = reshape(1:9,3,3);
Z(2,2) = NaN;
assertThrows(@() common.maxDemOnPath(Z,[1,1;2,2],"O01","S001"), ...
    'common:maxDemOnPath:InvalidElevation');
assertThrows(@() common.maxDemOnPath(Z,[4,1],"O01","S001"), ...
    'common:maxDemOnPath:PixelOutOfRange');
end

function testCoreg3CMRecovery()
% 人工平面在任意控制点上的水平位移/垂直偏移应能被精确反演。
lat = (30:0.001:30.010)';
lon = (110:0.001:110.010);
[lonGrid,latGrid] = meshgrid(lon,lat);
metresLat = 110852; metresLon = 96486;
xKm = (lonGrid-110)*metresLon/1000;
yKm = (latGrid-30)*metresLat/1000;
Z = 400 + 120*xKm - 80*yKm + 10*xKm.*yKm;
points = [110.002,30.002;110.008,30.003;110.003,30.008; ...
    110.007,30.007;110.005,30.004];
raw = interp2(lon,lat,Z,points(:,1),points(:,2),'linear');
dx = 7.5; dy = -4.0; dz = 2.25;
xPoint = (points(:,1)-110)*metresLon/1000;
yPoint = (points(:,2)-30)*metresLat/1000;
gradE = 0.12 + 0.01*yPoint;
gradN = -0.08 + 0.01*xPoint;
observed = raw - gradE*dx - gradN*dy + dz;
[~,fit] = common.coreg3cmDem(Z,lat,lon,[points,observed]);
assert(abs(fit.DX_m-dx)<0.03 && abs(fit.DY_m-dy)<0.03 && ...
    abs(fit.DZ_m-dz)<0.03 && fit.RMSE_m<1e-5, ...
    'Coreg3CM 未能正确反演人工 DEM 的 DX、DY、DZ。');
end

function testProjectTerrainMatrix()
paths = common.projectPaths();
tempBase = [tempname,'.mat'];
cleanupObj = onCleanup(@() deleteIfExists(tempBase)); %#ok<NASGU>
options = struct('ShowFigure',false,'WriteResultXlsx',false, ...
    'FlightBaseFile',tempBase);
flightBase = common.computeTerrainMatrices(options);

assert(isequal(size(flightBase.D),[16,16]),'基础矩阵必须为 16×16。');
assert(isequal(size(flightBase.HterrainMax),[16,16]));
assert(max(abs(flightBase.HterrainMax-flightBase.HterrainMax'),[],'all') < 1e-9);
assert(max(abs(flightBase.Hcruise-flightBase.Hcruise'),[],'all') < 1e-9);
offDiagonal = ~eye(16);
delta = flightBase.Hcruise-flightBase.HterrainMax-50;
assert(max(abs(delta(offDiagonal))) < 1e-9);
assert(max(abs(flightBase.Hup-flightBase.Hdown'),[],'all') < 1e-9);
assert(all(diag(flightBase.Hup)==0) && all(diag(flightBase.Hdown)==0));

assert(isfield(flightBase,'dem') && flightBase.dem.Coreg3CM.RMSE_m >= 0, ...
    '基础矩阵应记录 Coreg3CM 的拟合结果。');
assert(isfile(paths.DemFile),'DEM 数据文件不存在。');
end

function assertPixels(actual,expected)
actual = sortrows(actual,[1,2]);
expected = sortrows(expected,[1,2]);
assert(isequal(actual,expected),'闭合 supercover 像元集合不符合预期。');
end

function assertThrows(func,identifier)
didThrow = false;
try
    func();
catch ME
    didThrow = true;
    assert(strcmp(ME.identifier,identifier), ...
        '异常标识应为 %s，实际为 %s。',identifier,ME.identifier);
end
assert(didThrow,'预期应抛出异常 %s。',identifier);
end

function deleteIfExists(filePath)
if isfile(filePath)
    delete(filePath);
end
end
