function files=exportResults(result,input)
%EXPORTRESULTS 复制官方模板，输出问题四提交簿、分析、档案和图表。
c=result.Config; rep=input.Rep;
if ~exist(c.ResultDir,'dir'), mkdir(c.ResultDir); end
files=struct();
submission=fullfile(c.ResultDir,'问题四_结果提交.xlsx');
[ok,msg]=copyfile(c.TemplateFile,submission,'f');
assert(ok,'复制官方模板失败：%s',msg);
trips=sortrows(rep.Transport.Trips,{'Start_s','TripID'});
official=trips(:,{'TripID','DroneID','Model','BatteryID','Start_s', ...
    'Route','Return_s','Energy_kWh'});
writetable(official,submission,'Sheet','Q2_运输架次', ...
    'Range','A2','WriteVariableNames',false);
delivery=sortrows(rep.Transport.Deliveries,'BoxID');
writetable(delivery(:,{'BoxID','TripID','ServiceID','Delivery_s'}), ...
    submission,'Sheet','Q2_逐箱交付','Range','A2', ...
    'WriteVariableNames',false);
relay=sortrows(rep.Relay.RelayTrips,{'Start_s','RelayTripID'});
writetable(relay(:,{'RelayTripID','RelayID','ComponentID','Start_s', ...
    'HoverLon_deg','HoverLat_deg','HoverAlt_m','LinkReady_s', ...
    'ServiceEnd_s','Return_s','Energy_kWh'}), ...
    submission,'Sheet','Q3_中继架次','Range','A2', ...
    'WriteVariableNames',false);
coverage=sortrows(rep.Coverage,{'TripID','Start_s'});
writetable(coverage(:,{'TripID','Phase','Start_s','End_s','Mode', ...
    'RelayTripID'}),submission,'Sheet','Q3_通信保障', ...
    'Range','A2','WriteVariableNames',false);
selected=[result.Selected2,result.Selected3];
rows=table();
for s=1:numel(selected)
    x=selected(s);
    for g=1:x.K
        r=x.Resource(x.Resource.GroupID==g,:);
        counts=zeros(1,8);
        for j=1:8, counts(j)=r.Required(j); end
        row=table(x.K,"G"+sprintf('%02d',g),x.Group.Services(g), ...
            counts(1),counts(2),counts(3),counts(4),counts(5), ...
            counts(6),counts(7),counts(8), ...
            'VariableNames',{'K','GroupID','Services','A_U','B_U','C_U', ...
            'A_BAT','B_BAT','C_BAT','R_U','R_COMP'});
        rows=[rows;row]; %#ok<AGROW>
    end
end
writetable(rows,submission,'Sheet','Q4_分区配置','Range','A2', ...
    'WriteVariableNames',false);
sourceCheck=problem3.verifySubmission(rep,submission,c.TemplateFile);
assert(sourceCheck.Feasible,'问题四提交簿的 Q2/Q3 继承内容回读失败。');
q4Header=readcell(c.TemplateFile,'Sheet','Q4_分区配置','Range','A1:K1');
actualHeader=readcell(submission,'Sheet','Q4_分区配置','Range','A1:K1');
assert(isequal(string(q4Header),string(actualHeader)), ...
    '问题四提交表头与官方模板不同。');
actual=readcell(submission,'Sheet','Q4_分区配置','Range','A2:K6');
expected=table2cell(rows);
for i=1:size(expected,1)
    for j=1:size(expected,2)
        if isnumeric(expected{i,j})
            assert(isnumeric(actual{i,j}) && ...
                abs(actual{i,j}-expected{i,j})<1e-8, ...
                '问题四提交簿第 %d 行第 %d 列数值错误。',i,j);
        else
            assert(string(actual{i,j})==string(expected{i,j}), ...
                '问题四提交簿第 %d 行第 %d 列文本错误。',i,j);
        end
    end
end
allRows=readcell(submission,'Sheet','Q4_分区配置');
assert(nnz(~cellfun(@blankCell,allRows(2:end,1)))==5, ...
    '问题四提交簿必须恰有五条分组记录。');
files.Submission=submission;

analysis=fullfile(c.ResultDir,'问题四_分区与资源配置分析.xlsx');
if isfile(analysis), delete(analysis); end
writetable(result.Summary,analysis,'Sheet','候选方案');
writetable(result.Groups,analysis,'Sheet','组间工作量');
writetable(result.Resources,analysis,'Sheet','组内资源峰值');
writetable(resourceComparison(result),analysis,'Sheet','库存与缺口');
writetable(result.Baseline,analysis,'Sheet','不分组基线');
writetable(result.Assignments,analysis,'Sheet','资源任务链');
writetable(result.Validation.Checks,analysis,'Sheet','独立校核');
writetable(sourceCheck.Checks,analysis,'Sheet','提交回读校核');
files.Analysis=analysis;

archive=fullfile(c.ResultDir,'问题四_完整分区档案.mat');
save(archive,'result','-v7.3'); files.Archive=archive;
files.Paper=problem4.writePaper(result,input.Data);
if c.ExportFigures
    files.Figures=figures(result,input.Data,c.ResultDir);
