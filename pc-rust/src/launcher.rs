//! 图形启动器：显示服务状态与访问地址，替代黑色控制台窗口。

use crate::WsHub;
use eframe::egui;
use egui::{Color32, FontData, FontDefinitions, FontFamily, RichText, Vec2};
use std::path::PathBuf;
use std::sync::mpsc::Receiver;
use std::sync::Arc;
use std::time::{Duration, Instant};

const PURPLE: Color32 = Color32::from_rgb(108, 92, 231);
const GREEN: Color32 = Color32::from_rgb(37, 190, 121);
const RED: Color32 = Color32::from_rgb(229, 72, 77);
const GRAY: Color32 = Color32::from_rgb(107, 112, 133);
const SOFT: Color32 = Color32::from_rgb(245, 246, 250);

pub fn run(port: u16, ip: String, dir: PathBuf, hub: Arc<WsHub>, rx: Receiver<Result<(), String>>) {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([520.0, 432.0])
            .with_min_inner_size([430.0, 380.0])
            .with_resizable(true),
        ..Default::default()
    };
    eframe::run_native(
        "文件共享中心",
        options,
        Box::new(move |cc| {
            install_chinese_font(cc);
            Ok(Box::new(LauncherApp::new(port, ip, dir, hub, rx)))
        }),
    )
    .expect("图形界面启动失败");
}

fn install_chinese_font(cc: &eframe::CreationContext<'_>) {
    let mut fonts = FontDefinitions::default();
    // 优先黑体（单文件 TTF，egui 可直接光栅化），再回退到其他系统中文字体
    let candidates = [
        "C:/Windows/Fonts/simhei.ttf",
        "C:/Windows/Fonts/Deng.ttf",
        "/System/Library/Fonts/PingFang.ttc",
        "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc",
    ];
    for path in candidates.iter() {
        if let Ok(bytes) = std::fs::read(path) {
            fonts.font_data.insert("cjk".into(), FontData::from_owned(bytes));
            fonts
                .families
                .entry(FontFamily::Proportional)
                .or_default()
                .insert(0, "cjk".into());
            fonts
                .families
                .entry(FontFamily::Monospace)
                .or_default()
                .insert(0, "cjk".into());
            break;
        }
    }
    cc.egui_ctx.set_fonts(fonts);

    let mut style = (*cc.egui_ctx.style()).clone();
    style.visuals.selection.bg_fill = PURPLE;
    style.visuals.widgets.active.bg_fill = PURPLE;
    style.visuals.widgets.hovered.bg_fill = Color32::from_rgb(239, 236, 255);
    style.visuals.widgets.hovered.fg_stroke.color = PURPLE;
    cc.egui_ctx.set_style(style);
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

struct LauncherApp {
    port: u16,
    ip: String,
    dir: PathBuf,
    hub: Arc<WsHub>,
    status_rx: Receiver<Result<(), String>>,
    running: bool,
    error: Option<String>,
    online: usize,
    files: usize,
    last_poll: Instant,
    toast: Option<String>,
}

impl LauncherApp {
    fn new(port: u16, ip: String, dir: PathBuf, hub: Arc<WsHub>, rx: Receiver<Result<(), String>>) -> Self {
        Self {
            port,
            ip,
            dir,
            hub,
            status_rx: rx,
            running: true,
            error: None,
            online: 0,
            files: 0,
            last_poll: Instant::now(),
            toast: None,
        }
    }

    fn local_addr(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }
    fn lan_addr(&self) -> String {
        format!("http://{}:{}", self.ip, self.port)
    }
    fn share_url(&self) -> String {
        let a = self.lan_addr();
        format!("{}/?host={}", a, percent_encode(&a))
    }
}

impl eframe::App for LauncherApp {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // 服务线程可能已经报告端口绑定结果
        if let Ok(result) = self.status_rx.try_recv() {
            match result {
                Ok(_) => {
                    self.running = true;
                    self.error = None;
                }
                Err(e) => {
                    self.running = false;
                    self.error = Some(e);
                }
            }
        }

        if self.last_poll.elapsed() >= Duration::from_secs(2) {
            self.last_poll = Instant::now();
            self.online = self.hub.try_online();
            self.files = std::fs::read_dir(&self.dir).map(|r| r.count()).unwrap_or(0);
        }
        if self.toast.is_some() {
            ctx.request_repaint_after(Duration::from_secs(2));
        }

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.add_space(12.0);
            ui.vertical_centered(|ui| {
                ui.label(RichText::new("文件共享中心").size(21.0).strong().color(PURPLE));
                ui.label(RichText::new("PC 端 · 局域网文件共享与群聊").size(11.5).color(GRAY));
            });

            ui.add_space(14.0);
            egui::Frame::none()
                .fill(SOFT)
                .rounding(12.0)
                .inner_margin(egui::Margin::same(14.0))
                .show(ui, |ui| {
                    ui.horizontal(|ui| {
                        let (rect, _) =
                            ui.allocate_exact_size(Vec2::splat(12.0), egui::Sense::hover());
                        ui.painter()
                            .circle_filled(rect.center(), 5.5, if self.running { GREEN } else { RED });
                        ui.label(
                            RichText::new(if self.running { "服务运行中" } else { "服务未启动" })
                                .strong()
                                .size(14.0),
                        );
                    });

                    if let Some(err) = &self.error {
                        ui.add_space(6.0);
                        ui.colored_label(RED, format!("错误：{}", err));
                    }

                    ui.add_space(10.0);
                    ui.label(RichText::new("本机访问").size(11.0).color(GRAY));
                    ui.monospace(RichText::new(self.local_addr()).size(14.0));

                    ui.add_space(6.0);
                    ui.label(RichText::new("手机 / 其他设备访问（同一 WiFi）").size(11.0).color(GRAY));
                    ui.monospace(RichText::new(self.lan_addr()).size(15.0).strong().color(PURPLE));

                    ui.add_space(10.0);
                    ui.separator();
                    ui.horizontal(|ui| {
                        ui.label(format!("共享项目 {}", self.files));
                        ui.label("·");
                        ui.label(format!("在线设备 {}", self.online));
                    });
                });

            ui.add_space(12.0);
            ui.horizontal(|ui| {
                if ui.button("复制邀请链接").clicked() {
                    let url = self.share_url();
                    ui.ctx().output_mut(|o| o.copied_text = url);
                    self.toast = Some("链接已复制，发给朋友即可加入".to_string());
                }
                if ui.button("打开网页").clicked() {
                    let _ = std::process::Command::new("explorer")
                        .arg(self.lan_addr())
                        .spawn();
                }
                if ui.button("共享文件夹").clicked() {
                    let _ = std::process::Command::new("explorer").arg(&self.dir).spawn();
                }
            });

            ui.add_space(10.0);
            if let Some(msg) = &self.toast {
                ui.colored_label(GREEN, msg);
            } else {
                ui.label(RichText::new("保持本窗口开启即可持续共享；关闭窗口将停止服务。")
                    .size(11.0)
                    .color(GRAY));
            }

            ui.add_space(8.0);
            ui.separator();
            ui.horizontal_wrapped(|ui| {
                ui.label(RichText::new(format!("共享目录：{}", self.dir.display()))
                    .size(10.5)
                    .color(GRAY));
            });
            ui.horizontal(|ui| {
                ui.label(RichText::new("v1.0 · Rust 版").size(10.5).color(GRAY));
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    if ui.small_button("退出").clicked() {
                        std::process::exit(0);
                    }
                });
            });
        });
    }
}
