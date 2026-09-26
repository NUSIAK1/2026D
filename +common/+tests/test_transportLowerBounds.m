function test_transportLowerBounds()
%TEST_TRANSPORTLOWERBOUNDS 全数据下界及现有档案一致性测试。
p=common.projectPaths();
b=common.computeTransportLowerBounds();
assert(b.Energy_kWh>0 && b.Makespan_s>0 && b.TransportTripCount>=1);
assert(height(b.BoxAudit)==80 && height(b.MSTEdges)==15);
assert(height(b.WorkloadAudit)==1 && b.Makespan_s>=b.WorkloadAudit.LowerBound_s-1e-9);
assert(abs(b.Energy_kWh-sum(b.Components.LowerBound(3:4)))<1e-10);

q2=load(fullfile(p.ResultDir,'问题二_Pareto完整档案.mat'));
q3=load(fullfile(p.ResultDir,'问题三_Pareto完整档案.mat'));
assert(b.Energy_kWh<=min(q2.paretoArchive.ParetoFront.Energy_kWh)+1e-7);
assert(b.Makespan_s<=min(q2.paretoArchive.ParetoFront.Makespan_s)+1e-7);
assert(b.TransportTripCount<=min(q2.paretoArchive.ParetoFront.TripCount));
assert(b.Energy_kWh<=min(q3.saved.ParetoFront.TotalEnergy_kWh)+1e-7);
assert(b.Makespan_s<=min(q3.saved.ParetoFront.JointMakespan_s)+1e-7);
assert(b.TransportTripCount<=min(q3.saved.ParetoFront.TransportTripCount));
fprintf('运输可证下界测试全部通过。\n');
end
