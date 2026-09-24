# 2026D MATLAB 代码仓库

本目录是独立 Git 仓库，只管理源码、测试和代码说明。原始数据保持只读，正式计算产物写入项目级 `结果/`，可再生成缓存写入 `cache/` 且不纳入 Git。

## 目录规则

- `+common/`：跨问题复用的路径、数据预处理和公共物理计算。
- `+problem1/`：问题一独有的组批、Pareto 动态规划、结果导出及测试。
- `+problem2/`：问题二的多点组批、异构机队、共享电池充电周转和 Pareto 调度。
- `cache/`：运行时缓存，目前为 `flightBase.mat`。

问题二至问题四开发时分别新建 `+problem2/`、`+problem3/`、`+problem4/`。只有已经跨问题复用，或明确属于公共物理、数据和路径层的代码才应放入 `+common/`。

## 标准运行方式

在 MATLAB 中将当前目录切换到本目录：

```matlab
% 先在临时路径验证 DEM 闭合 supercover 遍历与基础矩阵
common.tests.test_demTraversal();

% 问题一测试
problem1.tests.test_problem1();

% 验证通过后，正式覆盖共享基础矩阵和基础参数表
common.computeTerrainMatrices();

% 生成问题一正式结果
result = problem1.run_problem1();

% 问题二（首次运行前须已生成 flightBase.mat）
problem2.tests.test_problem2();
resultQ2 = problem2.run_problem2(struct('SaveRunArchive',false));
```

不需要将包子目录递归加入 MATLAB 路径；只需要让 `代码/` 本身位于当前目录或 MATLAB 路径中。

## 常用可选项

```matlab
options = struct( ...
    'ShowFigure',false, ...
    'WriteResultXlsx',false, ...
    'FlightBaseFile',fullfile(tempdir,'flightBase.mat'));
flightBase = common.computeTerrainMatrices(options);

result = problem1.run_problem1(struct('ExportFiles',false));
```

## DEM 航段高程口径

航段经过的 DEM 像元采用二维 Amanatides--Woo 闭合 supercover 遍历：
像元中心坐标为整数、边界为半整数，边界飞行、角点穿越和端点接触的全部
有效像元均纳入最高地形计算。DEM 中的 NoData、NaN、Inf 或越界像元会使
该航段计算直接失败，不会以端点高程或插值结果替代。
