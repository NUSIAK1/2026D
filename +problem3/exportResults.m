function files = exportResults(result,data,config)
%EXPORTRESULTS 校核通过后复制官方模板，并输出分析表与论文取数图。
if ~exist(config.ResultDir,'dir'), mkdir(config.ResultDir); end
names=fieldnames(result.Representatives);
labels=struct('TimelinessFirst',"及时性优先",'MakespanFirst',"完成时间优先", ...
    'EnergyFirst',"能耗优先",'TransportTripsFirst',"运输架次数优先", ...
    'RelayTripsFirst',"中继架次数优先",'Balanced',"折中方案");
files=struct(); files.Submissions=struct();
for k=1:numel(names)
    name=names{k}; rep=result.Representatives.(name);
    if ~rep.Validation.Feasible
        error('代表方案 %s 未通过校核，不允许导出。',name);
    end
    file=fullfile(config.ResultDir,"问题三_结果提交_"+labels.(name)+".xlsx");
    [ok,msg]=copyfile(config.TemplateFile,file,'f');
    if ~ok, error('复制官方提交模板失败：%s',msg); end
    trip=sortrows(rep.Transport.Trips,{'Start_s','TripID'});
    official=trip(:,{'TripID','DroneID','Model','BatteryID','Start_s', ...
        'Route','Return_s','Energy_kWh'});
    writetable(official,file,'Sheet','Q2_运输架次','Range','A2', ...
        'WriteVariableNames',false);
    delivery=sortrows(rep.Transport.Deliveries,'BoxID');
    official=delivery(:,{'BoxID','TripID','ServiceID','Delivery_s'});
    writetable(official,file,'Sheet','Q2_逐箱交付','Range','A2', ...
        'WriteVariableNames',false);
    official=sortrows(rep.Relay.RelayTrips,{'Start_s','RelayTripID'});
    official=official(:,{'RelayTripID','RelayID','ComponentID','Start_s', ...
        'HoverLon_deg','HoverLat_deg','HoverAlt_m','LinkReady_s', ...
        'ServiceEnd_s','Return_s','Energy_kWh'});
    if ~isempty(official)
        writetable(official,file,'Sheet','Q3_中继架次','Range','A2', ...
            'WriteVariableNames',false);
    end
    coverage=sortrows(rep.Coverage,{'TripID','Start_s'});
    official=coverage(:,{'TripID','Phase','Start_s','End_s','Mode','RelayTripID'});
    writetable(official,file,'Sheet','Q3_通信保障','Range','A2', ...
        'WriteVariableNames',false);
    files.Submissions.(name)=file;
end
analysis=fullfile(config.ResultDir,'问题三_多目标联合调度分析.xlsx');
if isfile(analysis), delete(analysis); end
writetable(result.ParetoFront,analysis,'Sheet','Pareto前沿');
summary=representativeSummary(result);
writetable(summary,analysis,'Sheet','代表方案汇总');
balanced=result.Representatives.Balanced;
writetable(balanced.Transport.Trips,analysis,'Sheet','主方案运输架次');
writetable(balanced.Transport.Deliveries,analysis,'Sheet','主方案逐箱交付');
writetable(balanced.Relay.RelayTrips,analysis,'Sheet','主方案中继架次');
writetable(balanced.Coverage,analysis,'Sheet','主方案通信保障');
writetable(balanced.Transport.DroneTimeline,analysis,'Sheet','运输机占用');
writetable(balanced.Transport.BatteryTimeline,analysis,'Sheet','运输电池周转');
if ~isempty(balanced.Relay.RelayTrips)
    writetable(balanced.Relay.DroneTimeline,analysis,'Sheet','中继机占用');
    writetable(balanced.Relay.ComponentTimeline,analysis,'Sheet','中继组件周转');
end
writetable(balanced.Validation.Checks,analysis,'Sheet','校核');
writetable(result.RunLog,analysis,'Sheet','运行记录');
if ~isempty(result.OperatorLog)
    writetable(result.OperatorLog,analysis,'Sheet','算子诊断');
end
files.Analysis=analysis;
archive=fullfile(config.ResultDir,'问题三_Pareto完整档案.mat');
saved=struct('Config',result.Config,'ParetoFront',result.ParetoFront, ...
    'ParetoSolutions',{result.ParetoSolutions},'ParetoOutcomes',{result.ParetoOutcomes}, ...
    'Representatives',result.Representatives,'RunLog',result.RunLog, ...
    'OperatorLog',result.OperatorLog, ...
    'InputFiles',struct('FlightBase',config.FlightBaseFile,'DEM',config.DemFile, ...
    'Demand',config.DemandFile,'Transport',config.TransportUavFile, ...
    'Relay',config.RelayUavFile,'Communication',config.CommFile));
save(archive,'saved','-v7.3'); files.Archive=archive;
if config.ExportFigures
    files.Figures=makeFigures(balanced,data,result,config.ResultDir);
end
end

function T=representativeSummary(result)
names=fieldnames(result.Representatives);
T=table();
for k=1:numel(names)
    r=result.Representatives.(names{k}); x=r.Validation.Objectives;
    row=table(string(names{k}),x(1),x(2),x(3),x(4),x(5), ...
        'VariableNames',{'Representative','Timeliness','JointMakespan_s', ...
        'TotalEnergy_kWh','TransportTripCount','RelayTripCount'});
    T=[T;row]; %#ok<AGROW>
end
end

