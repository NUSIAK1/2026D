function time_s = chargeTime(socStart, fullChargeTime_s)
%CHARGETIME 两阶段等效充电模型：从 SOC 充至 100%。

if any(socStart < -1e-12 | socStart > 1+1e-12)
    error('socStart 必须位于 [0,1]。');
end
if any(fullChargeTime_s < 0)
    error('fullChargeTime_s 必须非负。');
end

socStart = min(max(socStart,0),1);
time_s = zeros(size(socStart));
fastMask = socStart < 0.9;
time_s(fastMask) = fullChargeTime_s .* ...
    (0.65*(0.9-socStart(fastMask))/0.9 + 0.35);
time_s(~fastMask) = fullChargeTime_s .* ...
    0.35*(1-socStart(~fastMask))/0.1;
end
