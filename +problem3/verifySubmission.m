function report = verifySubmission(rep,workbook,templateFile)
%VERIFYSUBMISSION 独立回读官方提交簿，逐格核对完整方案与原模板表头。
if nargin<3 || isempty(templateFile)
    paths=common.projectPaths();
    templateFile=paths.TemplateFile;
end
spec={ ...
    'Q2_运输架次',rep.Transport.Trips, ...
        {'TripID','DroneID','Model','BatteryID','Start_s','Route','Return_s','Energy_kWh'}, ...
        {'Start_s','TripID'}; ...
    'Q2_逐箱交付',rep.Transport.Deliveries, ...
        {'BoxID','TripID','ServiceID','Delivery_s'}, {'BoxID'}; ...
    'Q3_中继架次',rep.Relay.RelayTrips, ...
        {'RelayTripID','RelayID','ComponentID','Start_s', ...
        'HoverLon_deg','HoverLat_deg','HoverAlt_m','LinkReady_s', ...
        'ServiceEnd_s','Return_s','Energy_kWh'}, {'Start_s','RelayTripID'}; ...
    'Q3_通信保障',rep.Coverage, ...
        {'TripID','Phase','Start_s','End_s','Mode','RelayTripID'}, ...
        {'TripID','Start_s'}};
sheet=strings(size(spec,1),1); passed=false(size(spec,1),1);
details=strings(size(spec,1),1);
for k=1:size(spec,1)
    sheet(k)=string(spec{k,1});
    expected=sortrows(spec{k,2},spec{k,4});
    expected=table2cell(expected(:,spec{k,3}));
    n=size(expected,1); width=size(expected,2);
    lastCol=char('A'+width-1);
    original=readcell(templateFile,'Sheet',sheet(k), ...
        'Range',sprintf('A1:%s1',lastCol));
    actualHeader=readcell(workbook,'Sheet',sheet(k), ...
        'Range',sprintf('A1:%s1',lastCol));
    headerOK=all(cellfun(@equivalent,original,actualHeader));
    actual=readcell(workbook,'Sheet',sheet(k), ...
        'Range',sprintf('A2:%s%d',lastCol,n+1));
    valueOK=isequal(size(actual),size(expected));
    mismatch="";
    if valueOK
        for row=1:n
            for col=1:width
                if ~equivalent(expected{row,col},actual{row,col})
                    mismatch=sprintf('第 %d 行第 %d 列',row,col);
                    valueOK=false; break;
                end
            end
            if ~valueOK, break; end
        end
    end
    full=readcell(workbook,'Sheet',sheet(k));
    ids=full(2:end,1);
    count=nnz(~cellfun(@isBlank,ids));
    countOK=count==n;
    passed(k)=headerOK && valueOK && countOK;
    details(k)=sprintf('预期 %d 行，实读 %d 行；表头 %d，值 %d', ...
        n,count,headerOK,valueOK);
    if mismatch~="", details(k)=details(k)+"；"+mismatch; end
end
report=struct('Feasible',all(passed),'Checks',table(sheet,passed,details, ...
    'VariableNames',{'Sheet','Passed','Details'}));
end

function yes=equivalent(a,b)
if isBlank(a) || isBlank(b)
    yes=isBlank(a) && isBlank(b); return;
end
if isnumeric(a) && isnumeric(b)
    yes=isscalar(a) && isscalar(b) && isfinite(a) && isfinite(b) && ...
        abs(a-b)<=1e-8*max(1,abs(a));
else
    yes=isequal(string(a),string(b));
end
end

function yes=isBlank(x)
yes=isempty(x) || (isnumeric(x) && isscalar(x) && isnan(x)) || ...
    (isstring(x) && (ismissing(x) || x=="")) || ...
    isa(x,'missing');
end
