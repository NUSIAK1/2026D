function xyz = positionAt(phase,time_s)
%POSITIONAT 运输阶段内按时间线性插值三维位置。
u=(time_s-phase.Start_s)/(phase.End_s-phase.Start_s);
u=min(1,max(0,u));
xyz=phase.A+u*(phase.B-phase.A);
end
