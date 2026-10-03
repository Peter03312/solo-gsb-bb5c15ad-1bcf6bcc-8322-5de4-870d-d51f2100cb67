"""敏感区间校验、合并与脱敏替换，以及敏感短语命中覆盖核验。

区间约定：左闭右开 [start, end)，位置按 Unicode 码点计，
与 Python 字符串的下标语义一致（包括对 BMP 之外的字符）。
"""

REDACTION_PLACEHOLDER = "[已遮蔽]"


class IntervalOutOfBoundsError(ValueError):
    """区间为空、倒置或超出原文长度。"""


def validate_intervals(text_length: int, intervals: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """校验并规范化区间；任何越界区间都会让整次请求被拒绝。"""
    normalized = []
    for start, end in intervals:
        if start < 0 or end > text_length or start >= end:
            raise IntervalOutOfBoundsError(
                f"interval [{start}, {end}) is out of bounds for text length {text_length}"
            )
        normalized.append((start, end))
    return normalized


def merge_intervals(intervals: list[tuple[int, int]]) -> list[tuple[int, int]]:
    """合并相交或相邻的区间，返回按起点排序的不相交区间列表。"""
    merged: list[list[int]] = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(start, end) for start, end in merged]


def redact_text(text: str, intervals: list[tuple[int, int]]) -> str:
    """将合并后的每个区间替换为占位符，其余原文保持不变。"""
    parts: list[str] = []
    cursor = 0
    for start, end in merge_intervals(intervals):
        parts.append(text[cursor:start])
        parts.append(REDACTION_PLACEHOLDER)
        cursor = end
    parts.append(text[cursor:])
    return "".join(parts)


def _is_fully_covered(merged: list[tuple[int, int]], start: int, end: int) -> bool:
    """命中区间 [start, end) 是否被某个合并后的遮蔽区间完整覆盖。"""
    for m_start, m_end in merged:
        if m_start > start:
            break  # 合并区间按起点排序，后续区间不可能再覆盖 start
        if end <= m_end:
            return True
    return False


def find_uncovered_hits(
    text: str, intervals: list[tuple[int, int]], phrases: list[str]
) -> list[tuple[int, int]]:
    """找出未被遮蔽区间完整覆盖的敏感短语命中区间（按起点排序）。

    - 查找按 Unicode 码点、区分大小写的字面量匹配（与 str.find 语义一致）；
    - 同一短语的重叠命中各自计入（如 "aa" 在 "aaa" 中命中 [0, 2) 与 [1, 3)）；
    - 每个命中区间 [start, end) 须被某个（相交/相邻合并后的）遮蔽区间完整覆盖；
    - 空清单（核验停用）或空原文返回空列表；清单中的空短语被忽略
      （空短语在清单替换时已被拒绝，此处仅作防御）。
    """
    if not phrases or not text:
        return []
    merged = merge_intervals(intervals)
    hits: list[tuple[int, int]] = []
    for phrase in phrases:
        if not phrase:
            continue
        start = 0
        while True:
            index = text.find(phrase, start)
            if index < 0:
                break
            end = index + len(phrase)
            if not _is_fully_covered(merged, index, end):
                hits.append((index, end))
            start = index + 1
    return sorted(hits)
