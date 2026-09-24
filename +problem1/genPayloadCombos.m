function T = genPayloadCombos(maxMass, maxVolume, demandCap, includeEmpty, modelIDs)
% genPayloadCombos 生成各机型在质量、体积和需求上界下的装载组合
%
% 输入：
%   maxMass      各机型允许的最大载货质量，单位 kg
%   maxVolume    各机型允许的最大装载体积，单位 m^3
%   demandCap    四类物资的数量上界 [医疗, 饮用水, 食品, 卫生用品]
%   includeEmpty 可选，是否包含全 0 空载组合，默认 false
%   modelIDs     可选，机型编号；默认使用 A、B、C 或 M1、M2、...
%
% 输出 T 的列：
%   Drone          机型编号
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

    if nargin < 3
        error('请传入 maxMass、maxVolume 和四维 demandCap。');
    end
    if nargin < 4 || isempty(includeEmpty)
        includeEmpty = false;
    end

    maxMass = maxMass(:);
    maxVolume = maxVolume(:);
    demandCap = double(demandCap(:)).';

    nModel = numel(maxMass);
    if numel(maxVolume) ~= nModel
        error('maxMass 与 maxVolume 的元素个数必须一致。');
    end
    if numel(demandCap) ~= 4 || any(demandCap < 0) || ...
            any(abs(demandCap-round(demandCap)) > 1e-12)
        error('demandCap 必须是包含 4 个非负整数的向量。');
    end
    if any(maxVolume < 0)
        error('maxVolume 不能为负数。');
    end

    if nargin < 5 || isempty(modelIDs)
        if nModel == 3
            modelIDs = ["A"; "B"; "C"];
        else
            modelIDs = "M" + string((1:nModel).');
        end
    else
        modelIDs = string(modelIDs(:));
        if numel(modelIDs) ~= nModel
            error('modelIDs 的元素个数必须与机型数量一致。');
        end
    end

    % 四种物资的单箱质量、体积
    itemMass = [3; 14; 8; 6];                    % kg/箱
    itemVol  = [0.012; 0.027; 0.028; 0.035];     % m^3/箱

    T = table();
    first = true;

    for d = 1:nModel
        if isnan(maxMass(d)) || maxMass(d) < 0
            continue;
        end

        % 单种物资的最大可能箱数上界，用于减少循环
        ub = min(floor(maxMass(d) ./ itemMass), ...
                 floor(maxVolume(d) ./ itemVol));
        ub = min(ub(:).', demandCap);

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
                           totalVol  <= maxVolume(d)  + 1e-12

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

        Td.Drone = repmat(modelIDs(d),size(combos,1),1);
        Td = movevars(Td,'Drone','Before',1);

        if first
            T = Td;
            first = false;
        else
            T = [T; Td]; %#ok<AGROW>
        end
    end
end
