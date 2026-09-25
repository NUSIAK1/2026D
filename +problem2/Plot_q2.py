from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt
from matplotlib import font_manager
from matplotlib.patches import Patch
from matplotlib.lines import Line2D


# ===================== 1. 文件与参数 =====================
project_root = Path(__file__).resolve().parents[2]
config_path = project_root / "结果" / "问题二_绘图配置.xlsx"
selected = str(pd.read_excel(config_path, sheet_name="绘图设置", header=None).iloc[1, 1]).strip()
scheme_suffix = {
    "TimelinessFirst": "及时性优先",
    "MakespanFirst": "完成时间优先",
    "EnergyFirst": "能耗优先",
    "TripCountFirst": "架次数优先",
    "Balanced": "折中方案",
}
if selected not in scheme_suffix:
    raise ValueError(f"绘图设置!B2 中的方案名称无效：{selected}")
excel_path = project_root / "结果" / f"问题二_结果提交_{scheme_suffix[selected]}.xlsx"
sheet_name = "Q2_运输架次"

# 图片保存位置
output_path = project_root / "论文" / "图表" / "问题二" / f"无人机甘特图_{scheme_suffix[selected]}.png"
output_path.parent.mkdir(parents=True, exist_ok=True)

# 首批硬时限，单位：小时
# 如果不需要这条红色虚线，可以改成 None
first_deadline_h = 1.0

# A、B、C 三种机型颜色
model_colors = {
    "A": "#4C72B0",
    "B": "#DD8452",
    "C": "#55A868",
}


# ===================== 2. 设置中文字体 =====================
def set_chinese_font():
    candidates = [
        "Microsoft YaHei",
        "SimHei",
        "Noto Sans CJK SC",
        "Source Han Sans SC",
        "PingFang SC",
        "Arial Unicode MS",
    ]

    installed_fonts = {f.name for f in font_manager.fontManager.ttflist}

    for font_name in candidates:
        if font_name in installed_fonts:
            plt.rcParams["font.sans-serif"] = [font_name]
            break

    plt.rcParams["axes.unicode_minus"] = False


set_chinese_font()


# ===================== 3. 读取 Excel =====================
df = pd.read_excel(
    excel_path,
    sheet_name=sheet_name
)

# 检查必要字段
required_cols = [
    "无人机编号",
    "机型编号",
    "开始时刻（s）",
    "访问服务区顺序",
    "返回O01时刻（s）",
]

missing_cols = [col for col in required_cols if col not in df.columns]

if missing_cols:
    raise ValueError(f"Excel 中缺少字段：{missing_cols}")


# ===================== 4. 时间转换 =====================
# 秒 -> 小时
df["开始_h"] = pd.to_numeric(
    df["开始时刻（s）"],
    errors="coerce"
) / 3600

df["结束_h"] = pd.to_numeric(
    df["返回O01时刻（s）"],
    errors="coerce"
) / 3600

df["持续_h"] = df["结束_h"] - df["开始_h"]

# 删除异常空值
df = df.dropna(
    subset=[
        "无人机编号",
        "机型编号",
        "开始_h",
        "结束_h",
    ]
)

# 整个运输方案的完成时间
completion_h = df["结束_h"].max()


# ===================== 5. 无人机排序 =====================
def get_uav_number(uav):
    """
    U01 -> 1
    U08 -> 8
    """
    text = str(uav)
    digits = "".join(ch for ch in text if ch.isdigit())

    if digits:
        return int(digits)

    return -1


# 按 U08、U07、...、U01 排序
uav_order = sorted(
    df["无人机编号"].astype(str).unique(),
    key=get_uav_number,
    reverse=True,
)

# 获得每架无人机对应的机型
type_map = (
    df.groupby("无人机编号")["机型编号"]
    .first()
    .astype(str)
    .to_dict()
)


