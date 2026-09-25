function test_problem4()
%TEST_PROBLEM4 小实例最优性、充电边界及全量固定方案验收。
tiny={ ...
    [0,1,2],[1,2,3],1; ...
    [0,0,1],[2,1,2],2; ...
    [0,1,1.5],[2,2,3],3; ...
    zeros(1,0),zeros(1,0),0};
for k=1:size(tiny,1)
    starts=tiny{k,1}; finish=tiny{k,2};
    ids=compose('J%02d',(1:numel(starts))');
    a=problem4.allocateIntervals(ids,starts,finish);
    assert(a.Required==tiny{k,3});
    if ~isempty(starts)
        assert(a.Required==bruteMinimum(starts,finish));
    end
end
assert(abs(common.chargeTime(0.9,1800)-630)<1e-9);
assert(abs(common.chargeTime(1,1800))<1e-9);

r=problem4.solveProblem4(struct('ExportFiles',false));
assert(numel(r.Blocks)==3 && nnz(r.Summary.K==2)==3 && ...
    nnz(r.Summary.K==3)==1);
assert(all(r.Validation.Checks.Passed));
assert(r.Selected2.K==2 && r.Selected3.K==3);
assert(height(r.Selected2.Group)==2 && height(r.Selected3.Group)==3);
assert(height(r.Baseline)==8);
assert(all(r.Selected2.Extra>=0) && all(r.Selected3.Extra>=0));
assert(sum(r.Selected2.Group.BoxCount)==80 && ...
    sum(r.Selected3.Group.BoxCount)==80);
fprintf('problem4.tests.test_problem4 全部通过。\n');
end

function minimum=bruteMinimum(start,finish)
% 穷举所有槽位分配，与独立的最优答案比较。
n=numel(start); minimum=n;
slot=zeros(1,n);
search(1,0);
    function search(pos,used)
        if used>=minimum, return; end
        if pos>n, minimum=used; return; end
        for c=1:used+1
            if c>=minimum, continue; end
            compatible=true;
            for j=1:pos-1
                if slot(j)==c && start(pos)<finish(j)-1e-7 && ...
                        start(j)<finish(pos)-1e-7
                    compatible=false;break;
                end
            end
            if compatible
                slot(pos)=c;
                search(pos+1,max(used,c));
            end
        end
    end
end
