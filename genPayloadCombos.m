function T = genPayloadCombos(maxMass, includeEmpty)
% genPayloadCombos 生成三种运输无人机在质量、体积约束下允许的物资装载组合
%
% 输入：
%   maxMass      三个机型的最大载货质量，顺序为 [A, B, C]，单位 kg
%                例如：maxMass = [25, 30, 80];
%   includeEmpty 可选，是否包含全 0 空载组合，默认 false
%
% 输出 T 的列：
%   Drone          机型：'A','B','C'
%   Med            医疗物资箱数
%   Water          饮用水箱数
%   Food           应急食品箱数
%   Hygiene        生活卫生用品箱数
%   TotalMass_kg   总质量 kg
%   TotalVolume_m3 总体积 m^3
%
% 物资顺序：
%   1 医疗物资：3 kg，0.012 m^3
%   2 饮用水：14 kg，0.027 m^3
%   3 应急食品：8 kg，0.028 m^3
%   4 生活卫生用品：6 kg，0.035 m^3

    if nargin < 1
        error('请传入三个机型的最大载货质量，例如 maxMass = [25, 30, 80];');
    end
    if nargin < 2
        includeEmpty = false;
    end

    maxMass = maxMass(:);
    if numel(maxMass) ~= 3
        error('maxMass 必须包含 3 个元素，依次对应机型 A、B、C。');
    end
    if any(maxMass < 0)
        error('maxMass 不能为负数。');
    end

    droneNames = {'A', 'B', 'C'};

    % 题目给定的可用装载体积，单位 m^3
    maxVol = [0.06; 0.073; 0.25];

    % 四种物资的单箱质量、体积
    itemMass = [3; 14; 8; 6];                    % kg/箱
    itemVol  = [0.012; 0.027; 0.028; 0.035];     % m^3/箱

    T = table();
    first = true;

    for d = 1:3
        % 单种物资的最大可能箱数上界，用于减少循环
        ub = min(floor(maxMass(d) ./ itemMass), ...
                 floor(maxVol(d) ./ itemVol));

        combos = zeros(0, 6);

        for n1 = 0:ub(1)          % 医疗物资
            for n2 = 0:ub(2)      % 饮用水
                for n3 = 0:ub(3)  % 应急食品
                    for n4 = 0:ub(4)  % 生活卫生用品

                        n = [n1, n2, n3, n4];

                        if ~includeEmpty && all(n == 0)
                            continue;
                        end

                        totalMass = n * itemMass;
                        totalVol  = n * itemVol;

                        if totalMass <= maxMass(d) + 1e-12 && ...
                           totalVol  <= maxVol(d)  + 1e-12

                            combos(end+1, :) = ...
                                [n, totalMass, totalVol]; %#ok<AGROW>
                        end
                    end
                end
            end
        end

        if isempty(combos)
            continue;
        end

        Td = array2table(combos, ...
            'VariableNames', ...
            {'Med','Water','Food','Hygiene','TotalMass_kg','TotalVolume_m3'});

        Td = [table(repmat(droneNames{d}, size(combos,1), 1), ...
                    'VariableNames', {'Drone'}), Td];

        if first
            T = Td;
            first = false;
        else
            T = [T; Td]; %#ok<AGROW>
        end
    end
end