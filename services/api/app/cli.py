"""Operator commands. Usage:
    python -m app.cli create-first-manager --username admin --full-name "..."   (password read from a prompt)
"""
from __future__ import annotations

import argparse
import getpass
import sys

import psycopg

from app.config import get_settings
from app.security import hash_password, validate_new_password


def create_first_manager(username: str, full_name: str) -> int:
    pw = getpass.getpass("كلمة المرور: ")
    if pw != getpass.getpass("تأكيد كلمة المرور: "):
        print("كلمتا المرور غير متطابقتين", file=sys.stderr)
        return 2
    problem = validate_new_password(pw, username)
    if problem:
        print(problem, file=sys.stderr)
        return 2
    with psycopg.connect(get_settings().database_url) as conn:
        if conn.execute("SELECT EXISTS (SELECT 1 FROM gms.app_users)").fetchone()[0]:
            print("يوجد مستخدمون بالفعل؛ أنشئ الحسابات من لوحة المدير", file=sys.stderr)
            return 3
        conn.execute("INSERT INTO gms.app_users(username,password_hash,full_name,role) VALUES (%s,%s,%s,'manager')",
                     (username.lower(), hash_password(pw), full_name))
    print("تم إنشاء حساب المدير الأول")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="gms")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create-first-manager")
    c.add_argument("--username", required=True)
    c.add_argument("--full-name", required=True)
    a = ap.parse_args()
    if a.cmd == "create-first-manager":
        return create_first_manager(a.username, a.full_name)
    return 1


if __name__ == "__main__":
    sys.exit(main())
