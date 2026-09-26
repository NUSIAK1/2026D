function checkDeadline(config)
%CHECKDEADLINE 在昂贵循环内部执行统一搜索期限检查。
if isfield(config,'DeadlineClock') && ...
        toc(config.DeadlineClock)>=config.DeadlineSeconds
    error('problem3:TimeLimit','达到搜索时间预算，保留已认证档案并导出。');
end
end