end
end

function yes=blankCell(x)
yes=isempty(x) || (isnumeric(x) && isscalar(x) && isnan(x)) || ...
    (isstring(x) && (ismissing(x) || x==""));
end

function rows=resourceComparison(result)
rows=table();
for i=1:numel(result.Candidates)
    x=result.Candidates(i);
    for j=1:height(result.Baseline)
        baseline=result.Baseline(j,:);
        stock=baseline.Inventory;
        row=table(x.ID,x.K,baseline.Type,x.Totals(j),stock, ...
            max(x.Totals(j)-stock,0),max(stock-x.Totals(j),0), ...
            x.Extra(j), ...
            'VariableNames',{'PartitionID','K','Type','Required', ...
            'Inventory','Shortfall','Surplus','ExtraVsUnpartitioned'});
        rows=[rows;row]; %#ok<AGROW>
    end
end
end

function files=figures(result,data,resultDir)
dir=fullfile(resultDir,'问题四_图表');
if ~exist(dir,'dir'), mkdir(dir); end
files=struct();
f=figure('Visible','off','Position',[100,100,1280,540]);
selected=[result.Selected2,result.Selected3];
for k=1:2
    subplot(1,2,k); hold on;
    x=selected(k);
    handles=gobjects(x.K,1);
    for g=1:x.K
        ss=split(x.Group.Services(g),',');
        mask=ismember(data.Nodes.ID,ss);
        handles(g)=scatter(data.Nodes.Lon(mask),data.Nodes.Lat(mask),70,'filled');
    end
    hub=data.Nodes(data.Nodes.ID=="O01",:);
    plot(hub.Lon,hub.Lat,'kp','MarkerFaceColor','k','MarkerSize',10);
    for j=1:height(data.Nodes)
        text(data.Nodes.Lon(j),data.Nodes.Lat(j)," "+data.Nodes.ID(j), ...
            'FontSize',8);
    end
    xlabel('经度');ylabel('纬度');title(sprintf('%d 组任务分区',x.K)); grid on;
    legend(handles,compose('G%02d',(1:x.K)'), 'Location','best');
end
files.Partition=fullfile(dir,'任务分区地图.png');
exportgraphics(f,files.Partition,'Resolution',180); close(f);

f=figure('Visible','off','Position',[100,100,1300,700]);
for k=1:2
    subplot(2,1,k); x=selected(k);
    bar([x.Totals;result.Baseline.Inventory']');
    set(gca,'XTick',1:8,'XTickLabel',result.Baseline.Type);
    set(gca,'TickLabelInterpreter','none');
    ylabel('数量');title(sprintf('%d 组配置与现有库存',x.K));
    legend('需求','库存','Location','northwest');grid on;
end
files.Inventory=fullfile(dir,'资源需求与库存.png');
exportgraphics(f,files.Inventory,'Resolution',180); close(f);

f=figure('Visible','off','Position',[100,100,1050,560]);
work=[result.Selected2.Group.Work_s;NaN;result.Selected3.Group.Work_s];
bar(work); ylabel('累计任务作业时间 s');grid on;
set(gca,'XTick',1:numel(work), ...
    'XTickLabel',{'2组 G01','2组 G02','','3组 G01','3组 G02','3组 G03'});
title('组间工作量比较');
files.Workload=fullfile(dir,'组间工作量.png');
exportgraphics(f,files.Workload,'Resolution',180); close(f);

for k=1:2
    a=selected(k).Allocation;
    ids=unique(a.AssignedResourceID,'stable');
    f=figure('Visible','off', ...
        'Position',[100,100,1450,max(560,35*numel(ids)+130)]);
    hold on; colors=lines(selected(k).K);
    for j=1:height(a)
        y=find(ids==a.AssignedResourceID(j),1);
        plot([a.Start_s(j),a.Available_s(j)],[y,y],'-', ...
            'LineWidth',5,'Color',colors(a.GroupID(j),:));
    end
    labels=strings(numel(ids),1);
    for j=1:numel(ids)
        idx=find(a.AssignedResourceID==ids(j),1);
        labels(j)="G"+sprintf('%02d',a.GroupID(idx))+"  "+ids(j);
    end
    set(gca,'YTick',1:numel(ids),'YTickLabel',labels,'FontSize',9, ...
        'TickLabelInterpreter','none');
    ylim([0,numel(ids)+1]);
    xlabel('时刻 s');ylabel('组内独占资源');
    title(sprintf('%d 组资源占用与充电/周转',selected(k).K));grid on;
    files.(sprintf('TimelineK%d',selected(k).K))= ...
        fullfile(dir,sprintf('%d组资源任务链甘特图.png',selected(k).K));
    exportgraphics(f,files.(sprintf('TimelineK%d',selected(k).K)), ...
        'Resolution',180);close(f);
end
old=fullfile(dir,'资源任务链甘特图.png');
if isfile(old), delete(old); end
end
