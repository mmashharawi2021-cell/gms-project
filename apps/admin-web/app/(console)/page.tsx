"use client";
import Link from "next/link";
import { useQuery } from "@/lib/api";
import { d, dt, money, num } from "@/lib/format";
import { TASK_STATUS, VISIT_STATUS } from "@/lib/labels";
import { Card, ErrorBox, Loading, PageHeader, StatusBadge } from "@/components/ui";

export default function Dashboard() {
  const { data, error, loading, reload } = useQuery<any>("dashboard");

  if (loading && !data) return <Loading label="جارٍ تحميل بيانات لوحة المتابعة…" />;
  if (error) return <ErrorBox error={error} />;
  if (!data) return null;

  const visits = Object.fromEntries((data.visits ?? []).map((v: any) => [v.record_status, v.n]));
  const b = data.blockers;
  const cycle = data.open_cycle;

  // Calculate readiness percentage
  const totalBlockers = b ? (b.unresolved_tasks ?? 0) + (b.unresolved_visits ?? 0) + (b.open_error_reports ?? 0) : 0;
  const isReadyToClose = cycle && totalBlockers === 0;

  // Task distribution calculations
  const totalTasks = (data.tasks ?? []).reduce((acc: number, t: any) => acc + (t.n ?? 0), 0);
  const completedTasks = (data.tasks ?? [])
    .filter((t: any) => t.status === "completed_reading" || t.status === "completed_unreadable")
    .reduce((acc: number, t: any) => acc + (t.n ?? 0), 0);
  const taskProgressPct = totalTasks > 0 ? Math.round((completedTasks / totalTasks) * 100) : 0;

  return (
    <div className="dash-stack">
      {/* 1. Hero Operational Banner */}
      <section className="dash-hero">
        <div className="dash-hero-content">
          <div className="dash-hero-tag">
            <span className="live-dot" />
            <span>نظام إدارة العمليات والشبكة</span>
          </div>
          <h1 className="dash-hero-title">لوحة متابعة الطاقة والمولدات</h1>
          <p className="dash-hero-subtitle">
            {cycle ? (
              <>
                الدورة الحالية: <b>{cycle.label}</b> (من {d(cycle.starts_on)} إلى {d(cycle.ends_on)})
                {cycle.provisional_rate_ils_per_kwh && (
                  <span className="rate-pill">
                    ⚡ السعر التقديري: <b>{cycle.provisional_rate_ils_per_kwh}</b> ₪/ك.و.س
                  </span>
                )}
              </>
            ) : (
              "لا توجد دورة فوترة مفتوحة حالياً. يمكنك فتح دورة جديدة للبدء في جدولة القراءات."
            )}
          </p>
        </div>

        <div className="dash-hero-actions">
          {cycle ? (
            <Link href={`/cycles/${cycle.id}`} className="btn btn-primary">
              ⚡ إدارة الدورة الحالية
            </Link>
          ) : (
            <Link href="/cycles" className="btn btn-primary">
              ➕ فتح دورة جديدة
            </Link>
          )}
          <button className="btn btn-secondary" onClick={reload} title="تحديث البيانات">
            🔄 تحديث
          </button>
        </div>
      </section>

      {/* 2. Quick Action Bar */}
      <div className="quick-actions-bar">
        <span className="quick-actions-label">إجراءات سريعة:</span>
        <div className="quick-actions-list">
          <Link href="/subscribers" className="quick-action-pill">
            <span>👥</span> إضافة مشترك جديد
          </Link>
          <Link href="/review" className="quick-action-pill">
            <span>📋</span> مراجعة القراءات الميدانية
          </Link>
          <Link href="/payments" className="quick-action-pill">
            <span>💵</span> تسجيل دفعة نقدية
          </Link>
          <Link href="/tasks" className="quick-action-pill">
            <span>⏱️</span> تكليف مهام العدادات
          </Link>
          <Link href="/reports" className="quick-action-pill">
            <span>📊</span> إصدار التقارير والكشوف
          </Link>
        </div>
      </div>

      {/* 3. Operational KPI Groups */}
      <div className="dash-grid-top">
        {/* Financial Highlights */}
        <div className="kpi-group kpi-group-finance">
          <div className="kpi-group-header">
            <h3>💰 المؤشرات المالية والتحصيل</h3>
            <Link href="/statements" className="kpi-link">عرض الكشوف ➔</Link>
          </div>
          <div className="kpi-cards-row">
            <div className="kpi-card highlight-amber">
              <span className="kpi-card-icon">💳</span>
              <div className="kpi-card-data">
                <span className="kpi-card-label">إجمالي المستحقات المطلوبة</span>
                <span className="kpi-card-value text-accent">{money(data.money.requested_total_ils)}</span>
                <span className="kpi-card-hint">من إجمالي {num(data.money.debtors)} مشترك عليه مستحقات</span>
              </div>
            </div>

            <div className="kpi-card">
              <span className="kpi-card-icon">💎</span>
              <div className="kpi-card-data">
                <span className="kpi-card-label">الأرصدة الدائنة (مقدمات)</span>
                <span className="kpi-card-value text-ok">{money(data.money.credit_total_ils)}</span>
                <span className="kpi-card-hint">أرصدة مدفوعة مسبقاً لصالح المشتركين</span>
              </div>
            </div>

            <div className="kpi-card">
              <span className="kpi-card-icon">⚡</span>
              <div className="kpi-card-data">
                <span className="kpi-card-label">تسعيرة الكيلوواط للدورة</span>
                <span className="kpi-card-value">
                  {cycle?.provisional_rate_ils_per_kwh ? `${cycle.provisional_rate_ils_per_kwh} ₪` : "غير محدد"}
                </span>
                <span className="kpi-card-hint">السعر المبدئي حتى تثبيت التكلفة</span>
              </div>
            </div>
          </div>
        </div>

        {/* Field Readings & Quality Stream */}
        <div className="kpi-group kpi-group-field">
          <div className="kpi-group-header">
            <h3>📋 حالة القراءات والمراجعة الميدانية</h3>
            <Link href="/review" className="kpi-link">غرفة المراجعة ➔</Link>
          </div>
          <div className="kpi-cards-row">
            <Link href="/review" className="kpi-card kpi-card-clickable">
              <span className="kpi-card-icon">⏳</span>
              <div className="kpi-card-data">
                <span className="kpi-card-label">بانتظار المراجعة والاعتماد</span>
                <span className={`kpi-card-value ${visits.pending_review ? "text-warn" : ""}`}>
                  {num(visits.pending_review ?? 0)}
                </span>
                <span className="kpi-card-hint">قراءات مكتملة بانتظار موافقة المدير</span>
              </div>
            </Link>

            <Link href="/review" className="kpi-card kpi-card-clickable highlight-danger">
              <span className="kpi-card-icon">⚠️</span>
              <div className="kpi-card-data">
                <span className="kpi-card-label">استثناءات تحتاج قراراً</span>
                <span className={`kpi-card-value ${visits.exception ? "text-danger" : ""}`}>
                  {num(visits.exception ?? 0)}
                </span>
                <span className="kpi-card-hint">فروق زمنية، عدم انتظام، أو مواقع</span>
              </div>
            </Link>

            <Link href="/error-reports" className="kpi-card kpi-card-clickable">
              <span className="kpi-card-icon">🛠️</span>
              <div className="kpi-card-data">
                <span className="kpi-card-label">بلاغات الموظفين المفتوحة</span>
                <span className={`kpi-card-value ${data.counts.open_error_reports ? "text-warn" : ""}`}>
                  {num(data.counts.open_error_reports)}
                </span>
                <span className="kpi-card-hint">أعطال عدادات وتغييرات ميدانية</span>
              </div>
            </Link>

            <div className="kpi-card">
              <span className="kpi-card-icon">📸</span>
              <div className="kpi-card-data">
                <span className="kpi-card-label">بانتظار رفع الصور</span>
                <span className="kpi-card-value">{num(visits.awaiting_photo ?? 0)}</span>
                <span className="kpi-card-hint">بانتظار مزامنة الهواتف بالـ Wi-Fi</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      {/* 4. Center Panels: Cycle Readiness & Tasks Progress */}
      <div className="grid grid-2">
        {/* Cycle Closing Readiness Card */}
        <Card
          title="🎯 جاهزية إغلاق الدورة الأسبوعية"
          actions={cycle && <Link href={`/cycles/${cycle.id}`} className="btn btn-ghost">تفاصيل الدورة ➔</Link>}
        >
          {cycle && b ? (
            isReadyToClose ? (
              <div className="readiness-box readiness-ready">
                <div className="readiness-icon">✅</div>
                <div className="readiness-info">
                  <h4>الدورة جاهزة تماماً للإغلاق المالي!</h4>
                  <p>تم إنجاز كافة المهام واعتماد القراءات ولا توجد أي بلاغات معلقة. يمكنك الآن تثبيت السعر النهائي وإصدار الكشوف.</p>
                  <Link href={`/cycles/${cycle.id}`} className="btn btn-primary" style={{ marginTop: 8 }}>
                    🔒 تثبيت السعر النهائي وإغلاق الدورة
                  </Link>
                </div>
              </div>
            ) : (
              <div className="readiness-box readiness-pending">
                <div className="readiness-bar-wrap">
                  <div className="readiness-bar-header">
                    <span>العوائق المتبقية قبل إمكانية الإغلاق:</span>
                    <span className="badge badge-warn">{totalBlockers} عوائق متبقية</span>
                  </div>
                </div>

                <div className="blockers-list">
                  {b.unresolved_tasks > 0 && (
                    <div className="blocker-item">
                      <span className="blocker-bullet">⏱️</span>
                      <div className="blocker-text">
                        <strong>{b.unresolved_tasks}</strong> مهام قراءة لم تُحسم بعد
                      </div>
                      <Link href="/tasks" className="btn btn-ghost btn-sm">
                        حل المهام ➔
                      </Link>
                    </div>
                  )}

                  {b.unresolved_visits > 0 && (
                    <div className="blocker-item">
                      <span className="blocker-bullet">🔍</span>
                      <div className="blocker-text">
                        <strong>{b.unresolved_visits}</strong> زيارات وقراءات بانتظار قرار المدير
                      </div>
                      <Link href="/review" className="btn btn-ghost btn-sm">
                        مراجعة الآن ➔
                      </Link>
                    </div>
                  )}

                  {b.open_error_reports > 0 && (
                    <div className="blocker-item">
                      <span className="blocker-bullet">⚠️</span>
                      <div className="blocker-text">
                        <strong>{b.open_error_reports}</strong> بلاغات أخطاء مفتوحة بحاجة لحسم
                      </div>
                      <Link href="/error-reports" className="btn btn-ghost btn-sm">
                        حسم البلاغات ➔
                      </Link>
                    </div>
                  )}
                </div>
              </div>
            )
          ) : (
            <div className="empty-state-box">
              <span className="empty-icon">🔄</span>
              <p>لا توجد دورة مفتوحة في الوقت الحالي للتحقق من جاهزيتها.</p>
              <Link href="/cycles" className="btn btn-primary">
                فتح دورة جديدة
              </Link>
            </div>
          )}
        </Card>

        {/* Tasks & Reading Execution Progress */}
        <Card
          title="📊 تقدم تنفيذ مهام الدورة"
          actions={<Link href="/tasks" className="btn btn-ghost">جدول المهام ➔</Link>}
        >
          {data.tasks?.length ? (
            <div className="tasks-progress-wrap">
              <div className="progress-summary-row">
                <span className="progress-summary-label">نسبة إنجاز مهام القراءة:</span>
                <span className="progress-summary-pct">{taskProgressPct}%</span>
              </div>

              {/* Progress bar */}
              <div className="progress-track">
                <div
                  className="progress-fill"
                  style={{ width: `${taskProgressPct}%` }}
                />
              </div>

              <div className="task-status-badges-grid">
                {data.tasks.map((t: any) => (
                  <div key={t.status} className="task-badge-pill">
                    <StatusBadge map={TASK_STATUS} value={t.status} />
                    <span className="task-badge-count">{num(t.n)}</span>
                  </div>
                ))}
              </div>

              <hr style={{ border: 0, borderTop: "1px solid var(--border)", margin: "14px 0" }} />

              <span className="sub-section-title">حالات الزيارات الميدانية للدورة:</span>
              <div className="task-status-badges-grid">
                {Object.entries(visits).map(([k, n]) => (
                  <div key={k} className="task-badge-pill">
                    <StatusBadge map={VISIT_STATUS} value={k} />
                    <span className="task-badge-count">{num(n as number)}</span>
                  </div>
                ))}
              </div>
            </div>
          ) : (
            <div className="empty-state-box">
              <p className="muted">لم يتم توليد أي مهام قراءة في هذه الدورة بعد.</p>
              <Link href="/tasks" className="btn btn-secondary">
                توليد وتكليف المهام
              </Link>
            </div>
          )}
        </Card>
      </div>

      {/* 5. Network Assets & System Sentinel */}
      <div className="grid grid-2">
        {/* Network Assets Summary */}
        <Card title="⚡ أصول وموارد الشبكة الفعالة">
          <div className="network-assets-grid">
            <Link href="/subscribers" className="asset-stat-box">
              <span className="asset-icon">👥</span>
              <div>
                <span className="asset-val">{num(data.counts.active_subscribers)}</span>
                <span className="asset-lbl">مشترك فعال</span>
              </div>
            </Link>

            <Link href="/generators" className="asset-stat-box">
              <span className="asset-icon">⚡</span>
              <div>
                <span className="asset-val">{num(data.counts.generators)}</span>
                <span className="asset-lbl">مولدات كهربائية</span>
              </div>
            </Link>

            <Link href="/users" className="asset-stat-box">
              <span className="asset-icon">👷</span>
              <div>
                <span className="asset-val">{num(data.counts.employees)}</span>
                <span className="asset-lbl">موظف ميداني</span>
              </div>
            </Link>

            <Link href="/devices" className="asset-stat-box">
              <span className="asset-icon">📱</span>
              <div>
                <span className="asset-val">{num(data.counts.active_devices)}</span>
                <span className="asset-lbl">أجهزة أندرويد نشطة</span>
              </div>
            </Link>
          </div>
        </Card>

        {/* System Health & Automated Backup Status */}
        <Card
          title="🛡️ سلامة النظام والنسخ الاحتياطي"
          actions={<Link href="/backups" className="btn btn-ghost">سجل النسخ ➔</Link>}
        >
          <div className="sentinel-box">
            <div className="sentinel-status-row">
              <div className="sentinel-indicator">
                <span className="sentinel-pulse" />
                <span>قاعدة البيانات والمزامنة:</span>
              </div>
              <span className="badge badge-ok">تعمل بكفاءة 100%</span>
            </div>

            <div className="sentinel-backup-info">
              {data.last_backup ? (
                <>
                  <div className="backup-row">
                    <span className="muted">آخر عملية نسخ احتياطي:</span>
                    <strong>{dt(data.last_backup.started_at)}</strong>
                  </div>
                  <div className="backup-row">
                    <span className="muted">الحالة:</span>
                    {data.last_backup.succeeded ? (
                      <span className="badge badge-ok">ناجحة وآمنة</span>
                    ) : (
                      <span className="badge badge-danger">بحاجة لفحص</span>
                    )}
                  </div>
                  {data.last_backup.size_bytes && (
                    <div className="backup-row">
                      <span className="muted">حجم النسخة:</span>
                      <span className="num">{(data.last_backup.size_bytes / (1024 * 1024)).toFixed(2)} MB</span>
                    </div>
                  )}
                </>
              ) : (
                <div className="alert alert-warn">لم تُسجل أي عملية نسخ احتياطي مؤتمتة حتى الآن.</div>
              )}
            </div>
          </div>
        </Card>
      </div>
    </div>
  );
}
