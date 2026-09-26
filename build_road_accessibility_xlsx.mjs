import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { SpreadsheetFile, Workbook } from "@oai/artifact-tool";

const codeDir = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(path.dirname(codeDir), "结果", "道路可达性先验");

function parseCsv(text) {
  const records = [];
  let row = [], cell = "", quote = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (c === '"') {
      if (quote && text[i + 1] === '"') { cell += '"'; i++; } else quote = !quote;
    } else if (c === "," && !quote) { row.push(cell); cell = ""; }
    else if ((c === "\n" || c === "\r") && !quote) {
      if (c === "\r" && text[i + 1] === "\n") i++;
      row.push(cell); if (row.some(x => x !== "")) records.push(row);
      row = []; cell = "";
    } else cell += c;
  }
  if (cell !== "" || row.length) { row.push(cell); records.push(row); }
  const [header, ...rows] = records;
  header[0] = header[0].replace(/^\uFEFF/, "");
  return rows.map(r => Object.fromEntries(header.map((h, i) => [h, r[i] ?? ""])));
}
const readCsv = async filename => parseCsv(await fs.readFile(path.join(outDir, filename), "utf8"));
const num = value => value === "" || value === "None" ? null : Number(value);
const services = await readCsv("服务区道路可达性.csv");
const segments = await readCsv("易损路段清单.csv");
if (services.length !== 15 || segments.length === 0) throw new Error("输入行数不符合预期");

const wb = Workbook.create();
const summary = wb.worksheets.add("服务区可达性");
const risk = wb.worksheets.add("易损路段");
const method = wb.worksheets.add("方法口径");
for (const s of [summary, risk, method]) s.showGridLines = false;
summary.tabColor = "#264E64";

summary.getRange("A2").values = [["服务区地面可达性与原始优先系数对照"]];
summary.getRange("A3").values = [["基于原始道路、30 m DEM、水系与水体；仅为风险筛查，不代表实际道路通断。"]];
const columns = [
  ["服务区", "服务区编号", x => x], ["名称", "服务区名称", x => x],
  ["人口(人)", "保障人口_人", num], ["最近道路(m)", "最近道路距离_m", num],
  ["路网匹配", "路网匹配状态", x => x], ["路网距离(km)", "路网最短距离_km", num],
  ["绕行系数", "道路绕行系数", num], ["陡坡暴露率", "路径陡坡暴露率", num],
  ["临水暴露率", "路径临水暴露率", num], ["双因子暴露率", "路径陡坡且临水率", num],
  ["任一因子暴露率", "路径任一风险暴露率", num],
  ["封闭后路网状态", "高风险段封闭后状态", x => x],
  ["原优先系数·箱数加权", "原始优先系数_按箱加权均值", num],
  ["医疗优先系数", "原始医疗优先系数", num],
];
summary.getRange("A5:N5").values = [columns.map(c => c[0])];
summary.getRange("A6:N20").values = services.map(s => columns.map(([, key, transform]) => transform(s[key])));
summary.getRange("A22").values = [["缺测说明：最近道路距离超过 300 m 的服务区不计算路网路径；空白单元格表示不可可靠估计。"]];
summary.getRange("A23").values = [["优先系数来自原始需求表，按总需求箱数加权；本表不替换原系数，也不改动 Q1/Q2 计算结果。"]];

risk.getRange("A2").values = [["陡坡且临水易损路段清单"]];
risk.getRange("A3").values = [["路段 30 m 内插采样；坡度≥30°且距水体/水系≤100 m 的样本占比≥50%。"]];
const riskCols = [
  ["路段ID", "edge_id", num], ["道路要素", "road_id", x => x],
  ["道路类型", "road_type", x => x], ["长度(m)", "length_m", num],
  ["起点经度", "lon_a", num], ["起点纬度", "lat_a", num],
  ["终点经度", "lon_b", num], ["终点纬度", "lat_b", num],
  ["双因子样本占比", "dual_fraction", num],
];
risk.getRange("A5:I5").values = [riskCols.map(c => c[0])];
risk.getRange(`A6:I${5 + segments.length}`).values = segments.map(s => riskCols.map(([, key, transform]) => transform(s[key])));

