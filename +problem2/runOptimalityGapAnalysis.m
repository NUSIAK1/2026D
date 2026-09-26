function result = runOptimalityGapAnalysis(config)
%RUNOPTIMALITYGAPANALYSIS 生成 Q2/Q3 可证下界与启发式最优间隙表。
if nargin<1, config=struct(); end
p=common.projectPaths();
config=defaults(config,struct( ...
    'Q2ArchiveFile',fullfile(p.ResultDir,'问题二_Pareto完整档案.mat'), ...
    'Q3ArchiveFile',fullfile(p.ResultDir,'问题三_Pareto完整档案.mat'), ...
    'OutputFile',fullfile(p.ResultDir,'问题二三_可证下界与最优间隙.xlsx'), ...
    'FlightBaseFile',p.FlightBaseFile,'DemandFile',p.DemandFile, ...
    'TransportUavFile',p.TransportUavFile));

bounds=common.computeTransportLowerBounds(config);
q2=readFront(config.Q2ArchiveFile,"Q2");
q3=readFront(config.Q3ArchiveFile,"Q3");

rows=cell(0,8);
rows(end+1,:)=gapRow("Q2","及时性",bounds.Timeliness,min(q2.Timeliness),"0","无负延误");
rows(end+1,:)=gapRow("Q2","完成时间",bounds.Makespan_s,min(q2.Makespan_s),"s", ...
    "无限资源关键路径与受限机队工作量对偶界取大");
rows(end+1,:)=gapRow("Q2","总能耗",bounds.Energy_kWh,min(q2.Energy_kWh),"kWh", ...
    "空载连通(MST与最少架次×最短往返取大) + 水平载荷增量");
rows(end+1,:)=gapRow("Q2","运输架次",bounds.TransportTripCount,min(q2.TripCount),"趟", ...
    "质量/体积/不相容团容量松弛");
rows(end+1,:)=gapRow("Q3","及时性",bounds.Timeliness,min(q3.Timeliness),"0","无负延误");
rows(end+1,:)=gapRow("Q3","联合完成时间",bounds.Makespan_s,min(q3.JointMakespan_s),"s", ...
    "忽略通信与中继后的运输关键路径/机队工作量界");
rows(end+1,:)=gapRow("Q3","总能耗",bounds.Energy_kWh,min(q3.TotalEnergy_kWh),"kWh", ...
    "运输能耗下界 + 中继非负能耗");
rows(end+1,:)=gapRow("Q3","运输架次",bounds.TransportTripCount,min(q3.TransportTripCount),"趟", ...
    "质量/体积/不相容团容量松弛");
rows(end+1,:)=gapRow("Q3","中继架次",bounds.RelayTripCount,min(q3.RelayTripCount),"趟", ...
    "删除全部通信约束（严格但较弱）");
gapTable=cell2table(rows,'VariableNames',{'Problem','Objective','LowerBound', ...
    'BestHeuristic','AbsoluteGap','GapOverHeuristic_pct','CertifiedGapOverLB_pct','Method'});

notes=table( ...
    ["口径";"GapOverHeuristic_pct";"CertifiedGapOverLB_pct";"逐箱直送和";"逐服务区装箱和";"Q3 中继架次"], ...
    ["每个目标使用现有 Pareto 档案中的单目标最好值，不能拼成一个实际方案。"; ...
     "(启发式上界-下界)/启发式上界；表示当前上下界区间占启发式值的比例。"; ...
     "(启发式上界-下界)/下界；下界为 0 时记为 NaN。"; ...
     "因重复计算机体往返基础能耗，可能高于合并运输方案，未作为下界。"; ...
     "Q2 允许一趟访问多个服务区，逐区最少箱数不能相加；这里只取逐区界的最大值。"; ...
     "当前采用删除通信约束后的 0 下界，严格成立但不能说明中继目标的接近程度。"], ...
    'VariableNames',{'Item','Explanation'});

if isfile(config.OutputFile), delete(config.OutputFile); end
writetable(gapTable,config.OutputFile,'Sheet','最优间隙');
writetable(bounds.Components,config.OutputFile,'Sheet','下界分解');
writetable(bounds.BoxAudit,config.OutputFile,'Sheet','逐箱审计');
writetable(bounds.MSTEdges,config.OutputFile,'Sheet','MST审计');
writetable(bounds.WorkloadAudit,config.OutputFile,'Sheet','工作量对偶审计');
writetable(table(bounds.IncompatibleCliqueBoxes,'VariableNames',{'BoxID'}), ...
    config.OutputFile,'Sheet','不相容团');
writetable(notes,config.OutputFile,'Sheet','口径说明');

result=struct('Bounds',bounds,'GapTable',gapTable,'Notes',notes, ...
    'OutputFile',config.OutputFile,'Q2Front',q2,'Q3Front',q3,'Config',config);
fprintf('可证下界与最优间隙已写入：%s\n',config.OutputFile);
disp(gapTable);
end

function front=readFront(file,problem)
assert(isfile(file),'未找到 %s Pareto 档案：%s',problem,file);
s=load(file);
if isfield(s,'paretoArchive'), a=s.paretoArchive;
elseif isfield(s,'saved'), a=s.saved;
else, error('%s 档案不含 paretoArchive 或 saved。',problem); end
assert(isfield(a,'ParetoFront') && istable(a.ParetoFront) && ~isempty(a.ParetoFront), ...
    '%s ParetoFront 为空。',problem);
front=a.ParetoFront;
end

function row=gapRow(problem,objective,lb,ub,unit,method)
assert(isfinite(lb) && isfinite(ub) && lb<=ub+1e-7, ...
    '%s/%s 的下界 %.12g 高于启发式值 %.12g，请检查证明或数据口径。',problem,objective,lb,ub);
absolute=max(0,ub-lb);
if abs(ub)>1e-12, overHeuristic=100*absolute/abs(ub); else, overHeuristic=0; end
if abs(lb)>1e-12, certified=100*absolute/abs(lb); else, certified=NaN; end
row={problem,objective+"（"+unit+"）",lb,ub,absolute,overHeuristic,certified,method};
end

function out=defaults(in,d)
out=in; names=fieldnames(d);
for k=1:numel(names)
    if ~isfield(out,names{k}) || isempty(out.(names{k})), out.(names{k})=d.(names{k}); end
end
end