# ===================== 6. 绘制甘特图 =====================
fig, ax = plt.subplots(figsize=(14, 6.6))

bar_height = 0.62


for y, uav in enumerate(uav_order):

    # 当前无人机的所有架次
    sub_df = df[
        df["无人机编号"].astype(str) == uav
    ].sort_values("开始_h")

    for _, row in sub_df.iterrows():

        model = str(row["机型编号"])

        start = row["开始_h"]
        duration = row["持续_h"]

        # 绘制甘特条
        ax.barh(
            y=y,
            width=duration,
            left=start,
            height=bar_height,
            color=model_colors.get(model, "#888888"),
            edgecolor="white",
            linewidth=1.0,
            zorder=2,
        )

        # 架次内部文字
        # S012->S010 改成 S012-S010
        label = str(
            row["访问服务区顺序"]
        ).replace("->", "-")

        ax.text(
            start + duration / 2,
            y,
            label,
            ha="center",
            va="center",
            fontsize=9,
            color="white",
            clip_on=True,
            zorder=3,
        )


# ===================== 7. 首批硬时限 =====================
if first_deadline_h is not None:

    ax.axvline(
        first_deadline_h,
        color="#C44E52",
        linestyle="--",
        linewidth=1.8,
        zorder=4,
    )


# ===================== 8. 总完成时间 =====================
ax.axvline(
    completion_h,
    color="#8172B2",
    linestyle=":",
    linewidth=2.0,
    zorder=4,
)


# ===================== 9. Y 轴 =====================
y_labels = [
    f"{uav}({type_map.get(uav, '')})"
    for uav in uav_order
]

ax.set_yticks(range(len(uav_order)))
ax.set_yticklabels(
    y_labels,
    fontsize=13
)

# 让 U08 位于最上面
ax.invert_yaxis()


# ===================== 10. X 轴 =====================
ax.set_xlabel(
    "任务时间（h）",
    fontsize=14
)

# 不设置标题
# ax.set_title(...)

# 右边留一点空间显示紫色虚线
ax.set_xlim(
    0,
    completion_h + 0.04
)


# ===================== 11. 网格 =====================
ax.grid(
    axis="x",
    alpha=0.25,
    linewidth=0.8
)

ax.set_axisbelow(True)

for spine in ax.spines.values():
    spine.set_linewidth(0.9)


# ===================== 12. 图例 =====================
legend_handles = [

    Patch(
        facecolor=model_colors["A"],
        label="A 型"
    ),

    Patch(
        facecolor=model_colors["B"],
        label="B 型"
    ),

    Patch(
        facecolor=model_colors["C"],
        label="C 型"
    ),
]


# 首批硬时限图例
if first_deadline_h is not None:

    legend_handles.append(

        Line2D(
            [0],
            [0],
            color="#C44E52",
            linewidth=1.8,
            linestyle="--",
            label=f"首批硬时限 {first_deadline_h:g} h",
        )
    )


# 完成时间图例
legend_handles.append(

    Line2D(
        [0],
        [0],
        color="#8172B2",
        linewidth=2.0,
        linestyle=":",
        label=f"完成时间 {completion_h:.2f} h",
    )
)


ax.legend(
    handles=legend_handles,
    loc="upper center",
    bbox_to_anchor=(0.5, -0.15),
    ncol=len(legend_handles),
    frameon=False,
    fontsize=11,
    handlelength=2.7,
    columnspacing=1.5,
)


# ===================== 13. 排版和保存 =====================
plt.subplots_adjust(
    left=0.11,
    right=0.985,
    top=0.97,
    bottom=0.22
)

plt.savefig(
    output_path,
    dpi=400,
    bbox_inches="tight"
)
# plt.savefig(
#     output_path.with_suffix(".pdf"),
#     bbox_inches="tight"
# )

plt.show()

print(f"甘特图已保存至：{output_path.resolve()}")
print(f"方案完成时间：{completion_h:.4f} h")
