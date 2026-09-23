function [qMaxRow, detail] = calcMaxSafePayload(serviceID, flightBase, reserveOverride)
% calcMaxSafePayload
%
% 给定一个服务区编号，计算 A/B/C 三种运输无人机执行
% O01 -> Si -> O01 单点直接往返任务时的最大安全载荷。
%
% 基本调用：
%   [q, detail] = calcMaxSafePayload("S001", flightBase);
%
% 安全余量敏感性分析（可选）：
%   [q, detail] = calcMaxSafePayload("S001", flightBase, 0.25);
%
% reserveOverride 可取：
%   []          使用附件中各机型的返航电量下限
%   0.25        三种机型统一采用25%
%   [0.2 0.25 0.3]  A/B/C分别采用20%、25%、30%
%
% 本函数不读取DEM、不重新计算节点距离、不重新提取路径高程；
% 直接使用主脚本已经得到的 D、Hup 等基础矩阵。
%
% 核心逻辑：
%   去程：O01 -> Si，载荷为 q
%   返程：Si  -> O01，载荷为 0
%
%   E_RT(q) = E_out(q) + E_back(0)
%
%   最大安全载荷：
%   max q
%   s.t.
%       0 <= q <= Q_g
%       E_RT(q) <= (1-rho_g) E_g^use
%
% 在当前题目给定的等效航程关系下，E_RT(q) 随 q 单调增加，
% 因此采用稳定的二分搜索求最大可行 q。

if nargin < 2
    error('至少需要输入 serviceID 和 flightBase。');
end

if nargin < 3
    reserveOverride = [];
end

serviceID = string(serviceID);

nodes = flightBase.nodes;
uav   = flightBase.uav;
D     = flightBase.D;
Hup   = flightBase.Hup;

idxO = find(nodes.ID=="O01",1);
idxS = find(nodes.ID==serviceID,1);

if isempty(idxO)
    error('基础节点数据中不存在 O01。');
end

if isempty(idxS)
    error('不存在服务区编号：%s',serviceID);
end

if ~startsWith(serviceID,"S")
    error('输入节点必须是服务区编号，例如 S001。');
end

nModel = height(uav);

% -------------------------------------------------------------------------
% 处理可选安全余量
% -------------------------------------------------------------------------

rhoVec = uav.ReservePct/100;

if ~isempty(reserveOverride)

    reserveOverride = double(reserveOverride(:));

    if isscalar(reserveOverride)
        rhoVec = repmat(reserveOverride,nModel,1);
    elseif numel(reserveOverride) == nModel
        rhoVec = reserveOverride;
    else
        error('reserveOverride 应为空、标量或包含A/B/C三个值的向量。');
    end

    if any(rhoVec < 0 | rhoVec >= 1)
        error('返航安全余量应满足 0 <= rho < 1。');
    end
end

qMaxRow = nan(1,nModel);

ratedMax = zeros(nModel,1);
reserveRatio = rhoVec;
energyLimit = zeros(nModel,1);

emptyRoundTripEnergy = nan(nModel,1);
ratedLoadRoundTripEnergy = nan(nModel,1);
energyAtQmax = nan(nModel,1);

outboundEnergyAtQmax = nan(nModel,1);
returnEmptyEnergy = nan(nModel,1);

socAtQmax = nan(nModel,1);
energyMargin = nan(nModel,1);

emptyRoundTripFeasible = false(nModel,1);
fullRatedLoadFeasible = false(nModel,1);

bindingConstraint = strings(nModel,1);
monotonicityOK = true(nModel,1);

% 记录航段空间条件，便于论文解释
distanceOneWay = repmat(D(idxO,idxS),nModel,1);
climbOut = repmat(Hup(idxO,idxS),nModel,1);
climbBack = repmat(Hup(idxS,idxO),nModel,1);

g0 = 9.81;       % m/s^2
tolQ = 1e-6;     % kg
maxIter = 100;

dOut  = D(idxO,idxS);
dBack = D(idxS,idxO);

hOut  = Hup(idxO,idxS);
hBack = Hup(idxS,idxO);

