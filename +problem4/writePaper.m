function path=writePaper(result,data)
%WRITEPAPER 根据求解数据生成可复算的中文论文材料。
root=fileparts(result.Config.ResultDir);
paperDir=fullfile(root,'论文');
if ~exist(paperDir,'dir'), mkdir(paperDir); end
path=fullfile(paperDir,'问题四_救援任务分区与资源配置_算法及结果.md');
L=strings(0,1);
    function add(line)
        L(end+1,1)=string(line); %#ok<AGROW>
    end
add('# 问题四 救援任务分区与资源配置优化');
add('');
add('## 1 数据继承与研究边界');
add('');
add('以问题三完整 MAT 档案的折中主方案为基线：15 个服务区、80 个货箱、22 个运输架次、3 个中继架次。先将该档案与问题三正式提交簿逐格比对，再独立复核问题三的运输、能源及连续通信约束。问题四固定全部原任务的组批、机型、路线、开始及结束时刻、中继悬停方案和通信保障关系；仅决定服务区分组及同型号资源在组内的重新分配。');
add('');
add('官方提交簿的 Q2/Q3 四表保留问题三原任务及原编号，作为任务继承依据。新分区的组内资源编号与原编号的逐架次映射在问题四分析簿“资源任务链”表中；两种分区的映射分别列示。');
add('');
add('## 2 模型与算法');
add('');
add('令服务区集合为 V。若两个服务区位于同一运输架次，或由同一中继架次保障的运输任务涉及，则两区之间建立绑定边；取该图的连通分量作为不可拆任务块。对 K=2、3 使用受限增长序列枚举无标签的非空分区，避免交换组号产生重复解。');
add('');
add('对某组 g 和资源类别 r，将每次任务表示为半开占用区间 I=[s,a)。运输无人机的 a 为返航时刻；运输电池的 a 为返航加充满时间；中继无人机的 a 为返航加架次周转时间；中继能源组件的 a 为返航加充满时间。电池与组件的充电时间调用公共两阶段 SOC 函数，满电后才可再次使用。');
add('');
add('令 N(g,r)=max_t Σ_{i∈任务(g,r)} 1{s_i≤t<a_i}。该最大重叠数是独立执行的资源需求下界。按开始时刻依次将任务放入已释放的最早资源槽位；若没有可复用槽位则新增一个。区间图的贪心着色恰好使用 N(g,r) 个槽位，故构造与下界一致，所得数量在固定时间线下为全局最小。所有资源编号仅属于一个组。');
add('');
add('各资源类别库存 Q_r 直接来自原始运输与中继参数表。分区总需求为 N_r=Σ_g N(g,r)，缺口为 max(N_r−Q_r,0)，余量为 max(Q_r−N_r,0)。分区新增需求是 N_r 减去相同任务在不分组情况下的最少需求。工作量 W_g=Σ运输架次(返航−开始)+Σ中继架次(返航−开始)，均衡指标为总体标准差除以各组平均工作量；另列货箱、质量、能耗和架次数。');
add('');
add('二组推荐方案按如下字典序选择：① Σ_r 缺口_r/Q_r；② Σ_r N_r/Q_r；③ 工作量变异系数；完全相同按服务区编号顺序稳定选择。候选解还按这三个指标计算 Pareto 支配关系。此选择是题目未规定单一权重时的明确决策口径。');
add('');
add('算法步骤：读取并核验主方案 → 建立运输与中继绑定边 → 求连通任务块 → 枚举 K=2、3 分区 → 为各组各类资源计算区间峰值和最优槽位分配 → 统计库存缺口与工作量 → 按字典序选择并独立校核 → 回读正式提交簿。');
add('');
add('## 3 不可拆任务块与候选');
add('');
add('| 任务块 | 服务区 | 运输架次 | 中继架次 |');
add('| --- | --- | ---: | ---: |');
for b=1:numel(result.Blocks)
    x=result.Blocks(b);
    add(sprintf('| %s | %s | %d | %d |',x.BlockID, ...
        strjoin(x.Services,', '),numel(x.TripIDs),numel(x.RelayTripIDs)));
