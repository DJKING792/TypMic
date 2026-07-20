#!/usr/bin/env python3
"""文本后处理：术语表修正 + 可选 AI 润色。

两个能力，都可独立开关，且失败一律降级为「返回原文」，绝不阻断粘贴：

1. 术语表（glossary）：把常被识别错的产品名 / 人名 / 英文工具名纠正回来。
   读取同目录 glossary.txt，每行一条规则，两种写法：
       klawd => Claude          # 错词 => 正词（大小写不敏感匹配）
       Cursor                   # 单独一个词 = 告诉润色模型「优先用这个写法」
   `=>` 规则做**文本替换**（识别后立刻纠正，最稳）；
   单词条目作为**术语偏好**注入润色提示，让 LLM 倾向用它。

2. AI 润色（polish）：把口语化的识别原文整理成能直接用的文本——
   去口头禅、顺句、自动分段、数字/金额规范、明显口误自纠。
   走 OpenAI 兼容的 chat/completions 接口，模型可自由配置。

设计原则：润色是「增益」不是「依赖」。任一环节报错都返回上一步文本，
保证「识别 → 粘贴」主链路永远不被润色拖垮。
"""

import re
from pathlib import Path

import aiohttp


# --------------------------------------------------------------------------- #
# 术语表
# --------------------------------------------------------------------------- #
def load_glossary(path):
    """读取 glossary.txt，返回 (replacements, terms)。

    replacements: [(wrong, right), ...]  用于文本替换（=> 规则）
    terms:        ["Cursor", "TypMic", ...]  用于注入润色提示的术语偏好
    文件不存在或为空时返回 ([], [])，调用方据此自动跳过。
    """
    p = Path(path)
    if not p.exists():
        return [], []
    replacements = []
    terms = []
    try:
        with open(p, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=>" in line:
                    wrong, _, right = line.partition("=>")
                    wrong, right = wrong.strip(), right.strip()
                    if wrong and right:
                        replacements.append((wrong, right))
                        terms.append(right)
                else:
                    terms.append(line)
    except Exception:
        return [], []
    # 术语去重，保序
    seen = set()
    uniq_terms = []
    for t in terms:
        if t not in seen:
            seen.add(t)
            uniq_terms.append(t)
    return replacements, uniq_terms


def apply_glossary(text, replacements):
    """按 replacements 做大小写不敏感的整词/子串替换。失败返回原文。"""
    if not text or not replacements:
        return text
    out = text
    try:
        for wrong, right in replacements:
            # 大小写不敏感替换；wrong 里的正则元字符做转义
            out = re.sub(re.escape(wrong), right, out, flags=re.IGNORECASE)
    except Exception:
        return text
    return out


# --------------------------------------------------------------------------- #
# AI 润色
# --------------------------------------------------------------------------- #
# 公共基础规则：所有「改写类」模式共享（角色 / 标点 / 命令词 / 去重复）。
# 注意：大幅「去废话」不放在这里，由各模式按需叠加，使小说等模式可保留口语感。
_BASE_RULES = (
    "你是一个中文语音输入的文本整理助手。用户会给你一段语音识别的原始文本"
    "（通常没有标点、口语化、可能有口头禅和同音口误），请把它整理成可以直接粘贴使用的书面文本。\n\n"
    "【最重要】第一条规则：必须补全符合中文书写习惯的标点符号。根据语义和自然停顿，"
    "补上逗号、句号、顿号、分号、冒号、引号、书名号、问号、感叹号等。"
    "绝对不要输出一整段没有标点的纯文本。\n\n"
    "【命令词】若用户以指令口吻说出下列词，请转化为对应的格式或标点，而不是保留这几个字：\n"
    "- 「新段落」「换行」「另起一段」「分段」→ 在对应位置插入一个空行（分段）\n"
    "- 「句号」「点」→ 。\n"
    "- 「逗号」→ ，\n"
    "- 「问号」→ ？\n"
    "- 「感叹号」→ ！\n"
    "- 「冒号」→ ：\n"
    "- 「分号」→ ；\n\n"
    "【基础规则】\n"
    "1. 删除重复与自我修正中的废话（如「我今天，今天去了」→「今天去了」；"
    "「那个，就是那个超市」→「那个超市」）。\n"
)

# 大幅清理口语冗余（去废话核心），需要「口语变书面」的模式叠加这一段。
_DECLUTTER = (
    "2. 必须大幅清理口语冗余：删除所有口头禅、语气词和填充词，包括但不限于："
    "呃、啊、哎、嗯、呢、嘛、吧、呀、哦、额、嗨、那个、这个、就是说、就是、然后、"
    "然后然后、那个那个、这个这个、怎么说呢、我觉得吧、对吧、是吧、你知道吗、"
    "说白了、其实吧、反正、也就是、换句话说、一大堆、什么的、之类、那个啥、"
    "对不对、是不是、可能吧、应该吧、差不多、大概、好像、似乎、我个人觉得、"
    "说实话、说真的、讲真的、换句话、也就是说、或者说、总而言之、"
    "简单来说、话说回来、再说了、不瞒你说、说实在的、讲白了、老实说、说起来。\n"
)

# 各模式在「基础规则 + 去废话」之上追加的「风格」段落。
_STYLE_FULL = (
    _DECLUTTER +
    "3. 在不改变事实、观点与原意的前提下，可适度重组语句、删去冗余铺陈，使表达更简洁通顺；"
    "但必须保留用户提供的全部信息、专有名词与术语。\n"
    "4. 顺句、修正明显的同音口误（如「不是周五，是周四」直接写成「周四」）。\n"
    "5. 内容较长或有并列要点时，自动分段或列成条目。\n"
    "6. 规范数字、金额（如「三千六」写成「¥3,600」）、时间与单位。\n"
    "7. 技术术语、代码、英文标识符、专有名词保持原样，不要「翻译」或改写。\n"
    "8. 严格保持原意：不要扩写、不要添加原文没有的信息、不要回答其中的问题；"
    "只输出整理后的正文，不要任何解释、前言，也不要用引号包裹整段。"
)

_STYLE_LOGIC = (
    _DECLUTTER +
    "3. 【理顺逻辑】用户的话可能跳跃、零散、缺乏条理。请在保持原意和全部信息的前提下，"
    "补全省略的连接词、理清因果关系与主次顺序、把并列 / 递进关系显式化，使行文通顺连贯、有结构。\n"
    "4. 内容较长时按逻辑分段或列成条目，让层次清晰。\n"
    "5. 修正明显的同音口误，规范数字与单位。\n"
    "6. 技术术语、代码、英文标识符、专有名词保持原样。\n"
    "7. 严格保持原意：不要扩写、不要添加原文没有的信息、不要回答其中的问题；"
    "只输出整理后的正文，不要任何解释、前言，也不要用引号包裹整段。"
)

_STYLE_BUSINESS = (
    _DECLUTTER +
    "3. 【商务正式】这是公司 / 商业文案口述。请整理为专业、正式、得体的书面语："
    "用词精准、语气稳妥、避免口语化和情绪化表达，必要时按商务语境润色成通顺的段落或条目。\n"
    "4. 理顺逻辑、突出要点，长内容用分段或条目呈现，层次清晰，便于直接用于邮件 / 报告 / 方案。\n"
    "5. 修正同音口误，规范数字、金额（如「三千六」→「¥3,600」）、时间与单位。\n"
    "6. 技术术语、产品名、英文标识符、专有名词保持原样。\n"
    "7. 严格保持事实与数据：不要扩写、不要添加原文没有的信息、不要回答其中的问题；"
    "只输出整理后的正文，不要任何解释、前言，也不要用引号包裹整段。"
)

_STYLE_ADMIN = (
    _DECLUTTER +
    "3. 【行政公文】这是行政 / 公文类口述。请整理为规范、正式、严谨的行政公文语感："
    "用语准确、条理分明、措辞稳妥，符合公文「简明、准确、庄重」的风格。\n"
    "4. 按行政文书习惯分段、列点，使用「一是 / 二是」「第一 / 第二」或「关于……的」等规范表述；"
    "长内容条目化呈现，层次清晰。\n"
    "5. 修正同音口误，规范数字（如「三千六」→「3600」）、金额、时间与单位。\n"
    "6. 机关名、文件名、文号、专有名词、术语保持原样。\n"
    "7. 严格忠实原意与事实：不要扩写、不要添加原文没有的内容、不要回答其中的问题；"
    "只输出整理后的正文，不要任何解释、前言，也不要用引号包裹整段。"
)

_STYLE_NOVEL = (
    "2. 【保留文学性】这是小说 / 创作类口述。请保留原本的口语感、情绪、节奏与个人风格，"
    "不要把它改写成千篇一律的书面公文；允许保留适度的口语词和生动表达。\n"
    "3. 只删去最影响阅读的大量重复与无意义的纯粹语气词（如句首成串的「呃呃呃」），"
    "但保留能体现人物语气和性格的口头禅，不要一刀切清掉。\n"
    "4. 修正明显的同音口误（如人名、地点写错），规范明显的数字；"
    "但对话语气、方言感、停顿感可以保留，让文字有「说出来的味道」。\n"
    "5. 专有名词、人名、地名、作品名保持原样。\n"
    "6. 不要扩写、不要改变情节与原意、不要回答其中的问题；"
    "只输出整理后的正文，不要任何解释、前言，也不要用引号包裹整段。"
)

# 润色模式 → 完整系统提示词
MODE_PROMPTS = {
    "full": _BASE_RULES + _STYLE_FULL,
    "logic": _BASE_RULES + _STYLE_LOGIC,
    "business": _BASE_RULES + _STYLE_BUSINESS,
    "admin": _BASE_RULES + _STYLE_ADMIN,
    "novel": _BASE_RULES + _STYLE_NOVEL,
}
# 润色模式 → 中文标签（用于启动菜单 / 状态页 / 桌面页）
# 注：不再提供「只加标点」模式——云端 mimo-v2.5-asr 与本地 SenseVoice 均已原生输出带标点的文本，
# 额外跑一次 LLM 补标点纯属浪费；本地 Whisper / SenseVoice 用户也不需要走 AI 润色补标点。
MODE_LABELS = {
    "full": "通用润色",
    "logic": "理顺逻辑",
    "novel": "小说创作",
    "business": "公司文案",
    "admin": "行政公文",
}
# 合法 mode 全集（不含 punctuate）
VALID_MODES = set(MODE_PROMPTS.keys())
# 兼容别名（避免其它调用方引用 DEFAULT_SYSTEM_PROMPT 报错）
DEFAULT_SYSTEM_PROMPT = MODE_PROMPTS["full"]


# 深度思考开关：mimo-v2.5 是全模态模型，原生支持深度思考（thinking）。
# 但润色是轻量任务——只补标点 / 去废话 / 顺句，开了深度思考只会更慢、更费 token、
# 还可能把简单改写过度复杂化。这里一律关闭，防止「乱用」深度思考。
# 接口约定：请求体顶层传 "thinking": {"type": "disabled"}（enabled 才开）。
THINKING_DISABLED = {"type": "disabled"}


class Polisher:
    """OpenAI 兼容 chat/completions 润色客户端。

    参数均可通过环境变量配置（见 voice_input_server 里的读取逻辑）。
    ready() 为 False 时调用方应跳过润色。
    """

    def __init__(self, api_url, api_key, model, system_prompt=None, timeout=30,
                 mode="full"):
        self.api_url = (api_url or "").strip()
        self.api_key = (api_key or "").strip()
        self.model = (model or "").strip()
        self.mode = (mode or "full").strip().lower()
        # 各润色模式从 MODE_PROMPTS 取对应风格提示；也可显式传入 system_prompt 覆盖。
        if system_prompt:
            self.system_prompt = system_prompt
        else:
            self.system_prompt = MODE_PROMPTS.get(self.mode, MODE_PROMPTS["full"])
        self.timeout = timeout
        # 记录最近一次润色失败原因，便于服务端/桌面页直接展示（默认无错）。
        self.last_error = None

    def ready(self):
        return bool(self.api_url and self.api_key and self.model)

    async def polish(self, text, terms=None):
        """润色文本。任何异常都返回原文（降级），绝不抛出打断主链路。

        与旧版区别：失败时会在 self.last_error 记录原因并打到控制台，
        不再「静默吞掉」，方便排查（如模型名不被 chat 端点识别、key 失效）。
        """
        if not text or not text.strip():
            self.last_error = None
            return text
        if not self.ready():
            self.last_error = (
                "润色未就绪：缺少 url / api_key / model 之一"
                f"（url={self.api_url!r}, model={self.model!r}）"
            )
            print(f"[polish] {self.last_error}", flush=True)
            return text

        sys_prompt = self.system_prompt
        # 术语偏好注入提示，让润色模型倾向使用标准写法（各模式均生效）。
        if terms:
            sys_prompt += (
                "\n\n以下是用户的专有名词/术语表，若原文出现相近发音或写法，"
                "请优先使用这些标准写法：" + "、".join(terms) + "。"
            )

        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": sys_prompt},
                {"role": "user", "content": text},
            ],
            "temperature": 0.2,
            # 关闭深度思考：轻量润色无需推理链，避免更慢/更贵/改写过度复杂化。
            "thinking": THINKING_DISABLED,
        }
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "api-key": self.api_key,  # 兼容小米等用 api-key 头的服务
            "Content-Type": "application/json",
        }
        try:
            timeout = aiohttp.ClientTimeout(total=self.timeout)
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    self.api_url, json=payload, headers=headers, timeout=timeout
                ) as resp:
                    if resp.status != 200:
                        body = (await resp.text())[:300]
                        self.last_error = (
                            f"润色接口返回 HTTP {resp.status}：{body}"
                        )
                        print(f"[polish] {self.last_error}", flush=True)
                        return text
                    data = await resp.json()
            polished = data["choices"][0]["message"]["content"]
            polished = (polished or "").strip().strip('"').strip("'").strip()
            self.last_error = None
            return polished or text
        except Exception as e:
            self.last_error = f"润色调用异常：{type(e).__name__}: {e}"
            print(f"[polish] {self.last_error}", flush=True)
            return text
