function test_priorityFlood()
%TEST_PRIORITYFLOOD priorityFlood 单元测试：小网格穷举 Dijkstra 对照 + 屏障情景。
rng(0);

%% 用例 1：随机小网格 vs 穷举 Dijkstra（最小最大路径）
for trial = 1:20
    nR = randi([4, 8]); nC = randi([4, 8]);
    Z = 10 + 40*rand(nR, nC);
    Z(rand(nR,nC) < 0.1) = NaN;
    Z = round(Z*10)/10;            % 与 priorityFlood 相同的 0.1 m 量化口径
    nSeed = randi([1, 6]);
    idx = randperm(nR*nC, nSeed);
    idx = idx(isfinite(Z(idx)));   % 排除 NaN
    if isempty(idx), continue; end
    lvl = Z(idx);

    [H, s, reached] = common.priorityFlood(Z, idx, lvl);
    [Hr, sr] = refMinimax(Z, idx, lvl);

    assert(isequal(reached, isfinite(Hr)), 'reached 与参考不一致');
    assert(all(abs(H(reached) - Hr(reached)) < 1e-9, 'all'), 'Hmin 与参考不符');
    assert(all(abs(s(reached) - sr(reached)) < 1e-9, 'all'), 'src 与参考不符');
end

%% 用例 2：屏障情景（抬升 = 墙高 - 水源水位）
Z = zeros(1, 9);
Z(1) = 0; Z(2:8) = 10; Z(9) = 2;   % 0---10墙---2
[H, ~] = common.priorityFlood(Z, 1, 0);
assert(abs(H(9) - 10) < 1e-9, '屏障水位应为墙高 10');
assert(H(1) == 0, '种子自身水位应为 0');

%% 用例 3：单种子平面（处处连通，Hmin = 种子水位）
Z = 5*ones(6, 7);
[H, s] = common.priorityFlood(Z, 20, 5);
assert(all(H(:) == 5, 'all'), '平面场景 Hmin 应为 5');
assert(all(s(:) == 5, 'all'), '平面场景 src 应为 5');

fprintf('test_priorityFlood 全部通过。\n');
end

function [H, s] = refMinimax(Z, seeds, lvl)
%REFMINIMAX 小网格穷举 Dijkstra（最小最大路径）参考实现。
[nR, nC] = size(Z);
n = nR*nC;
Zlin = Z(:);
H = inf(n,1); s = nan(n,1);
H(seeds) = lvl; s(seeds) = lvl;
done = false(n,1);
dr = [-1 -1 -1 0 0 1 1 1];
dc = [-1 0 1 -1 1 -1 0 1];
while true
    rem = H; rem(done) = inf;
    [v, i] = min(rem);
    if ~isfinite(v), break; end
    done(i) = true;
    r = i - nR*floor((i-1)/nR); c = floor((i-1)/nR)+1;
    for k = 1:8
        nr = r+dr(k); nc = c+dc(k);
        if nr<1||nr>nR||nc<1||nc>nC, continue; end
        j = i+dr(k)+dc(k)*nR;
        if done(j) || ~isfinite(Zlin(j)), continue; end
        nw = max(H(i), Zlin(j));
        if nw < H(j), H(j)=nw; s(j)=s(i); end
    end
end
H = reshape(H, nR, nC); s = reshape(s, nR, nC);
end
