# -*- coding: utf-8 -*-
"""
Generator for GMS Comprehensive User Manual in Arabic (.docx)
"""
import os
import docx
from docx.shared import Inches, Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT, WD_ALIGN_VERTICAL
from docx.oxml import OxmlElement, parse_xml
from docx.oxml.ns import qn, nsdecls

def create_manual(output_path: str):
    doc = docx.Document()

    # Set page margins (1 inch)
    for section in doc.sections:
        section.top_margin = Inches(0.8)
        section.bottom_margin = Inches(0.8)
        section.left_margin = Inches(0.8)
        section.right_margin = Inches(0.8)

    def set_p_rtl(p):
        pPr = p._p.get_or_add_pPr()
        bidi = OxmlElement('w:bidi')
        bidi.set(qn('w:val'), '1')
        pPr.append(bidi)
        p.alignment = WD_ALIGN_PARAGRAPH.RIGHT

    def set_cell_rtl(cell):
        tcPr = cell._tc.get_or_add_tcPr()
        # RTL text direction
        bidi = OxmlElement('w:bidi')
        bidi.set(qn('w:val'), '1')
        for p in cell.paragraphs:
            set_p_rtl(p)

    def set_table_rtl(table):
        table.alignment = WD_TABLE_ALIGNMENT.CENTER
        tblPr = table._tbl.tblPr
        bidiVisual = OxmlElement('w:bidiVisual')
        tblPr.append(bidiVisual)

    def add_title(text):
        p = doc.add_paragraph()
        set_p_rtl(p)
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        run = p.add_run(text)
        run.bold = True
        run.font.size = Pt(24)
        run.font.name = "Arial"
        run.font.color.rgb = RGBColor(15, 23, 42) # Slate 900
        p.paragraph_format.space_before = Pt(20)
        p.paragraph_format.space_after = Pt(6)
        return p

    def add_subtitle(text):
        p = doc.add_paragraph()
        set_p_rtl(p)
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        run = p.add_run(text)
        run.font.size = Pt(13)
        run.font.name = "Arial"
        run.font.color.rgb = RGBColor(100, 116, 139) # Slate 500
        p.paragraph_format.space_after = Pt(24)
        return p

    def add_h1(text):
        p = doc.add_paragraph()
        set_p_rtl(p)
        run = p.add_run(text)
        run.bold = True
        run.font.size = Pt(16)
        run.font.name = "Arial"
        run.font.color.rgb = RGBColor(30, 58, 138) # Dark Navy
        p.paragraph_format.space_before = Pt(18)
        p.paragraph_format.space_after = Pt(6)
        return p

    def add_h2(text):
        p = doc.add_paragraph()
        set_p_rtl(p)
        run = p.add_run(text)
        run.bold = True
        run.font.size = Pt(13)
        run.font.name = "Arial"
        run.font.color.rgb = RGBColor(180, 83, 9) # Amber 700
        p.paragraph_format.space_before = Pt(12)
        p.paragraph_format.space_after = Pt(4)
        return p

    def add_p(text, bold_prefix=None):
        p = doc.add_paragraph()
        set_p_rtl(p)
        if bold_prefix:
            r_pre = p.add_run(bold_prefix)
            r_pre.bold = True
            r_pre.font.size = Pt(11)
            r_pre.font.name = "Arial"
            r_pre.font.color.rgb = RGBColor(15, 23, 42)
        run = p.add_run(text)
        run.font.size = Pt(11)
        run.font.name = "Arial"
        run.font.color.rgb = RGBColor(51, 65, 85) # Slate 700
        p.paragraph_format.space_after = Pt(4)
        p.paragraph_format.line_spacing = 1.2
        return p

    def add_bullet(text, bold_prefix=None):
        p = doc.add_paragraph(style='List Bullet')
        set_p_rtl(p)
        if bold_prefix:
            r_pre = p.add_run(bold_prefix)
            r_pre.bold = True
            r_pre.font.size = Pt(11)
            r_pre.font.name = "Arial"
            r_pre.font.color.rgb = RGBColor(15, 23, 42)
        run = p.add_run(text)
        run.font.size = Pt(11)
        run.font.name = "Arial"
        run.font.color.rgb = RGBColor(51, 65, 85)
        p.paragraph_format.space_after = Pt(3)
        p.paragraph_format.line_spacing = 1.15
        return p

    def add_callout(text, title="ملاحظة هامة"):
        table = doc.add_table(rows=1, cols=1)
        set_table_rtl(table)
        table.autofit = False
        table.columns[0].width = Inches(6.8)
        cell = table.cell(0, 0)
        set_cell_rtl(cell)
        
        # Light amber / blue background
        shading = parse_xml(r'<w:shd {} w:fill="F8FAFC"/>'.format(nsdecls('w')))
        cell._tc.get_or_add_tcPr().append(shading)
        
        # Border
        borders = parse_xml(r'''
            <w:tcBorders {} >
                <w:top w:val="none"/>
                <w:left w:val="none"/>
                <w:bottom w:val="none"/>
                <w:right w:val="single" w:sz="24" w:space="0" w:color="0284C7"/>
            </w:tcBorders>
        '''.format(nsdecls('w')))
        cell._tc.get_or_add_tcPr().append(borders)
        
        p = cell.paragraphs[0]
        set_p_rtl(p)
        r_title = p.add_run(f"📌 {title}: ")
        r_title.bold = True
        r_title.font.name = "Arial"
        r_title.font.size = Pt(10.5)
        r_title.font.color.rgb = RGBColor(2, 132, 199)
        
        r_text = p.add_run(text)
        r_text.font.name = "Arial"
        r_text.font.size = Pt(10.5)
        r_text.font.color.rgb = RGBColor(30, 41, 59)
        p.paragraph_format.space_after = Pt(2)
        p.paragraph_format.space_before = Pt(2)
        doc.add_paragraph() # spacer

    # --- COVER / HEADER ---
    add_title("دليل استخدام نظام إدارة المولدات والاشتراكات (GMS)")
    add_subtitle("دليل تشغيلي وإداري شامل للوحة التحكم والفوترة وكشف الفاقد وقراءات العدادات")

    add_callout(
        "لوحة تحكم المدير تعمل مباشرة من أي متصفح حديث عبر أجهزة الحاسوب أو الهواتف الذكية. "
        "تم تصميم النظام بدقة حسابية متناهية تضمن حفظ الحقوق المالية، ومنع أي تلاعب أو حذف، "
        "مع ترحيل كسور الشيكل تلقائياً ومطابقة كافة حركات الصندوق.",
        "رسالة النظام"
    )

    # --- SECTION 1 ---
    add_h1("1. الدخول إلى النظام وأمان الحساب")
    add_bullet(" يتم فتح لوحة التحكم من خلال الرابط الإلكتروني المعتمد للمنشأة عبر أي متصفح (Google Chrome, Safari, Edge).", "رابط الدخول:")
    add_bullet(" يتم إدخال اسم المستخدم وكلمة المرور المسلمة للإدارة.", "تسجيل الدخول:")
    add_bullet(" عند الدخول لأول مرة بكلمة مرور مؤقتة، يُلزمك النظام بتعيين كلمة مرور شخصية جديدة تتكون من 8 خانات على الأقل وتجمع بين الحروف والأرقام لضمان حماية بيانات المنشأة.", "تغيير كلمة المرور المؤقتة:")
    add_bullet(" حرصاً على أمان النظام، بعد 5 محاولات إدخال خاطئة لكلمة المرور، يتم قفل الحساب تلقائياً لمدة 15 دقيقة لمنع محاولات الاختراق والتخمين.", "قفل الحساب التلقائي:")
    add_bullet(" الموظفون الميدانيون لا يدخلون لوحة المدير، بل لديهم تطبيق خاص على أجهزة الهاتف المحمول (Android) مرتبط بكلمات مرور ورموز تفعيل مشفرة.", "صلاحيات الموظفين:")

    # --- SECTION 2 ---
    add_h1("2. لوحة القيادة والمتابعة التنفيذية (Executive Command Center)")
    add_p("بمجرد الدخول تظهر الشاشة الرئيسية المصممة لتزويد المدير بنظرة بانورامية حية عن سير العمل:")
    add_bullet(" بطاقة حية في أعلى الشاشة تعرض اسم الدورة الجارية وتاريخها وسعر الكيلوواط الحالي وزر فتح/إغلاق الدورة.", "شريط حالة الدورة الأسبوعية:")
    add_bullet(" أزرار وصول فوري للإجراءات الأكثر استخداماً (إضافة مشترك، مراجعة القراءات، تسجيل دفعة، كشف الفاقد).", "أزرار الإجراءات السريعة:")
    add_bullet(" إجمالي عدد المشتركين الفعّالين، رصيد المستحقات غير المحصلة، إجمالي التحصيلات النقدية، ونسبة إنجاز مهام القراءة الميدانية.", "مؤشرات الأداء الحيوية (KPIs):")
    add_bullet(" قائمة فحص ذكية توضح للمدير ما إذا كانت الدورة جاهزة للإغلاق المالي أم هناك مهام أو زيارات بانتظار الاعتماد.", "رادار التحقق من جاهزية الإغلاق:")

    # --- SECTION 3 ---
    add_h1("3. التجهيز الأولي وإعدادات المنشأة")
    add_p("عند بدء استخدام النظام للمرة الأولى، يُنصح باتباع الترتيب التالي:")
    add_bullet(" من قسم «الإدارة والتهيئة ← إعدادات النظام»، حدد اسم شبكة المولدات، أرقام هواتف التواصل، ونص التذييل الرسمي الذي يظهر في أسفل الفواتير وإيصالات القبض.", "بيانات الجهة والطباعة:")
    add_bullet(" من قسم «المشتركون والشبكة ← المولدات والمناطق»، أضف المولدات المغذية ثم قسّم كل مولد إلى مناطق جغرافية محددة. يمكنك تحديد «يوم القراءة المعتاد» لكل منطقة لتسهيل الجدولة التلقائية.", "المولدات والمناطق:")
    add_bullet(" من قسم «الإدارة والتهيئة ← الموظفون والحسابات»، أنشئ حساباً لكل موظف ميداني وامنحه صلاحية المناطق المسندة إليه.", "الموظفون الميدانيون:")
    add_bullet(" اضغط «رمز تفعيل هاتف» لإصدار رمز لمرة واحدة (صالح 24 ساعة) يربط هاتف الموظف بالنظام ويمنع الدخول من أجهزة غير مصرحة.", "تفعيل هواتف الموظفين:")

    # --- SECTION 4 ---
    add_h1("4. إدارة المشتركين والعدادات")
    add_h2("أ. الترقيم التسلسلي التلقائي (يبدأ من 0001)")
    add_p("يوفر النظام ميزة الترقيم التلقائي الذكي لاشتراكات المواطنين:")
    add_bullet("عند الضغط على زر «+ مشترك جديد»، يتم توليد رقم الاشتراك التالي تلقائياً بصيغة تسلسلية تبدأ من 0001 (مثل 0001، 0002، 0003...).")
    add_bullet("الحقل قابل للتعديل اليدوي في حال أرادت الإدارة إسناد رقم اشتراك استثنائي.")
    add_bullet("إذا تم استيراد مشتركون سابقون من إكسيل (مثلاً حتى الرقم 0250)، يستأنف النظام التسلسل التلقائي الذكي فوراً من الرقم التالي (0251).")

    add_h2("ب. إضافة مشترك يدوي والعداد والقراءة الافتتاحية")
    add_p("عند تسجيل مشترك جديد، يتم ملء البيانات الأساسية (الاسم، الهاتف، العنوان، المنطقة، وفترة القراءة بالأيام).")
    add_bullet("بيانات العداد: يتم إدخال رقم العداد ونوعه (رقمي أو ميكانيكي) وتاريخ تركيبه.")
    add_bullet("القراءة الافتتاحية (kWh): هي نقطة الصفر الحسابية للعداد، يدخلها المدير ولا تُنتج أي مطالبة مالية على المشترك، بل يُحسب استهلاك المشترك المستقبلي انطلاقاً منها.")

    add_h2("ج. الاستيراد الجماعي الذكي من Excel")
    add_p("إذا كانت بيانات المشتركين مسجلة مسبقاً في ملف Excel، يمكن استيرادها دفعة واحدة:")
    add_bullet("الدخول إلى «المشتركون والشبكة ← استيراد Excel».")
    add_bullet("رفع الملف؛ يقوم النظام آلياً باقتراح ربط الأعمدة (رقم الاشتراك، الاسم، الهاتف، المنطقة، رقم العداد، القراءة الافتتاحية).")
    add_bullet("الضغط على «معاينة وفحص»؛ يتحقق النظام من صحة البيانات وخلوها من الأخطاء أو التكرارات قبل حفظها.")
    add_bullet("الضغط على «تأكيد الاستيراد» لحفظ المشتركين وتثبيت قراءاتهم الافتتاحية بأمان.")

    # --- SECTION 5 ---
    add_h1("5. دورة الفوترة الأسبوعية ومهام القراءة الميدانية")
    add_bullet(" يتم فتح دورة جديدة من «المالية والفوترة ← الدورات والأسعار ← + دورة جديدة» (مثلاً من السبت إلى الجمعة). لا يُسمح بتداخل الدورات، وتوجد دورة مفتوحة واحدة فقط.", "فتح الدورة الأسبوعية:")
    add_bullet(" يتم تحديد سعر مبدئي استرشادي للكيلوواط، وتكون كافة الكشوف والأرقام قبل الإغلاق موسومة بأنها «تقديرية» حتى اعتماد السعر النهائي.", "تحديد السعر المبدئي:")
    add_bullet(" بالضغط على زر «توليد المهام المستحقة»، يقوم النظام آلياً بإنشاء مهام القراءة للمشتركين الذين حان موعد قراءتهم بحسب فتراتهم الزمنية المحددة، وتنزل المهام مباشرة على هواتف الموظفين.", "توليد مهام القراءة:")
    add_bullet(" يمكن للمدير تكليف موظف بمهمة قراءة طارئة، أو إعادة توزيع المهام بين الموظفين، أو إلغاء مهمة لسبب موثق.", "إدارة المهام والتكليف:")

    # --- SECTION 6 ---
    add_h1("6. مراجعة واعتماد قراءات العدادات (العمل اليومي الأهم)")
    add_p("يقوم الموظف الميداني بتصوير العداد وتوثيق القراءة من التطبيق (حتى بدون إنترنت). فور المزامنة، تظهر الزيارات في شاشة «مراجعة القراءات»:")
    add_bullet("الضغط على صورة العداد لتكبيرها، ومطابقة الرقم المكتوب في الصورة مع الرقم الذي أدخله الموظف.")
    add_bullet("مقارنة القراءة الحالية بالقراءة السابقة للتأكد من منطقية الاستهلاك وخلوه من الأخطاء.")
    add_bullet("الاعتماد أو التصحيح: في حال وجود خطأ في كتابة الرقم من الموظف، يمكن للمدير تصحيح القراءة استناداً إلى الصورة الواضحة مع تدوين سبب التصحيح، وتبقى القراءة الأصلية للموظف محفوظة في السجل للتدقيق.")
    add_bullet("طلب إعادة زيارة: إذا كانت الصورة غير واضحة أو العداد مغلقاً، يمكن بضغطة زر طلب إعادة الزيارة للموظف.")
    add_bullet("الاعتماد الجماعي: يمكن للمدير تحديد عدة قراءات سليمة واعتمادها دفعة واحدة لتوفير الوقت.")

    # --- SECTION 7 ---
    add_h1("7. كاشف الفاقد وسرقة التيار الكهربائي (Power Loss & Theft Detection)")
    add_p("ميزة متقدمة وحصرية لكشف أي هدر فني أو سرقة للتيار عبر المولدات:")
    add_bullet("الدخول إلى «المشتركون والشبكة ← كشف الفاقد والسرقة».")
    add_bullet("اختيار المولد والدورة المطلوبة.")
    add_bullet("إدخال قراءة العداد الرئيسي للمولد (الإنتاج الكلي بالكيلوواط).")
    add_bullet("يقوم النظام فوراً بجمع كافة استهلاكات المشتركين المعتمدة على هذا المولد ومقارنتها بالإنتاج الكلي.")
    add_bullet("يعرض النظام:")
    add_bullet("   • كمية الطاقة المفقودة بالكيلوواط (kWh).")
    add_bullet("   • نسبة الفاقد المئوية (%).")
    add_bullet("   • الخسارة المالية التقديرية بالعملة المحلية (شيكل).")
    add_bullet("   • مؤشر الخطر الذكي: (طبيعي أقل من 5% | تحذير متوسط 5-10% | حرج وخطر سرقة أعلى من 10%).")
    add_bullet("   • جدول تفصيلي لكافة المشتركين المرتبطين بالمولد مع استهلاك كل منهم لسهولة المتابعة والتفتيش.")

    # --- SECTION 8 ---
    add_h1("8. إغلاق الأسبوع وتثبيت السعر وترحيل كسر الشيكل")
    add_p("عند اكتمال اعتماد قراءات الأسبوع، يتم إغلاق الدورة المالية:")
    add_bullet("فحص خلو عوائق الإغلاق في شاشة الدورة.")
    add_bullet("الضغط على «تثبيت السعر النهائي وإغلاق الدورة» وإدخال السعر الرسمي الموحد للكيلوواط.")
    add_bullet("إعادة الاحتساب التلقائي: يُعاد احتساب استهلاك كافة المشتركين بالسعر النهائي وتصدر الكشوفات الرسمية فوراً.")
    add_bullet("ترحيل كسر الشيكل التلقائي: المبلغ المطلوب يُقرب دائماً للرقم الصحيح دون كسور، والكسور تُرحّل تلقائياً ككسر مستحق للدورة التالية (مثلاً: رصيد 35.60 شيكل يصبح المطلوب 35 شيكل، و 0.60 شيكل ترحل تلقائياً)؛ فلا يضيع شيكل واحد على الإدارة ولا على المشترك.")
    add_bullet("الطباعة الجماعية: إمكانية طباعة كافة الكشوفات الأسبوعية بملف PDF واحد أو طباعتها مفروزة حسب المنطقة.")

    # --- SECTION 9 ---
    add_h1("9. المراسلة الفورية عبر الواتساب (WhatsApp Direct Messaging)")
    add_p("أصبح بإمكان الإدارة إرسال الفواتير والإيصالات للمشتركين بلمسة واحدة:")
    add_bullet("يظهر زر «إرسال واتساب» بجانب كل كشف حساب أسبوعي أو إيصال قبض.")
    add_bullet("عند الضغط على الزر من الهاتف المحمول أو الكمبيوتر، يفتح تطبيق WhatsApp مباشرة محادثة المشترك برقم هاتفه المعتمد دولياً.")
    add_bullet("الرسالة تكون مجهزة ومكتوبة بصياغة مهنية وأنيقة تشمل:")
    add_bullet("   • اسم المشترك ورقم اشتراكه.")
    add_bullet("   • تفاصيل الدورة وقراءة العداد السابقة والحالية والاستهلاك.")
    add_bullet("   • المبلغ المطلوب دفعه بالضبط، ونص تذييل الشبكة وأرقام الطوارئ.")

    # --- SECTION 10 ---
    add_h1("10. التحصيلات المالية وإيصالات القبض والتسويات")
    add_bullet(" تسجيل الدفعة النقدية من صفحة المشترك أو من قائمة «المدفوعات»، مع تحديد المبلغ وطريقة الدفع والمرجع.", "تسجيل سندات القبض:")
    add_bullet(" فور حفظ الدفعة، يمكن الضغط على «إيصال PDF» لطباعة إيصال رسمي يحتوي على باركود وبصمة رقمية، أو الضغط على «إرسال واتساب» لتسليم المشترك الإيصال فوراً على هاتفه.", "طباعة وإرسال الإيصال:")
    add_bullet(" إذا حدث خطأ في تسجيل دفعة، لا يتم حذفها أبداً لحماية الصندوق، بل يتم الضغط على «إلغاء بقيد عكسي» مع تسجيل سبب الإلغاء في سجل التدقيق.", "إلغاء الدفعة بقيد عكسي:")
    add_bullet(" في حال منح خصم للمشترك أو تسجيل تسوية تعويضية، يتم إدخالها من دفتر حساب المشترك كـ «تسوية يدوية»، وتنعكس فوراً على رصيده.", "التسويات اليدوية:")

    # --- SECTION 11 ---
    add_h1("11. التقارير الإدارية وسجل التدقيق والنسخ الاحتياطي")
    add_bullet(" تتضمن تقارير الاستهلاك التفصيلي، كشوفات الديون والمستحقات، مقبوضات الصندوق، تقارير أداء الموظفين الميدانيين، وتصدير كافة الجداول بملفات Excel و PDF عربية منسقة وجاهزة للطباعة.", "التقارير الرسمية الشاملة:")
    add_bullet(" ميزة أمان فائقة تسجل أي عملية إضافة أو تعديل أو دخول في النظام بالوقت الدقيق واسم المستخدم، ولا يمكن لأحد تعديل هذا السجل إطلاقاً.", "سجل التدقيق (Audit Log):")
    add_bullet(" يقوم النظام بأخذ نسخة احتياطية يومية تلقائية لقاعدة البيانات وصور العدادات ويحتفظ بها لمدة 30 يوماً لضمان عدم فقدان أي بيانات تحت أي ظرف.", "النسخ الاحتياطي الآلي:")

    # --- SAVE ---
    doc.save(output_path)
    print(f"Manual created successfully at: {output_path}")

if __name__ == "__main__":
    out_dir = r"c:\Users\mozar\Desktop\VS\GMS_Claude_Code_Project"
    out_file = os.path.join(out_dir, "دليل_استخدام_نظام_إدارة_المولدات_GMS.docx")
    create_manual(out_file)
