"use client";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { ReactNode, useEffect, useState } from "react";
import { api } from "@/lib/api";
import { setTimezone } from "@/lib/format";

interface NavItem {
  href: string;
  label: string;
  icon: string;
}

interface NavSection {
  id: string;
  label: string;
  icon: string;
  rootHref: string;
  items: NavItem[];
}

const SECTIONS: NavSection[] = [
  {
    id: "dashboard",
    label: "لوحة المتابعة",
    icon: "⚡",
    rootHref: "/",
    items: [],
  },
  {
    id: "network",
    label: "المشتركون والشبكة",
    icon: "👥",
    rootHref: "/subscribers",
    items: [
      { href: "/subscribers", label: "المشتركون والعدادات", icon: "👥" },
      { href: "/generators", label: "المولدات والمناطق", icon: "⚡" },
      { href: "/generators/power-loss", label: "كاشف الفاقد والسرقات", icon: "🔍" },
    ],
  },
  {
    id: "field",
    label: "الميدان والقراءات",
    icon: "📋",
    rootHref: "/review",
    items: [
      { href: "/review", label: "مراجعة القراءات", icon: "📋" },
      { href: "/tasks", label: "المهام والتكليفات", icon: "⏱️" },
      { href: "/error-reports", label: "بلاغات الموظفين", icon: "⚠️" },
    ],
  },
  {
    id: "finance",
    label: "المالية والفوترة",
    icon: "💰",
    rootHref: "/statements",
    items: [
      { href: "/statements", label: "الكشوف الأسبوعية", icon: "📑" },
      { href: "/payments", label: "المدفوعات والتحصيل", icon: "💵" },
      { href: "/cycles", label: "الدورات والأسعار", icon: "🔄" },
      { href: "/adjustments", label: "التسويات والأرصدة", icon: "⚖️" },
    ],
  },
  {
    id: "admin",
    label: "الإدارة والتقارير",
    icon: "⚙️",
    rootHref: "/reports",
    items: [
      { href: "/reports", label: "التقارير الرسمية", icon: "📊" },
      { href: "/imports", label: "استيراد Excel", icon: "📥" },
      { href: "/users", label: "الموظفون والحسابات", icon: "👤" },
      { href: "/devices", label: "الأجهزة والمزامنة", icon: "📱" },
      { href: "/backups", label: "النسخ الاحتياطية", icon: "💾" },
      { href: "/audit", label: "سجل التدقيق", icon: "🛡️" },
      { href: "/settings", label: "إعدادات النظام", icon: "⚙️" },
    ],
  },
];

export default function Shell({ children }: { children: ReactNode }) {
  const path = usePathname();
  const router = useRouter();
  const [me, setMe] = useState<{ full_name: string } | null>(null);
  const [open, setOpen] = useState(false);

  useEffect(() => {
    api("auth/me").then(setMe).catch(() => undefined);
    api<{ key: string; value: string }[]>("settings")
      .then((s) => setTimezone(s.find((x) => x.key === "business_timezone")?.value ?? ""))
      .catch(() => undefined);
  }, []);

  useEffect(() => setOpen(false), [path]);

  async function logout() {
    await api("/auth/logout", { method: "POST" }).catch(() => undefined);
    router.replace("/login");
  }

  // Determine active section
  const activeSection = SECTIONS.find((s) => {
    if (s.id === "dashboard") return path === "/";
    return s.items.some((it) => path === it.href || path.startsWith(it.href + "/"));
  }) || SECTIONS[0];

  const isItemActive = (href: string) => {
    return href === "/" ? path === "/" : path === href || path.startsWith(href + "/");
  };

  return (
    <div className="shell">
      <aside className={`sidebar ${open ? "open" : ""}`}>
        <div className="brand">
          <span className="brand-mark">⚡</span>
          <div>
            <strong>GMS</strong>
            <small>إدارة المولدات</small>
          </div>
        </div>

        <nav className="main-nav">
          {SECTIONS.map((section) => {
            const isSecActive = section.id === activeSection.id;
            return (
              <div key={section.id} className="nav-section-wrap">
                <Link
                  href={section.rootHref}
                  className={`nav-main-link ${isSecActive ? "active" : ""}`}
                >
                  <span className="nav-main-icon">{section.icon}</span>
                  <span className="nav-main-label">{section.label}</span>
                </Link>

                {/* Sub-links in sidebar for mobile or quick expansion */}
                {isSecActive && section.items.length > 0 && (
                  <div className="sidebar-sublinks">
                    {section.items.map((it) => (
                      <Link
                        key={it.href}
                        href={it.href}
                        className={`sidebar-sublink ${isItemActive(it.href) ? "active" : ""}`}
                      >
                        <span className="sidebar-sublink-dot" />
                        <span>{it.label}</span>
                      </Link>
                    ))}
                  </div>
                )}
              </div>
            );
          })}
        </nav>
      </aside>

      {open && <div className="sidebar-scrim" onClick={() => setOpen(false)} />}

      <div className="main">
        <header className="topbar">
          <button className="icon-btn menu-btn" onClick={() => setOpen(!open)} aria-label="القائمة">
            ☰
          </button>
          <div className="topbar-section-title">
            <span className="topbar-icon">{activeSection.icon}</span>
            <span className="topbar-label">{activeSection.label}</span>
          </div>
          <span className="spacer" />
          <span className="muted topbar-user">{me?.full_name}</span>
          <button className="btn btn-ghost" onClick={logout}>
            تسجيل الخروج
          </button>
        </header>

        {/* Floating Sub-Tabs Header */}
        {activeSection.items.length > 0 && (
          <nav className="subnav-bar" aria-label="أقسام الصفحة">
            <div className="subnav-container">
              {activeSection.items.map((it) => {
                const active = isItemActive(it.href);
                return (
                  <Link
                    key={it.href}
                    href={it.href}
                    className={`subnav-item ${active ? "active" : ""}`}
                  >
                    <span className="subnav-icon">{it.icon}</span>
                    <span>{it.label}</span>
                  </Link>
                );
              })}
            </div>
          </nav>
        )}

        <main className="content">{children}</main>
      </div>
    </div>
  );
}
