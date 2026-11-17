"""Daily backup loop for the `backup` container: runs at GMS_BACKUP_HOUR (business timezone), keeps running on errors."""
from __future__ import annotations

import os
import subprocess
import sys
import time
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


def next_run(now: datetime, hour: int) -> datetime:
    target = now.replace(hour=hour, minute=0, second=0, microsecond=0)
    return target if target > now else target + timedelta(days=1)


def main() -> int:
    tz = ZoneInfo(os.environ.get("GMS_BUSINESS_TZ", "Asia/Gaza"))
    hour = int(os.environ.get("GMS_BACKUP_HOUR", "2"))
    while True:
        now = datetime.now(tz)
        wait = (next_run(now, hour) - now).total_seconds()
        print(f"next backup in {int(wait)}s", flush=True)
        time.sleep(wait)
        rc = subprocess.run([sys.executable, "-m", "app.ops.backup", "run", "scheduled"]).returncode
        print(f"backup finished rc={rc}", flush=True)


if __name__ == "__main__":
    sys.exit(main())