for g = 1:nModel

    m0    = uav.EmptyMass(g);
    Qg    = uav.MaxPayload(g);
    L0    = uav.RangeEmpty(g);
    LF    = uav.RangeFull(g);
    Euse  = uav.BatteryUse(g);
    rho   = rhoVec(g);
    etaUp = uav.EtaClimb(g);

    ratedMax(g) = Qg;
    energyLimit(g) = (1-rho)*Euse;

    % =====================================================================
    % 1. 空载返程能耗
    % =====================================================================

    EhorBack = Euse*dBack/L0;
    EupBack  = m0*g0*hBack/(etaUp*3.6e6);

    Eback = EhorBack + EupBack;

    returnEmptyEnergy(g) = Eback;

    % =====================================================================
    % 2. 载荷相关的去程和完整往返能耗
    % =====================================================================

    Lfun = @(q) ...
        L0 - (L0-LF).*(q./Qg).^(3/2);

    EoutFun = @(q) ...
        Euse*dOut./Lfun(q) + ...
        (m0+q).*g0*hOut/(etaUp*3.6e6);

    EroundFun = @(q) EoutFun(q) + Eback;

    E0 = EroundFun(0);
    EF = EroundFun(Qg);

    emptyRoundTripEnergy(g) = E0;
    ratedLoadRoundTripEnergy(g) = EF;

    emptyRoundTripFeasible(g) = E0 <= energyLimit(g);
    fullRatedLoadFeasible(g) = EF <= energyLimit(g);

    % =====================================================================
    % 3. 单调性数值检查
    %
    % 文献和当前等效航程公式都表明载荷增大时续航降低、能耗增加。
    % 为防止数据录入或公式修改后破坏该性质，这里主动检查。
    % =====================================================================

    qCheck = linspace(0,Qg,21);
    eCheck = arrayfun(EroundFun,qCheck);

    monotonicityOK(g) = all(diff(eCheck) >= -1e-10);

    if ~monotonicityOK(g)
        warning(['机型 %s 在节点 %s 的往返能耗未通过单调性检查。' ...
                 '请检查航程或能耗公式。'],uav.ID(g),serviceID);
    end

    % =====================================================================
    % 4. 最大安全载荷
    % =====================================================================

    if ~emptyRoundTripFeasible(g)

        % 连空载往返都无法满足安全余量
        qMaxRow(g) = NaN;
        bindingConstraint(g) = "空载不可达";
        continue;
    end

    if fullRatedLoadFeasible(g)

        % 满额定载荷都可行，因此结构额定载荷成为主导约束
        qStar = Qg;
        bindingConstraint(g) = "额定载荷约束";

    else

        % 能量安全约束先于额定载荷约束生效
        bindingConstraint(g) = "能量安全约束";

        if monotonicityOK(g)

            qLow = 0;
            qHigh = Qg;

            for iter = 1:maxIter

                qMid = (qLow+qHigh)/2;

                if EroundFun(qMid) <= energyLimit(g)
                    qLow = qMid;
                else
                    qHigh = qMid;
                end

                if qHigh-qLow <= tolQ
                    break;
                end
            end

            qStar = qLow;

        else
            % 极端情况下若单调性被破坏，用细网格保守寻找最大可行值
            qGrid = linspace(0,Qg,100001);
            eGrid = arrayfun(EroundFun,qGrid);
            feasibleGrid = qGrid(eGrid <= energyLimit(g));

            if isempty(feasibleGrid)
                qStar = NaN;
                bindingConstraint(g) = "无可行载荷";
            else
                qStar = max(feasibleGrid);
            end
        end
    end

    qMaxRow(g) = qStar;

    if isnan(qStar)
        continue;
    end

    energyAtQmax(g) = EroundFun(qStar);
    outboundEnergyAtQmax(g) = EoutFun(qStar);

    energyMargin(g) = energyLimit(g)-energyAtQmax(g);

    % Bhuiyan et al. 类似地跟踪任务完成后的剩余电量。
    % SOC = 1 - 已消耗能量/电池可用能量
    socAtQmax(g) = 1-energyAtQmax(g)/Euse;
end

detail = table( ...
    uav.ID, ...
    ratedMax, ...
    qMaxRow(:), ...
    reserveRatio, ...
    distanceOneWay, ...
    climbOut, ...
    climbBack, ...
    emptyRoundTripEnergy, ...
    ratedLoadRoundTripEnergy, ...
    energyLimit, ...
    energyAtQmax, ...
    outboundEnergyAtQmax, ...
    returnEmptyEnergy, ...
    socAtQmax, ...
    energyMargin, ...
    bindingConstraint, ...
    monotonicityOK, ...
    emptyRoundTripFeasible, ...
    fullRatedLoadFeasible, ...
    'VariableNames',{ ...
    'Model', ...
    'RatedMaxPayload_kg', ...
    'MaxSafePayload_kg', ...
    'ReserveRatio', ...
    'OneWayDistance_m', ...
    'OutboundClimb_m', ...
    'ReturnClimb_m', ...
    'EmptyRoundTripEnergy_kWh', ...
    'RatedLoadRoundTripEnergy_kWh', ...
    'EnergyLimit_kWh', ...
    'EnergyAtMaxSafePayload_kWh', ...
    'OutboundEnergyAtMax_kWh', ...
    'ReturnEmptyEnergy_kWh', ...
    'SOC_AfterTrip_AtMaxSafePayload', ...
    'EnergyMargin_kWh', ...
    'BindingConstraint', ...
    'MonotonicityOK', ...
    'EmptyRoundTripFeasible', ...
    'FullRatedLoadFeasible'});

end