function files=makeFigures(rep,data,result,resultDir)
dir=fullfile(resultDir,'问题三_图表');
if ~exist(dir,'dir'), mkdir(dir); end
files=struct();
try
    f=figure('Visible','off'); hold on;
    scatter(data.Nodes.Lon,data.Nodes.Lat,32,'k','filled');
    for i=1:numel(rep.Transport.Phases)
        p=rep.Transport.Phases(i);
        if p.Phase=="巡航"
            plot([p.A(1),p.B(1)],[p.A(2),p.B(2)],'b-');
        end
    end
    R=rep.Relay.RelayTrips;
    if ~isempty(R)
        scatter(R.HoverLon_deg,R.HoverLat_deg,70,'r','filled');
        o=data.Nodes(data.Nodes.ID=="O01",:);
        for k=1:height(R)
            plot([o.Lon,R.HoverLon_deg(k)],[o.Lat,R.HoverLat_deg(k)],'r--');
        end
    end
    xlabel('经度（°）');ylabel('纬度（°）');title('问题三运输与中继路线');grid on;
    files.Routes=fullfile(dir,'联合路线.png');
    exportgraphics(f,files.Routes,'Resolution',180);close(f);
catch ME
    warning('问题三路线图导出失败：%s',ME.message);
end
try
    f=figure('Visible','off');hold on;
    drawTimeline(rep.Transport.DroneTimeline,1,[0.2,0.45,0.8]);
    drawTimeline(rep.Relay.DroneTimeline,height(data.Drones)+2,[0.85,0.3,0.25]);
    xlabel('时刻（s）');ylabel('实体无人机序号');title('运输与中继无人机占用');grid on;
    files.Drones=fullfile(dir,'无人机甘特图.png');
    exportgraphics(f,files.Drones,'Resolution',180);close(f);
catch ME
    warning('问题三无人机甘特图导出失败：%s',ME.message);
end
try
    f=figure('Visible','off');hold on;
    drawTimeline(rep.Transport.BatteryTimeline,1,[0.2,0.6,0.45]);
    drawTimeline(rep.Relay.ComponentTimeline,height(data.Batteries)+2,[0.7,0.4,0.8]);
    xlabel('时刻（s）');ylabel('能源资源序号');title('电池与能源组件占用及充电');grid on;
    files.Energy=fullfile(dir,'能源资源甘特图.png');
    exportgraphics(f,files.Energy,'Resolution',180);close(f);
catch ME
    warning('问题三能源资源图导出失败：%s',ME.message);
end
try
    f=figure('Visible','off'); hold on;
    C=rep.Coverage; ids=unique(C.TripID,'stable');
    for k=1:height(C)
        y=find(ids==C.TripID(k),1);
        if C.Mode(k)=="直连", color=[0.25,0.55,0.85];
        else, color=[0.9,0.35,0.2]; end
        plot([C.Start_s(k),C.End_s(k)],[y,y],'-','Color',color,'LineWidth',4);
    end
    yticks(1:numel(ids));yticklabels(ids);xlabel('时刻（s）');
    ylabel('运输架次');title('连续通信保障：蓝为直连，红为中继');grid on;
    files.Coverage=fullfile(dir,'通信保障时序.png');
    exportgraphics(f,files.Coverage,'Resolution',180);close(f);
catch ME
    warning('问题三通信图导出失败：%s',ME.message);
end
try
    f=figure('Visible','off'); hold on;
    C=rep.Coverage;
    middle=(C.Start_s+C.End_s)/2;
    direct=C.Mode=="直连";
    scatter(middle(direct),C.WorstMargin_dB(direct),18, ...
        [0.25,0.55,0.85],'filled');
    scatter(middle(~direct),C.WorstMargin_dB(~direct),18, ...
        [0.9,0.35,0.2],'filled');
    yline(0,'k--');
    xlabel('区间中点时刻（s）');ylabel('双向链路保守余量（dB）');
    title('连续通信区间链路校核');
    legend({'直连','中继','可用门限'},'Location','best');grid on;
    files.LinkMargins=fullfile(dir,'链路余量校核.png');
    exportgraphics(f,files.LinkMargins,'Resolution',180);close(f);
catch ME
    warning('问题三链路校核图导出失败：%s',ME.message);
end
try
    f=figure('Visible','off'); hold on;
    P=result.ParetoFront;
    scatter(P.JointMakespan_s,P.TotalEnergy_kWh, ...
        35+4*P.TransportTripCount,P.Timeliness,'filled');
    for k=1:height(P)
        text(P.JointMakespan_s(k)+65,P.TotalEnergy_kWh(k), ...
            sprintf('%d 次运输，%d 次中继',P.TransportTripCount(k), ...
            P.RelayTripCount(k)),'FontSize',10);
    end
    xlabel('联合完成时间（s）');ylabel('总能耗（kWh）');
    title('问题三可行 Pareto 档案');
    cb=colorbar; cb.Label.String='加权相对迟到';grid on;
    xlim([min(P.JointMakespan_s)-500,max(P.JointMakespan_s)+2000]);
    ylim([min(P.TotalEnergy_kWh)-0.4,max(P.TotalEnergy_kWh)+0.4]);
    files.Pareto=fullfile(dir,'五目标权衡.png');
    exportgraphics(f,files.Pareto,'Resolution',180);close(f);
catch ME
    warning('问题三 Pareto 图导出失败：%s',ME.message);
end
end

function drawTimeline(T,offset,color)
if isempty(T), return; end
ids=unique(T.ResourceID,'stable');
for k=1:height(T)
    y=offset+find(ids==T.ResourceID(k),1)-1;
    plot([T.Start_s(k),T.TaskEnd_s(k)],[y,y],'-','Color',color,'LineWidth',7);
    if T.Available_s(k)>T.TaskEnd_s(k)
        plot([T.TaskEnd_s(k),T.Available_s(k)],[y,y],':', ...
            'Color',color,'LineWidth',2);
    end
end
end
