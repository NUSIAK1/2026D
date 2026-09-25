function time_s = chargeTime(socStart, fullChargeTime_s)
%CHARGETIME 从当前 SOC 按题目两阶段规则充至 100% 所需时间。
if any(socStart < -1e-12 | socStart > 1+1e-12)
    error('socStart 必须位于 [0,1]。');
end
if any(fullChargeTime_s < 0)
    error('fullChargeTime_s 必须非负。');
end
socStart = min(max(socStart,0),1);
time_s = zeros(size(socStart));
fast = socStart < 0.9;
time_s(fast) = fullChargeTime_s .* ...
    (0.65*(0.9-socStart(fast))/0.9 + 0.35);
time_s(~fast) = fullChargeTime_s .* 0.35*(1-socStart(~fast))/0.1;
end
