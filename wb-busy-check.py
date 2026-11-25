# 供 wb-daily-checkin.ps1 调用：统计最近有活动的 working 会话数
# 用法: python wb-busy-check.py <workbuddy.db路径> <截止时间戳ms>
# 输出: 一行数字（working 会话数）；查询失败退出码 3
import sqlite3
import sys
from contextlib import closing
from pathlib import Path


def main():
    if len(sys.argv) < 3:
        sys.exit(2)
    db_path = sys.argv[1]
    try:
        cutoff = int(sys.argv[2])
        with closing(sqlite3.connect(Path(db_path).resolve().as_uri() + '?mode=ro', uri=True)) as con:
            # 部分版本 last_activity_at 为 NULL；回退到实际更新时间。
            # 所有时间未知时保守视为忙，历史遗留 working 状态不永久阻止退出。
            n = con.execute(
                'select count(*) from sessions where status=? and '
                '(coalesce(last_activity_at,updated_at,created_at) is null or '
                'coalesce(last_activity_at,updated_at,created_at)>?)',
                ('working', cutoff),
            ).fetchone()[0]
        print(n)
    except Exception:
        sys.exit(3)


if __name__ == '__main__':
    main()
