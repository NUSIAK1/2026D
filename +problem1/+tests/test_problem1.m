function test_problem1()
%TEST_PROBLEM1 问题一 DP/Pareto 的单元测试与全数据验收测试。

testSmallInstanceAgainstBruteForce();
testExactDemandTransition();

config = struct();
config.ExportFiles = false;
config.ReserveRatios = 0.10:0.05:0.30;
config.BaselineRatio = 0.20;
result = problem1.solveProblem1Pareto(config);

assert(numel(result.Input.ServiceIDs) == 15,'服务区数量错误。');
assert(height(result.Input.Boxes) == 80,'货箱数量错误。');
assert(all(result.Validation.Passed), ...
    '全数据验收失败：%s',strjoin(result.Validation.Check(~result.Validation.Passed),'；'));
assert(sum(cellfun(@(x) prod(x+1),num2cell(result.Input.Demand,2))) == 644, ...
    '状态数合计应为 644。');

fprintf('test_problem1: 全部测试通过。\n');
end

function testSmallInstanceAgainstBruteForce()
modes = table( ...
    [1;0;1;1], [0;1;1;1], zeros(4,1), zeros(4,1), ...
    [1;1;3;2], [5;5;6;8], ...
    'VariableNames',{'Med','Water','Food','Hygiene','Energy_kWh','OperationTime_s'});
demand = [1,1,0,0];

dp = problem1.solveServiceParetoDP(demand,modes);
bruteObjectives = bruteForceObjectives(demand,modes,[0,0,0]);
keep = problem1.paretoKeepIndices(bruteObjectives,[0,1e-9,1e-6]);
bruteFront = sortrows(bruteObjectives(keep,:),[1,2,3]);
dpFront = sortrows(dp.Front{:,{'N','E_kWh','T_s'}},[1,2,3]);

assert(isequal(size(dpFront),size(bruteFront)) && ...
    all(abs(dpFront-bruteFront) < 1e-10,'all'), ...
    '小实例 DP 前沿与穷举结果不一致。');
end

function testExactDemandTransition()
modes = table( ...
    [1;2], zeros(2,1), zeros(2,1), zeros(2,1), ...
    [1;0.1], [1;0.1], ...
    'VariableNames',{'Med','Water','Food','Hygiene','Energy_kWh','OperationTime_s'});
dp = problem1.solveServiceParetoDP([1,0,0,0],modes);
plan = dp.Front.ModeIndices{1};
assert(isscalar(plan) && plan(1)==1, ...
    '超出剩余需求的模式不应通过截断转移进入方案。');
end

function objectives = bruteForceObjectives(demand,modes,startObjective)
loads = modes{:,{'Med','Water','Food','Hygiene'}};
objectives = zeros(0,3);
walk(zeros(1,4),startObjective);

    function walk(state,obj)
        if isequal(state,demand)
            objectives(end+1,:) = obj;
            return;
        end
        remaining = demand-state;
        for mm = 1:height(modes)
            if all(loads(mm,:) <= remaining)
                walk(state+loads(mm,:),obj + ...
                    [1,modes.Energy_kWh(mm),modes.OperationTime_s(mm)]);
            end
        end
    end
end
