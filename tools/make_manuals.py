#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成三个平台的操作手册 PDF（带真实截图）。

运行：.venv/Scripts/python.exe tools/make_manuals.py
输出：docs/文件共享中心-{PC版|安卓版|iOS版}操作手册.pdf
"""
import os
from PIL import Image as PILImage
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate, Frame, Image, KeepTogether, PageBreak, PageTemplate,
    Paragraph, Spacer, Table, TableStyle,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOCS = os.path.join(ROOT, 'docs')
SHOTS = os.path.join(DOCS, 'screenshots')  # 截图素材随仓库提交，保证手册可重新生成
TEMP = os.path.join(ROOT, 'temp')          # 临时裁剪图输出（已 gitignore）
FONT_PATH = 'C:/Windows/Fonts/simhei.ttf'

pdfmetrics.registerFont(TTFont('SimHei', FONT_PATH))
PRIMARY = colors.HexColor('#6C5CE7')
SOFT = colors.HexColor('#F5F6FA')
LINE = colors.HexColor('#ECEEF4')
TEXT = colors.HexColor('#1F2233')
MUTED = colors.HexColor('#6B7085')

ss = getSampleStyleSheet()
S = {
    'title': ParagraphStyle('title', fontName='SimHei', fontSize=26, leading=34,
                            textColor=PRIMARY, alignment=TA_CENTER, spaceAfter=10),
    'subtitle': ParagraphStyle('subtitle', fontName='SimHei', fontSize=15, leading=22,
                               textColor=MUTED, alignment=TA_CENTER, spaceAfter=8),
    'cover_meta': ParagraphStyle('cover_meta', fontName='SimHei', fontSize=10, leading=18,
                                 textColor=MUTED, alignment=TA_CENTER),
    'h1': ParagraphStyle('h1', fontName='SimHei', fontSize=15, leading=22,
                         textColor=PRIMARY, spaceBefore=14, spaceAfter=8),
    'h2': ParagraphStyle('h2', fontName='SimHei', fontSize=11.5, leading=18,
                         textColor=TEXT, spaceBefore=10, spaceAfter=5),
    'body': ParagraphStyle('body', fontName='SimHei', fontSize=9.8, leading=16.5,
                           textColor=TEXT, spaceAfter=6, alignment=TA_LEFT),
    'bullet': ParagraphStyle('bullet', fontName='SimHei', fontSize=9.8, leading=16,
                             textColor=TEXT, leftIndent=14, bulletIndent=4, spaceAfter=3),
    'note': ParagraphStyle('note', fontName='SimHei', fontSize=9, leading=14.5,
                           textColor=MUTED, backColor=SOFT, borderPadding=8,
                           leftIndent=4, rightIndent=4, spaceBefore=4, spaceAfter=8),
    'caption': ParagraphStyle('caption', fontName='SimHei', fontSize=8.2, leading=12,
                              textColor=MUTED, alignment=TA_CENTER, spaceBefore=4, spaceAfter=10),
    'code': ParagraphStyle('code', fontName='Courier', fontSize=8.8, leading=14,
                           textColor=colors.HexColor('#5A4BD1'), backColor=SOFT,
                           borderPadding=7, spaceBefore=4, spaceAfter=8),
}


def para(text, style='body'):
    return Paragraph(text, S[style])


def bullets(items):
    # 用 reportlab 的 bulletText 渲染圆点（默认西文字体），避免中文字体缺 • 字形
    return [Paragraph(t, S['bullet'], bulletText='•') for t in items]


def section(title):
    return [Spacer(1, 4), para(title, 'h1')]


def sub(title):
    return para(title, 'h2')


def note(text):
    return para('提示：' + text, 'note')


def table(headers, rows, widths):
    data = [[para(h, 'body') for h in headers]]
    for row in rows:
        data.append([para(str(c), 'body') for c in row])
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, 0), PRIMARY),
        ('TEXTCOLOR', (0, 0), (-1, 0), colors.white),
        ('FONTNAME', (0, 0), (-1, -1), 'SimHei'),
        ('FONTSIZE', (0, 0), (-1, -1), 9),
        ('GRID', (0, 0), (-1, -1), 0.4, LINE),
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('LEFTPADDING', (0, 0), (-1, -1), 7),
        ('RIGHTPADDING', (0, 0), (-1, -1), 7),
        ('TOPPADDING', (0, 0), (-1, -1), 5),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 5),
        ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, colors.HexColor('#F9F8FF')]),
        # 表头用白色文字（覆盖上面的 TEXT）
        ('TEXTCOLOR', (0, 0), (-1, 0), colors.white),
    ]))
    # 表头段落颜色单独设置（Paragraph 自带样式优先级高）
    for i in range(len(headers)):
        data[0][i] = Paragraph(f'<font color="#ffffff">{headers[i]}</font>', S['body'])
    return t


def figure(name, caption, max_w=455, max_h=430, crop_top=None):
    """插入截图；crop_top 为保留上半部分的比例（用于手机长图）。"""
    path = os.path.join(SHOTS, name)
    if not os.path.exists(path):
        return para(f'［截图缺失：{name}，请检查 docs/screenshots/］', 'note')
    im = PILImage.open(path)
    w, h = im.size
    if crop_top:
        out = os.path.join(TEMP, 'crop_' + name)
        im.crop((0, 0, w, int(h * crop_top))).save(out)
        path = out
        h = int(h * crop_top)
    scale = min(max_w / w, max_h / h, 1.0)
    iw, ih = w * scale, h * scale
    return KeepTogether([
        Image(path, width=iw, height=ih),
        para('图：' + caption, 'caption'),
    ])


def cover(title, subtitle, badge, extra=''):
    return [
        Spacer(1, 62 * mm),
        para('文件共享中心', 'title'),
        para(subtitle, 'subtitle'),
        Spacer(1, 6 * mm),
        table(['适用平台'], [[badge]], [120 * mm]),
        Spacer(1, 10 * mm),
        para(extra, 'cover_meta'),
        Spacer(1, 24 * mm),
        para('局域网文件共享 · 实时群聊 · 多端互通', 'cover_meta'),
        PageBreak(),
    ]


def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont('SimHei', 8)
    canvas.setFillColor(MUTED)
    canvas.drawString(18 * mm, 12 * mm, '文件共享中心 · 操作手册')
    canvas.drawRightString(A4[0] - 18 * mm, 12 * mm, f'第 {doc.page} 页')
    canvas.setStrokeColor(LINE)
    canvas.line(18 * mm, 15 * mm, A4[0] - 18 * mm, 15 * mm)
    canvas.restoreState()


def build(filename, title, subtitle, badge, story, extra=''):
    os.makedirs(DOCS, exist_ok=True)
    path = os.path.join(DOCS, filename)
    doc = BaseDocTemplate(path, pagesize=A4,
                          leftMargin=18 * mm, rightMargin=18 * mm,
                          topMargin=16 * mm, bottomMargin=20 * mm,
                          title=title, author='File Share Team')
    frame = Frame(doc.leftMargin, doc.bottomMargin, doc.width, doc.height, id='main')
    doc.addPageTemplates([PageTemplate(id='all', frames=[frame], onPage=footer)])
    doc.build(cover(title, subtitle, badge, extra) + story)
    print(f'{filename}: {os.path.getsize(path)//1024} KB, 已生成')
    return path


# ================================================================ PC 版（Rust）
def build_pc():
    st = []
    st += section('一、软件简介')
    st += [para('PC 版是文件共享中心的电脑端主机程序，采用 Rust 编写，编译后为<strong>单个 exe 文件（约 5.3 MB）</strong>。'
                '移动端界面已编译进程序，运行时不需要安装 Python、Node、.NET 或任何运行库。')]
    st += [para('它同时具备两种身份：启动后自己是「主机」，持有共享文件夹；也可以在网页的「连接」页填入其他手机或电脑的地址，'
                '变成「客户端」加入对方的共享空间。')]
    st += [note('双击 exe 打开的是图形启动器窗口，不会弹黑色命令行窗口。')]

    st += section('二、安装与启动')
    st += [sub('1. 运行条件'), para('Windows 10 / 11 64 位；无需额外依赖。')]
    st += [sub('2. 启动'), para('双击 <strong>file-share-pc.exe</strong>，或双击同目录的 <strong>start.bat</strong>。首次弹出防火墙提示时，勾选「专用网络」并允许访问。')]
    st += [figure('launcher-window.png', '图形启动器：状态、地址、统计与快捷按钮')]
    st += [sub('3. 启动器窗口说明')]
    st += [table(['区域', '作用'], [
        ['运行状态', '绿点表示服务正常；端口被占用时变红并显示原因'],
        ['本机访问', '仅本机可用，用于快速测试'],
        ['局域网访问', '手机与其他设备用这个地址，同一 WiFi 即可打开'],
        ['共享项目 / 在线设备', '每 2 秒自动刷新一次'],
        ['复制邀请链接', '复制带 ?host= 参数的链接，对方打开即自动连上本机'],
        ['打开网页 / 共享文件夹', '分别在浏览器和系统资源管理器中打开'],
    ], [42 * mm, 108 * mm])]
    st += [sub('4. 命令行参数（可选）')]
    st += [para('file-share-pc.exe                           默认 5000 端口，共享目录 ./download')]
    st += [para('file-share-pc.exe --port 5001              端口被占用时换一个')]
    st += [para('file-share-pc.exe --dir D:\\共享文件夹      指定共享目录')]
    st += [para('file-share-pc.exe --no-gui                 纯后台模式，不显示窗口')]
    st += [para('file-share-pc.exe --help                   查看帮助')]
    st += [note('关闭图形窗口即停止服务；--no-gui 模式下需在任务管理器结束进程来停止。')]

    st += section('三、网页端界面导览')
    st += [para('在浏览器打开启动器显示的「局域网访问」地址即可进入。PC 宽屏下页面会自动展开为多列布局，不再是一条窄栏。')]
    st += [figure('rwd-pc.png', 'PC 宽屏：上传区三栏、文件卡片多列、整体居中限宽')]
    st += [table(['区域', '功能'], [
        ['顶部紫色栏', '当前主机地址与连接状态；点击状态可跳到「连接」页'],
        ['上传卡片', '选择文件（可多选）、选择文件夹、拍照；带进度条'],
        ['文件列表', '卡片流展示，支持搜索、下载、删除、在线预览'],
        ['底部导航', '文件 / 群聊 / 连接 三个标签'],
    ], [40 * mm, 110 * mm])]

    st += section('四、文件操作')
    st += bullets([
        '<strong>上传文件</strong>：点「选择文件」可一次选多个；上传完成后其他在线设备会自动刷新列表。',
        '<strong>上传文件夹</strong>：点「选择文件夹」保留目录结构；若浏览器不支持目录选择，用「选择文件」多选代替。',
        '<strong>下载</strong>：点文件卡片的 ↓ 按钮；文件夹会自动打包成 ZIP。',
        '<strong>批量操作</strong>：点「管理」进入多选，可全选、打包下载、批量删除。',
        '<strong>预览</strong>：图片、视频、音频、PDF、TXT 直接在弹层打开。',
        '<strong>删除</strong>：删除前会二次确认，删除后同步通知其他设备。',
    ])

    st += section('五、实时群聊')
    st += [para('切到「群聊」标签即可发送消息。所有连接到同一主机的设备都在同一个群里。支持昵称、在线人数、'
                '加入/离开系统提示、文件分享通知，新加入者能看到最近 100 条历史消息。断线后会自动重连。')]

    st += section('六、连接其他主机')
    st += [para('切到「连接」页，四种方式任选：')]
    st += [table(['方式', '操作'], [
        ['扫码连接', '点「扫码连接」→ 拍照或从相册选对方主机「连接」页的二维码'],
        ['剪贴板', '复制对方地址后点「剪贴板」，或直接在输入框粘贴，会自动识别并连接'],
        ['附近主机', '点「附近主机」，自动探测同网段设备；端口框默认 5000/5001/8000/8080，可自行增删后「重新搜索」'],
        ['手动输入', '输入 http://IP:端口，也支持只填 IP 或 IP:端口'],
    ], [32 * mm, 118 * mm])]
    st += [figure('connect-qr.png', '「连接」页：四种加入方式、邀请二维码与端口设置')]
    st += [note('如果扫不到非 5000 端口的主机，展开搜索结果里的「端口」框，把对方端口加进去再点「重新搜索」。')]

    st += section('七、多设备适配')
    st += [para('同一套页面会按屏幕宽度自动切换布局：')]
    st += [figure('rwd-ipad-portrait.png', 'iPad 竖屏（768px）：上传区横向三栏、文件列表两列')]
    st += [figure('rwd-ipad-landscape.png', 'iPad 横屏（1024px）：连接页两列、二维码放大')]
    st += [table(['设备', '宽度', '布局'], [
        ['手机', '<600px', '单列、大按钮'],
        ['大屏手机', '≥600px', '适度加宽'],
        ['iPad 竖屏', '≥768px', '上传三栏、文件两列'],
        ['iPad 横屏', '≥1024px', '连接页两列'],
        ['PC', '≥1280px', '文件多列、居中限宽'],
        ['超宽屏', '≥1600px', '固定 1400px 不拉伸'],
    ], [30 * mm, 26 * mm, 94 * mm])]
    st += [para('手机横屏矮屏会自动压缩顶部与底部工具栏；鼠标悬停动效只在有鼠标的设备生效，触屏点击不会留下残影。')]

    st += section('八、常见问题')
    st += [table(['问题', '处理'], [
        ['手机打不开地址', '确认同一 WiFi；Windows 防火墙放行「专用网络」；路由器不要开 AP 隔离'],
        ['端口被占用', '启动时加 --port 5001，二维码与链接会自动用新端口'],
        ['图形窗口显示红色错误', '窗口里会写明原因，常见为端口绑定失败'],
        ['扫描不到主机', '在搜索结果的端口框加入对方端口；或直接扫码 / 手动输入'],
        ['文件存在哪里', '默认在 exe 同级的 download 目录，可用 --dir 指定'],
        ['想后台常驻', '使用 --no-gui 启动，或保持启动器窗口开启'],
    ], [48 * mm, 102 * mm])]

    st += section('九、安全提醒')
    st += bullets([
        '本程序<strong>没有登录鉴权</strong>，仅限可信局域网使用，不要把端口映射到公网。',
        '上传与删除路径都做了穿越校验，拒绝 ../ 与绝对路径。',
        '共享目录内的文件不会自动上传云端，仅保存在本机磁盘。',
        'ZIP 打包未启用 Zip64，单个文件超过约 4GB 会被跳过。',
    ])
    return build('文件共享中心-PC版操作手册.pdf', '文件共享中心 PC 版（Rust）操作手册',
                 '单文件 exe · 图形启动器 · 无黑窗', 'Windows 10 / 11 64 位', st,
                 '版本 1.0　|　生成日期 2026-11-10')


# ================================================================ 安卓版
def build_android():
    st = []
    st += section('一、软件简介')
    st += [para('安卓版是一个可安装的 APK。App 内部直接运行 HTTP + WebSocket 服务，因此<strong>既能当客户端，也能当主机</strong>。'
                '安装后手机自己就是一个共享中心，其他手机和电脑都能连进来。')]
    st += [note('下面标注「App 内页面」的截图，是 App 内嵌界面的实际渲染效果，与浏览器访问同一地址时一致；非真机外壳实拍。')]

    st += section('二、安装')
    st += [sub('1. 安装 APK')] + bullets([
        '把 <strong>文件共享中心.apk</strong> 传到手机（数据线、微信、网盘均可）。',
        '点开安装；系统提示「未知来源」时，按提示允许当前安装来源。',
        '或在电脑执行：adb install -r 文件共享中心.apk',
        '要求 Android 6.0（API 23）及以上。安装包为自签名，约 260 KB。',
    ])
    st += [sub('2. 权限说明'), table(['权限', '为什么需要'], [
        ['通知', '前台服务必须显示常驻通知，否则系统可能杀掉共享服务'],
        ['文件选择', '从相册或文件管理器挑选要上传的文件'],
        ['局域网 / 互联网', '提供 HTTP 服务并访问其他主机'],
    ], [38 * mm, 112 * mm])]

    st += section('三、启动与当主机')
    st += [para('打开 App 即自动启动共享服务，顶部状态栏显示服务地址，通知栏出现常驻提示。切到「连接」页可以看到本机的邀请二维码。')]
    st += [figure('rwd-phone.png', 'App 内页面：文件标签（上传区、文件卡片与底部导航）')]
    st += [sub('邀请别人加入本机')] + bullets([
        '在「连接」页向下找到邀请二维码，让对方连同一 WiFi 后扫码；或点「复制链接」发到微信群。',
        '链接形如 http://192.168.x.x:5000/?host=... ，对方点开会自动连上你的手机，无需手动填 IP。',
        '也可点「系统分享」直接调用系统分享面板。',
    ])
    st += [figure('connect-qr.png', 'App 内页面：邀请二维码与复制 / 分享按钮')]

    st += section('四、当客户端：连接其他主机')
    st += [para('在「连接」页任选一种方式加入别人的共享空间：')]
    st += [table(['方式', '操作'], [
        ['扫码连接', 'App 内走「拍照 / 相册选图识别」；对准对方主机二维码即可'],
        ['剪贴板', '复制对方链接后点「剪贴板」，或在输入框粘贴，自动识别并连接'],
        ['附近主机', '自动扫同网段 1~254 的 5000/5001/8000/8080 端口，可自定义端口后重新搜索'],
        ['手动输入', '填 http://IP:端口，也支持只填 IP 或 IP:端口'],
    ], [30 * mm, 120 * mm])]
    st += [figure('connect-v2.png', 'App 内页面：四种加入方式与端口设置', crop_top=0.56)]

    st += section('五、文件与群聊')
    st += bullets([
        '<strong>上传</strong>：文件页「选择文件」可多选；「拍照」直接调用相机；带上传进度。',
        '<strong>下载</strong>：点卡片 ↓ 按钮，交给系统下载管理器，文件落在「下载」目录，通知栏可查看。',
        '<strong>预览</strong>：图片、视频、音频、PDF、TXT 直接打开；文件夹下载时自动打包 ZIP。',
        '<strong>管理</strong>：「管理」进入多选，全选 / 打包下载 / 批量删除。',
        '<strong>群聊</strong>：实时气泡消息、昵称、在线人数、加入离开通知、文件分享提示、断线自动重连。',
    ])

    st += section('六、后台保活与限制')
    st += [table(['事项', '说明'], [
        ['前台服务', '保持通知栏常驻；部分国产 ROM 需在「电池优化 / 自启动 / 后台锁定」里允许本 App'],
        ['Android 15 限制', 'dataSync 类型前台服务有「24 小时内累计 6 小时」上限，超时后系统会停止，重新打开 App 即可恢复'],
        ['文件夹上传', 'WebView 不支持目录选择，请用「选择文件」多选代替；服务端本身支持文件夹上传'],
        ['扫码方式', 'App 内直接用拍照 / 相册识别，不申请摄像头实时权限'],
        ['共享目录', '/Android/data/com.fileshare.phone/files/shared ，卸载 App 会一并删除，重要文件请及时导出'],
    ], [36 * mm, 114 * mm])]

    st += section('七、常见问题')
    st += [table(['问题', '处理'], [
        ['其他手机连不上', '同一 WiFi；电脑防火墙放行；路由器关闭 AP 隔离'],
        ['顶部被信号栏遮挡', '已适配：WebView 通过系统 WindowInsets 避开状态栏与导航栏'],
        ['扫描不到主机', '在搜索结果的端口框加入对方端口；或直接扫码 / 手动输入'],
        ['服务突然中断', '检查是否锁屏过久或被系统清理，重新打开 App'],
        ['下载找不到文件', '到系统「下载」目录查看，或看通知栏下载完成提示'],
    ], [42 * mm, 108 * mm])]
    return build('文件共享中心-安卓版操作手册.pdf', '文件共享中心 安卓版操作手册',
                 '手机既是客户端，也是服务端', 'Android 6.0 及以上', st,
                 '版本 1.0　|　生成日期 2026-11-10')


# ================================================================ iOS 版
def build_ios():
    st = []
    st += section('一、交付内容与限制（务必先读）')
    st += [para('iOS 版交付的是<strong>完整 Xcode 工程源码</strong>（<font face="Courier">ios/</font> 目录），'
                '而不是现成的 IPA。因为 Apple 的编译、签名与导出只能在 macOS + Xcode 上完成，'
                '并且必须用你自己的 Apple ID 签名后才能安装到 iPhone。')]
    st += [para('同时受 iOS 系统限制：<strong>App 只能在前台运行期间当主机</strong>。切到后台或锁屏后系统会挂起网络 socket，'
                '其他设备就访问不到这台 iPhone 了。iPhone 当客户端（连接 PC / 安卓主机）则完全正常。')]
    st += [note('下面的界面截图来自同一套响应式网页在手机 / 平板尺寸下的渲染，用于说明操作位置；iOS 工程未在 macOS 上编译验证，界面以实际打包结果为准。')]

    st += section('二、在 Mac 上导出 IPA')
    st += [sub('方式 A：一键脚本（推荐）'), para('在 Mac 终端执行：')]
    st += [para('cd ios<br/>TEAM_ID=ABCDE12345 bash build-ipa.sh', 'code')]
    st += [para('脚本会自动 archive、把 Team ID 注入导出配置、再导出 IPA，产物在 <font face="Courier">ios/build/ipa/FileSharePhone.ipa</font>。'
                'TEAM_ID 在 developer.apple.com → Membership 查看。')]
    st += [sub('方式 B：Xcode 图形界面')] + bullets([
        '双击 <font face="Courier">ios/FileSharePhone.xcodeproj</font> 打开工程。',
        '选中 target → Signing & Capabilities → 勾选 Automatically manage signing → Team 选你的 Apple ID。',
        'Bundle ID 若冲突，改成唯一值（如 com.你的名字.fileshare）。',
        '数据线连接 iPhone，运行目标选这台真机，先点 ▶ 跑一次以登记设备。',
        '菜单 Product → Archive → Distribute App → 选 Development 或 Ad Hoc → 一路下一步导出 IPA。',
    ])
    st += [table(['账号类型', '签名有效期', '说明'], [
        ['免费 Apple ID', '7 天', '到期后 App 打不开，需重新签名安装'],
        ['Apple Developer Program', '1 年', 'Ad Hoc 最多登记 100 台设备，或走 TestFlight'],
    ], [46 * mm, 28 * mm, 76 * mm])]

    st += section('三、安装到 iPhone')
    st += bullets([
        'Xcode → Window → Devices and Simulators → 选中设备 → 点「+」选择 IPA。',
        '或把 IPA 拖进 Apple Configurator / Finder（iOS 17+）安装。',
        '首次启动会弹「本地网络」权限，<strong>必须允许</strong>，否则其他设备连不上。',
        '到「设置 → 通用 → VPN 与设备管理」信任你的开发者证书。',
    ])

    st += section('四、当客户端：连接其他主机')
    st += [para('打开 App 后切到「连接」页，四种方式任选：')]
    st += [table(['方式', '操作'], [
        ['扫码连接', '局域网 HTTP 下走「拍照 / 相册选图识别」；HTTPS 或安全上下文可用实时摄像头'],
        ['剪贴板', '复制对方地址后点「剪贴板」，或在输入框粘贴，自动识别并连接'],
        ['附近主机', '自动扫同网段 1~254 的 5000/5001/8000/8080 端口，可自定义端口'],
        ['手动输入', '填 http://IP:端口，也支持只填 IP 或 IP:端口'],
    ], [30 * mm, 120 * mm])]
    st += [figure('rwd-phone.png', '手机尺寸：App 内文件页布局', crop_top=0.72)]
    st += [figure('connect-qr.png', '手机尺寸：连接页的四种加入方式与邀请二维码')]

    st += section('五、文件与群聊')
    st += bullets([
        '<strong>上传</strong>：页面「选择文件」可多选；顶部「上传」按钮调用系统文件选择器（UIDocumentPicker），可多选文件。',
        '<strong>下载</strong>：下载链接会被拦截，用系统下载流程保存到 App 的 Documents/Downloads，再弹分享面板，可存到「文件」App。',
        '<strong>预览 / 删除 / 批量</strong>：图片、视频、PDF 可预览；「管理」进入多选，支持打包下载与批量删除。',
        '<strong>群聊</strong>：实时气泡消息、昵称、在线人数、分享通知、100 条历史、断线重连。',
    ])

    st += section('六、当主机的正确用法')
    st += [para('iPhone 当主机时<strong>必须保持 App 在前台</strong>。适合临时分享，例如会议现场传文件。'
                '需要长时间稳定共享时，请用 PC 版（Rust / Python）或安卓 App 当主机，iPhone 连进去即可。')]
    st += [table(['限制', '说明'], [
        ['后台', '切后台后约几十秒系统会挂起 socket，服务不可用'],
        ['文件夹上传', 'WKWebView 不支持 webkitdirectory，用「选择文件」多选代替'],
        ['启动图', '工程用空 UILaunchScreen，Archive 可能提示缺少启动图（警告，不影响导出）'],
        ['HTTPS', '全部明文 HTTP（ATS 已放行），仅限可信局域网'],
    ], [34 * mm, 116 * mm])]

    st += section('七、平板（iPad）适配')
    st += [figure('rwd-ipad-portrait.png', 'iPad 竖屏：上传区横向三栏、文件列表两列')]
    st += [figure('rwd-ipad-landscape.png', 'iPad 横屏：连接页两列、二维码放大')]
    st += [para('iPad 上布局会自动展开，利用屏幕宽度显示更多文件卡片，操作逻辑与手机一致。')]

    st += section('八、常见问题')
    st += [table(['问题', '处理'], [
        ['Archive 报错', '多为签名或 Xcode 版本差异，按报错行局部调整；业务逻辑无需改动'],
        ['App 装不上', '确认设备已在 Developer 后台登记、证书已信任；免费账号 7 天后需重装'],
        ['其他设备连不上', '确认同一 WiFi、已允许「本地网络」权限、App 仍在前台'],
        ['下载的文件找不到', '在「文件」App 里查找，或下载后通过系统分享面板选择保存位置'],
        ['切后台后服务停了', 'iOS 系统限制，无法长期绕过；请保持 App 在前台或改用 PC / 安卓当主机'],
    ], [42 * mm, 108 * mm])]
    return build('文件共享中心-iOS版操作手册.pdf', '文件共享中心 iOS 版操作手册',
                 'Xcode 工程 · 签名打包 · 前台主机', 'iOS 15.0 及以上 / macOS 编译', st,
                 '版本 1.0　|　生成日期 2026-11-10')


if __name__ == '__main__':
    os.makedirs(DOCS, exist_ok=True)
    os.makedirs(TEMP, exist_ok=True)
    build_pc()
    build_android()
    build_ios()
    print('三份操作手册已生成：', DOCS)
