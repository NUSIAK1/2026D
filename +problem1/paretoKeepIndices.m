function keepIdx = paretoKeepIndices(objectives, tolerance)
%PARETKEEPINDICES 返回稳定的三目标非支配行索引。
%
% objectives 每行依次为 [N, E, T]，三个目标均为最小化。
% tolerance 默认 [0, 1e-9, 1e-6]。容差内目标相同的行只保留最早一行。

if nargin < 2 || isempty(tolerance)
    tolerance = [0, 1e-9, 1e-6];
end

objectives = double(objectives);
tolerance = double(tolerance(:)).';

if size(objectives,2) ~= 3
    error('objectives 必须是 N×3 矩阵，列顺序为 [N,E,T]。');
end
if numel(tolerance) ~= 3 || any(tolerance < 0)
    error('tolerance 必须是包含 3 个非负数的向量。');
end

n = size(objectives,1);
keep = true(n,1);

for i = 1:n
    if ~keep(i)
        continue;
    end
    for j = 1:n
        if i == j || ~keep(j)
            continue;
        end

        same = all(abs(objectives(i,:)-objectives(j,:)) <= tolerance);
        if same
            if j < i
                keep(i) = false;
                break;
            else
                keep(j) = false;
            end
            continue;
        end

        if dominates(objectives(j,:),objectives(i,:),tolerance)
            keep(i) = false;
            break;
        elseif dominates(objectives(i,:),objectives(j,:),tolerance)
            keep(j) = false;
        end
    end
end

keepIdx = find(keep);
end

function tf = dominates(a,b,tol)
notWorse = all(a <= b + tol);
strictlyBetter = any(a < b - tol);
tf = notWorse && strictlyBetter;
end
