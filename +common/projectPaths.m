function paths = projectPaths()
%PROJECTPATHS 返回项目的标准路径，不创建或修改任何文件。

commonDir = fileparts(mfilename('fullpath'));
codeDir = fileparts(commonDir);
projectRoot = fileparts(codeDir);
sourceDataDir = fullfile(projectRoot,'原始题目信息','数据');

paths = struct();
paths.ProjectRoot = projectRoot;
paths.CodeDir = codeDir;
paths.SourceDataDir = sourceDataDir;
paths.BaseDataDir = fullfile(sourceDataDir,'无人机应急物资运输基础数据');
paths.GeoDataDir = fullfile(sourceDataDir,'镇龙乡地理空间数据');
paths.NodeFile = fullfile(paths.BaseDataDir,'调度中心与服务区.xlsx');
paths.TransportUavFile = fullfile(paths.BaseDataDir,'运输无人机数据.xlsx');
paths.DemandFile = fullfile(paths.BaseDataDir,'物资需求与配送时限.xlsx');
paths.DemFile = fullfile(paths.GeoDataDir,'镇龙乡及周边地理数据', ...
    '数字高程模型数据（DEM）','镇龙乡及周边30米DEM.mat');
paths.TemplateFile = fullfile(projectRoot,'原始题目信息','结果提交模板.xlsx');
paths.ResultDir = fullfile(projectRoot,'结果');
paths.CacheDir = fullfile(codeDir,'cache');
paths.FlightBaseFile = fullfile(paths.CacheDir,'flightBase.mat');
paths.TerrainResultFile = fullfile(paths.ResultDir,'节点间无人机运输基础参数.xlsx');
end
