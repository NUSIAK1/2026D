function test_euclideanDist()
%TEST_EUCLIDEANDIST euclideanDist 单元测试：穷举平方距离对照。
rng(1);
for trial = 1:30
    nR = randi([3, 12]); nC = randi([3, 12]);
    mask = rand(nR, nC) < 0.35;
    if ~any(mask(:)), mask(1,1) = true; end

    D = common.euclideanDist(mask);

    % 穷举
    [RR, CC] = ndgrid(1:nR, 1:nC);
    Dref = inf(nR, nC);
    [fr, fc] = find(mask);
    for q = 1:numel(fr)
        Dref = min(Dref, (RR-fr(q)).^2 + (CC-fc(q)).^2);
    end

    assert(all(abs(D(:) - Dref(:)) < 1e-9, 'all'), '平方距离与穷举不符');
end
fprintf('test_euclideanDist 全部通过。\n');
end