method.getRange("A2").values = [["数据与计算口径"]];
const methodRows = [
  ["坐标与距离", "原始坐标 EPSG:4326；在服务区平均纬度处转换为局部米制平面距离，仅用于道路长度与邻近计算。"],
  ["原始来源", "原始题目信息/数据/镇龙乡地理空间数据/：道路 CSV、30 m DEM GeoTIFF、水系 CSV、水体 CSV；节点与需求原始 XLSX。"],
  ["道路筛选", "排除在建道路、人行步道、步行街、小径；其余原始道路类型按双向通行建图。"],
  ["坡度阈值", "DEM 中心差分坡度≥30°记为陡坡暴露。DEM 为 DSM，不能替代现场边坡调查。"],
  ["临水阈值", "道路采样点距栅格化水系/水体≤100 m 记为临水暴露。"],
  ["高风险路段", "一个原始道路顶点间路段中，至少 50% 的有效采样点同时陡坡且临水。"],
  ["路网匹配", "节点至最近已映射道路≤300 m 为有效匹配；超过则路径指标留空。"],
  ["绕行系数", "路网最短距离 / O01 至服务区直线距离；不包含离路接驳距离。"],
  ["暴露率", "基线最短路径上各路段的采样风险占比按路径长度加权；起终点所在路段按实际通行比例计入。"],
  ["封闭情景", "将高风险路段全部视为封闭，检查已映射路网是否有替代路径；仅是假设性韧性筛查。"],
  ["原优先系数", "来自物资需求与配送时限.xlsx；服务区均值 = Σ(总需求箱数×应急优先系数)/Σ总需求箱数。"],
  ["解读边界", "道路与 DEM 风险不能证明实际塌方，也不能证明原优先系数由地理因素决定；未修改 Q1/Q2 模型与结果。"],
];
method.getRange("A5:B5").values = [["项目", "定义"]];
method.getRange(`A6:B${5 + methodRows.length}`).values = methodRows;

function styleSheet(sheet, titleRange, headerRange, bodyRange) {
  sheet.getUsedRange().format.font = { name: "Microsoft YaHei", size: 10, color: "#23323A" };
  sheet.getRange(titleRange).format.font = { name: "Microsoft YaHei", size: 14, bold: true, color: "#17252D" };
  sheet.getRange(headerRange).format = { fill: "#264E64", font: { name: "Microsoft YaHei", size: 10, bold: true, color: "#FFFFFF" } };
  sheet.getRange(headerRange).format.rowHeight = 31;
  sheet.getRange(bodyRange).format.rowHeight = 25;
  sheet.freezePanes.freezeRows(5);
}
styleSheet(summary, "A2", "A5:N5", "A6:N20");
styleSheet(risk, "A2", "A5:I5", `A6:I${5 + segments.length}`);
styleSheet(method, "A2", "A5:B5", `A6:B${5 + methodRows.length}`);
for (const [col, width] of Object.entries({A:13,B:25,C:13,D:17,E:20,F:19,G:13,H:17,I:17,J:19,K:21,L:26,M:25,N:18}))
  summary.getRange(`${col}:${col}`).format.columnWidth = width;
for (const [col, width] of Object.entries({A:12,B:16,C:17,D:15,E:17,F:17,G:17,H:17,I:20}))
  risk.getRange(`${col}:${col}`).format.columnWidth = width;
method.getRange("A:A").format.columnWidth = 19;
method.getRange("B:B").format.columnWidth = 105;
summary.getRange("D6:D20").setNumberFormat("0.0");
summary.getRange("F6:F20").setNumberFormat("0.000");
summary.getRange("G6:G20").setNumberFormat("0.00");
summary.getRange("H6:K20").setNumberFormat("0.0%");
summary.getRange("M6:M20").setNumberFormat("0.000");
risk.getRange(`D6:D${5 + segments.length}`).setNumberFormat("0.0");
risk.getRange(`E6:H${5 + segments.length}`).setNumberFormat("0.000000");
risk.getRange(`I6:I${5 + segments.length}`).setNumberFormat("0.0%");
summary.getRange("E6:E20").conditionalFormats.add("containsText", {text:"超出",format:{fill:"#FFF1D6",font:{color:"#8A4B05"}}});
summary.getRange("K6:K20").conditionalFormats.add("colorScale", {colors:["#EFF8F4","#F1C36D","#B44336"],thresholds:["min",{type:"percentile",value:50},"max"]});

wb.recalculate();
const check = await wb.inspect({kind:"table",range:"服务区可达性!A5:N8",include:"values",tableMaxRows:4,tableMaxCols:14});
console.log(check.ndjson);
const err = await wb.inspect({kind:"match",searchTerm:"#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A|#NUM!",options:{useRegex:true,maxResults:20}});
console.log(err.ndjson);
await fs.mkdir(path.join(codeDir,"cache"),{recursive:true});
for (const [sheetName, range, file] of [
  ["服务区可达性","A2:N12","road_accessibility_summary_preview.png"],
  ["易损路段","A2:I15","road_accessibility_risk_preview.png"],
  ["方法口径","A2:B17","road_accessibility_method_preview.png"],
]) {
  const preview = await wb.render({sheetName,range,scale:1.25,format:"png"});
  await fs.writeFile(path.join(codeDir,"cache",file),new Uint8Array(await preview.arrayBuffer()));
}
const out = await SpreadsheetFile.exportXlsx(wb);
await out.save(path.join(outDir,"道路可达性先验.xlsx"));
console.log(`Wrote ${path.join(outDir,"道路可达性先验.xlsx")}`);