end
add('');
add('三个不可拆块使二组只有 3 种不同分法，三组只有 1 种不同分法，因此以下比较覆盖了严格继承口径下的全部候选。');
add('');
add('| 方案 | 任务块分配 | 缺口总量 | 库存归一化缺口 | 工作量变异系数 |');
add('| --- | --- | ---: | ---: | ---: |');
for k=1:numel(result.Candidates)
    x=result.Candidates(k);
    blockText=strings(1,x.K);
    for g=1:x.K
        blockText(g)="G"+sprintf('%02d',g)+"="+ ...
            strjoin([result.Blocks(x.Partition{g}).BlockID],'+');
    end
    add(sprintf('| %s | %s | %d | %.4f | %.4f |',x.ID, ...
        strjoin(blockText,'；'),sum(x.Deficit),x.Score(1),x.WorkCV));
end
add('');
add('## 4 推荐分区与资源配置');
add('');
for kk=1:2
    if kk==1, x=result.Selected2; else, x=result.Selected3; end
    add(sprintf('### %d 组方案 %s',x.K,x.ID));
    add('');
    add('| 组别 | 服务区 | 运输架次 | 中继架次 | 货箱 | 工作量 s |');
    add('| --- | --- | ---: | ---: | ---: | ---: |');
    for g=1:x.K
        q=x.Group(g,:);
        add(sprintf('| G%02d | %s | %d | %d | %d | %.3f |',g, ...
            q.Services,q.TransportTrips,q.RelayTrips,q.BoxCount,q.Work_s));
    end
    add('');
    add('| 资源类别 | 原库存 | 最少总需求 | 缺口 | 剩余 | 分区新增 |');
    add('| --- | ---: | ---: | ---: | ---: | ---: |');
    for j=1:height(result.Baseline)
        stock=result.Baseline.Inventory(j);
        add(sprintf('| %s | %d | %d | %d | %d | %d |', ...
            result.Baseline.Type(j),stock,x.Totals(j),x.Deficit(j), ...
            max(stock-x.Totals(j),0),x.Extra(j)));
    end
    add('');
    add(sprintf('本方案工作量变异系数 %.4f；总缺口 %d 件，分区新增 %d 件。', ...
        x.WorkCV,sum(x.Deficit),sum(x.Extra)));
    add('');
end
add('## 5 缺口原因与结论');
add('');
add('二组推荐方案将前两个大型任务块合并为 G01，S011 独立为 G02。原计划中这两个任务块可以跨任务块复用部分资源；独立执行后，S011 的 T011 需要单独占用 1 架 B 型运输机及 1 组 B 型电池，分别形成 1 件缺口。该方案以较低配置代价换取明显的组间工作量不均衡。其余两种二组分法工作量更均衡，但分别产生 11 件与 12 件总缺口，因而在已约定的缺口优先规则下不被选为主方案。');
add('');
add('三组方案必须让三个不可拆块分别执行。A/B/C 型运输机分别需 5/5/4 架，对比库存 4/2/2 架；对应电池分别需 7/7/6 组，对比库存 6/4/4 组；中继机需 3 架，对比库存 2 架，能源组件需 3 组且库存为 6 组。总缺口为 13 件，来源于任务时间重叠、充电及周转占用，以及禁止跨组复用。每项资源的峰值时刻与造成峰值的架次列在分析簿“组内资源峰值”表，可逐项追溯。');
add('');
add('该结果对固定的问题三折中方案及严格任务继承口径精确成立。问题三方案本身属于经验证的近似 Pareto 解，因此不声称整个四问联合优化问题达到全局最优。');
add('');
add('## 6 复算与校核');
add('');
add('从代码目录运行 `problem4.tests.test_problem4()`，再运行 `resultQ4=problem4.run_problem4()`。前者以小实例穷举对照区间着色，并核对全部真实任务；后者重新生成官方提交簿、分析簿、MAT 档案和图表。正式结果经过服务区、任务继承、组内资源互斥、最少资源峰值、库存缺口及提交簿逐格回读校核。');
add('');
add('图表：`../结果/问题四_图表/任务分区地图.png`、`资源需求与库存.png`、`组间工作量.png`、`2组资源任务链甘特图.png` 和 `3组资源任务链甘特图.png`。');
fid=fopen(path,'w','n','UTF-8');
assert(fid>0,'无法创建问题四论文材料。');
cleanup=onCleanup(@()fclose(fid)); %#ok<NASGU>
fprintf(fid,'%s',char(strjoin(L,newline)+newline));
end
