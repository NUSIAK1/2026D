function out = calcLegCost(startID, endID, modelID, payload, flightBase)
%CALCLEGCOST 计算指定航段在给定机型与载荷下的时间与能耗
%
%   out = common.calcLegCost(startID, endID, modelID, payload)
%   out = common.calcLegCost(startID, endID, modelID, payload, flightBase)
%
%   输入：
%       startID  - 起点编号，字符串，如 "O01"
%       endID    - 终点编号，字符串，如 "S001"
%       modelID  - 机型，"A" / "B" / "C"
%       payload  - 有效载荷，单位 kg
%
%   输出结构体 out 字段：
%       几何/地形：
%           distance   水平球面距离 (m)
%           Hterrain   航线最高地面高程 (m)
%           Hcruise    计划巡航海拔 (m)
%           Hup        爬升高度 (m)
%           Hdown      下降高度 (m)
%
%       时间：
%           T_up       爬升时间 (s)
%           T_cruise   巡航时间 (s)
%           T_down     下降时间 (s)
%           T_total    总飞行时间 (s)
%
%       能量：
%           Leq        当前载荷下的等效航程 (m)
%           E_hor      水平巡航能耗 (kWh)
%           E_up       爬升附加能耗 (kWh)
%           E_total    单航段总能耗 (kWh)
%           budget     按返航余量折算的单组电池可用能量 (kWh)
%
%   flightBase 可选。传入时直接使用内存中的基础数据，适合批量计算；
%   省略时从标准缓存路径代码/cache/flightBase.mat 读取。

    %% 载入基础数据
    if nargin < 5 || isempty(flightBase)
        paths = common.projectPaths();
        baseFile = paths.FlightBaseFile;
        if ~isfile(baseFile)
            error(['未找到 flightBase.mat。' ...
                   '请先运行 common.computeTerrainMatrices() 生成基础矩阵。']);
        end
        S = load(baseFile);
    else
        S = flightBase;
    end

    requiredFields = {'nodes','uav','D','Hup','Hdown','Hcruise','HterrainMax'};
    for k = 1:numel(requiredFields)
        if ~isfield(S, requiredFields{k})
            error('flightBase 缺少字段：%s。', requiredFields{k});
        end
    end

    nodes       = S.nodes;
    uav         = S.uav;
    D           = S.D;
    Hup         = S.Hup;
    Hdown       = S.Hdown;
    Hcruise     = S.Hcruise;
    HterrainMax = S.HterrainMax;

    %% 定位节点与机型
    startID = string(startID);
    endID   = string(endID);
    modelID = string(modelID);

    idx1 = find(nodes.ID == startID, 1);
    idx2 = find(nodes.ID == endID,   1);
    if isempty(idx1), error('未找到起点编号：%s', startID); end
    if isempty(idx2), error('未找到终点编号：%s', endID);   end

    modelIdx = find(uav.ID == modelID, 1);
    if isempty(modelIdx)
        error('不存在机型 %s。可选 A/B/C。', modelID);
    end

    if payload < 0 || payload > uav.MaxPayload(modelIdx)
        error('载荷 %.3f kg 超出机型 %s 的允许范围 [0, %.3f] kg。', ...
            payload, modelID, uav.MaxPayload(modelIdx));
    end

    %% 机型参数
    g       = 9.81;
    mEmpty  = uav.EmptyMass(modelIdx);
    Qmax    = uav.MaxPayload(modelIdx);
    vc      = uav.VCruise(modelIdx);
    vup     = uav.VClimb(modelIdx);
    vdown   = uav.VDesc(modelIdx);
    L0      = uav.RangeEmpty(modelIdx);
    LF      = uav.RangeFull(modelIdx);
    Euse    = uav.BatteryUse(modelIdx);
    etaUp   = uav.EtaClimb(modelIdx);
    rho     = uav.ReservePct(modelIdx) / 100;

    %% 等效航程 L_g(q) = L0 - (L0 - LF) * (q / Qmax)^(3/2)
    Leq = L0 - (L0 - LF) * (payload / Qmax)^(3/2);
    if Leq <= 0
        error('计算得到的等效航程非正，请检查机型参数与载荷。');
    end

    %% 几何量
    out.startID   = startID;
    out.endID     = endID;
    out.modelID   = modelID;
    out.payload   = payload;

    out.distance  = D(idx1, idx2);
    out.Hterrain  = HterrainMax(idx1, idx2);
    out.Hcruise   = Hcruise(idx1, idx2);
    out.Hup       = Hup(idx1, idx2);
    out.Hdown     = Hdown(idx1, idx2);

    %% 时间
    out.T_up     = out.Hup     / vup;
    out.T_cruise = out.distance / vc;
    out.T_down   = out.Hdown   / vdown;
    out.T_total  = out.T_up + out.T_cruise + out.T_down;

    %% 能量
    out.Leq     = Leq;
    out.E_hor   = Euse * out.distance / Leq;
    out.E_up    = (mEmpty + payload) * g * out.Hup / (etaUp * 3.6e6);
    out.E_total = out.E_hor + out.E_up;
    out.budget  = (1 - rho) * Euse;
end
