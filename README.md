# 2026D MATLAB 代码仓库

本目录是独立 Git 仓库，只管理源码、测试和代码说明。原始数据保持只读，正式计算产物写入项目级 `结果/`，可再生成缓存写入 `cache/` 且不纳入 Git。

## 目录规则

- `+common/`：跨问题复用的路径、数据预处理和公共物理计算。
- `+problem1/`：问题一独有的组批、Pareto 动态规划、结果导出及测试。
- `+problem2/`：问题二的多点组批、异构机队、共享电池充电周转和 Pareto 调度。
- `+problem3/`：问题三的运输与中继联合调度、连续通信认证及五目标 Pareto 搜索。
- `+problem4/`：固定问题三折中方案的精确任务分区与独立资源配置。
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

% 问题三：先运行单元及全量回归，再执行默认 10 次、总计 3600 s 的搜索
problem3.tests.test_problem3();
resultQ3 = problem3.run_problem3();

% 问题四：读取已生成的问题三完整档案，精确枚举分区与资源需求
problem4.tests.test_problem4();
resultQ4 = problem4.run_problem4();
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

% 问题二：把 20 分钟预算分配给五种目标偏好，每种偏好运行两次。
% 求解器保留初始基线，并从 Pareto 档案构造多样化重启解。
q2Config = struct('NumRuns',10,'MaxIterations',2500,'TimeLimit_s',1200, ...
    'SaveRunArchive',false);
resultQ2 = problem2.run_problem2(q2Config);
```

若要以外部方案作为问题二 ALNS 的初始解，同时提供运输架次表和逐箱交付表：

```matlab
q2Config = struct( ...
    'WarmStartTripFile',"C:\\Users\\Administrator\\Downloads\\表6_Q2运输架次.xlsx", ...
    'WarmStartDeliveryFile',"C:\\Users\\Administrator\\Downloads\\表7_Q2逐箱交付.xlsx", ...
    'SaveRunArchive',false);
resultQ2 = problem2.run_problem2(q2Config);
```

导入时保留货箱分组、机型、访问顺序和表中开始时刻确定的架次顺序；无人机、电池、返回时刻和能耗将按当前物理口径重新计算。原方案单独保留为基线，后续运行会从基线及 Pareto 档案构造不同起点。两个文件必须同时提供，且须精确覆盖全部货箱；导入校验失败会直接报错。

问题二会分别导出及时性、完成时间、能耗、架次数和折中五份官方模板，
不再生成含义不明确的单一提交表。`问题二_多目标调度分析.xlsx` 包含
“代表方案汇总”“收敛记录”“算子诊断”“资源瓶颈”“Pareto架次”和“Pareto逐箱交付”；
完整 Pareto 档案同时写入 `问题二_Pareto完整档案.mat`，可通过
`ExportParetoArchive=false` 关闭。

## 问题三联合调度

`problem3.run_problem3(config)` 从原始表、DEM 和 `flightBase.mat` 读取物理参数；
当前五份问题二提交簿仅用作运输初始解，所有运输资源、链路和中继任务重新计算。
默认随机种子为 2026，最多启动 10 次搜索、每次最多 2500 次迭代，搜索
时间预算为 3600 秒；正在进行的链路预计算或候选校核会在完成后检查时限，
所以实际墙钟时间可能略超预算。`ExportFiles=false` 时不写入正式结果目录。结果为通过连续通信区间
认证的近似 Pareto 解，不表示全局最优。

正式结果保存在项目级 `结果/`：六份 `问题三_结果提交_*.xlsx` 从官方模板复制，
每份的 Q2 和 Q3 四张表来自同一方案；`问题三_多目标联合调度分析.xlsx` 包含
五目标、资源时间线及校核；`问题三_Pareto完整档案.mat` 保存可供问题四继承的
组批、路线、运输与中继任务及通信关系；`问题三_图表/` 保存路线、甘特图、
通信时序、链路保守余量和目标权衡图。只有通过全部硬约束校核的方案才会
填入这些文件。`problem3.verifySubmission(rep,workbook,templateFile)` 可回读
提交簿，逐格核对四张目标表与完整方案及原模板表头。

## 问题四分区与资源配置

`problem4.run_problem4()` 读取问题三 MAT 档案中的折中主方案，核对对应
正式提交簿并重新校核基线。运输同架次和中继同架次保障的服务区构成不可拆
任务块；代码枚举所有 2 组与 3 组分区。运输机、电池、中继机和能源组件
分别按占用、充电或周转区间的最大并发量计算独立执行的最少数量，同时
构造组内实体资源任务链。

运行 `problem4.tests.test_problem4()` 可做小实例穷举对照及全量验收；
`problem4.solveProblem4(struct('ExportFiles',false))` 只求解校核、不写正式结果。
默认运行输出项目级 `结果/问题四_结果提交.xlsx`、
`结果/问题四_分区与资源配置分析.xlsx`、完整 MAT 档案和图表，
并更新 `论文/问题四_救援任务分区与资源配置_算法及结果.md`。
官方提交簿的 Q2/Q3 表保留问题三原任务及编号；问题四各分区重分配后的
资源编号、原编号和“需增配”状态见分析簿“资源任务链”表。

## DEM 航段高程口径

航段经过的 DEM 像元采用二维 Amanatides--Woo 闭合 supercover 遍历：
像元中心坐标为整数、边界为半整数，边界飞行、角点穿越和端点接触的全部
有效像元均纳入最高地形计算。DEM 中的 NoData、NaN、Inf 或越界像元会使
该航段计算直接失败，不会以端点高程或插值结果替代。
