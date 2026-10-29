//! Overlay painting: `tiny-skia` shapes and text shaped by `rustybuzz`.
//! Everything is laid out in logical pixels and scaled at the last step.
//! Noto Sans Thai has no Latin letters, so Thai runs use it and the rest
//! (Latin, digits, spaces, punctuation) use Noto Sans.

use std::f32::consts::TAU;

use rustybuzz::{Face, UnicodeBuffer, ttf_parser};
use tiny_skia::{Color, FillRule, Paint, Path, PathBuilder, PixmapMut, Stroke, Transform};

/// Surface size in logical pixels. Fixed so a view change never needs a resize;
/// the pill is drawn centred and the rest stays transparent (and click-through).
pub const W: u32 = 640;
pub const H: u32 = 64;
/// Height of the pill itself.
const PILL_H: f32 = 44.0;
const TEXT_PX: f32 = 15.0;
pub const BARS: usize = 27;
const BAR_W: f32 = 3.0;
const BAR_GAP: f32 = 3.0;

#[cfg(unix)]
const THAI_FONT: &str = "/usr/share/fonts/noto/NotoSansThai-Medium.ttf";
#[cfg(unix)]
const LATIN_FONT: &str = "/usr/share/fonts/noto/NotoSans-Medium.ttf";
#[cfg(unix)]
const COLORS: &str = ".local/state/omarchy/current/theme/colors.toml";

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Kind {
    Info,
    Error,
}

pub enum View<'a> {
    Recording { bars: &'a [f32] },
    Processing { phase: f32 },
    Notice { kind: Kind, text: &'a str },
}

pub struct Palette {
    pub bg: Color,
    pub border: Color,
    pub accent: Color,
    pub text: Color,
    pub warn: Color,
    pub err: Color,
}

fn hex(s: &str) -> Option<Color> {
    let s = s.strip_prefix('#')?;
    if s.len() != 6 {
        return None;
    }
    let v = u32::from_str_radix(s, 16).ok()?;
    Some(Color::from_rgba8(
        (v >> 16) as u8,
        (v >> 8) as u8,
        v as u8,
        255,
    ))
}

impl Palette {
    fn tokyo() -> Palette {
        Palette::from_toml("").unwrap_or_else(|| unreachable!())
    }

    /// Missing or malformed keys fall back to Tokyo Night, so any table parses.
    fn from_toml(src: &str) -> Option<Palette> {
        let t: toml::Table = src.parse().ok()?;
        let get = |k: &str, d: &str| {
            t.get(k)
                .and_then(|v| v.as_str())
                .and_then(hex)
                .unwrap_or_else(|| hex(d).unwrap())
        };
        let mut bg = get("background", "#1a1b26");
        bg.set_alpha(0.94);
        Some(Palette {
            bg,
            border: get("muted", "#414868"),
            accent: get("accent", "#7aa2f7"),
            text: get("bright_foreground", "#c0caf5"),
            warn: get("yellow", "#e0af68"),
            err: get("red", "#f7768e"),
        })
    }

    /// Read on every show, so a theme change is picked up by the next recording.
    #[cfg(unix)]
    pub fn load() -> Palette {
        std::env::var_os("HOME")
            .map(|h| std::path::Path::new(&h).join(COLORS))
            .and_then(|p| std::fs::read_to_string(p).ok())
            .and_then(|s| Palette::from_toml(&s))
            .unwrap_or_else(Palette::tokyo)
    }
    #[cfg(windows)]
    pub fn load() -> Palette {
        Palette::tokyo()
    }
}

/// Font files, held only while the overlay is on screen.
pub struct Fonts {
    thai: Vec<u8>,
    latin: Vec<u8>,
}

impl Fonts {
    #[cfg(unix)]
    pub fn load() -> Option<Fonts> {
        Some(Fonts {
            thai: std::fs::read(THAI_FONT).ok()?,
            latin: std::fs::read(LATIN_FONT).ok()?,
        })
    }
    #[cfg(windows)]
    pub fn load() -> Option<Fonts> {
        let dir = crate::store::env_dir("WINDIR").ok()?.join("Fonts");
        let thai = ["LeelawUI.ttf", "leelawui.ttf", "tahoma.ttf"]
            .iter()
            .find_map(|name| std::fs::read(dir.join(name)).ok())?;
        let latin = std::fs::read(dir.join("segoeui.ttf")).ok()?;
        Some(Fonts { thai, latin })
    }
}

struct Faces<'a> {
    thai: Face<'a>,
    latin: Face<'a>,
}

fn is_thai(c: char) -> bool {
    ('\u{0E00}'..='\u{0E7F}').contains(&c)
}

/// Split into maximal runs that share a font: `true` = Thai.
fn runs(text: &str) -> Vec<(bool, &str)> {
    let mut out: Vec<(bool, &str)> = Vec::new();
    let mut start = 0;
    let mut cur = None;
    for (i, c) in text.char_indices() {
        let t = is_thai(c);
        match cur {
            Some(k) if k == t => {}
            Some(k) => {
                out.push((k, &text[start..i]));
                start = i;
                cur = Some(t);
            }
            None => cur = Some(t),
        }
    }
    if let Some(k) = cur {
        out.push((k, &text[start..]));
    }
    out
}

struct Outline(PathBuilder);

impl ttf_parser::OutlineBuilder for Outline {
    fn move_to(&mut self, x: f32, y: f32) {
        self.0.move_to(x, y);
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.0.line_to(x, y);
    }
    fn quad_to(&mut self, x1: f32, y1: f32, x: f32, y: f32) {
        self.0.quad_to(x1, y1, x, y);
    }
    fn curve_to(&mut self, x1: f32, y1: f32, x2: f32, y2: f32, x: f32, y: f32) {
        self.0.cubic_to(x1, y1, x2, y2, x, y);
    }
    fn close(&mut self) {
        self.0.close();
    }
}

/// Shape `text` and either measure it (`pm` = None) or paint it with its left
/// end at `x` on `baseline`. Returns the advance width in logical pixels.
fn text_run(
    faces: &Faces,
    mut pm: Option<(&mut PixmapMut, Transform, &Paint)>,
    text: &str,
    x: f32,
    baseline: f32,
) -> f32 {
    let mut pen = x;
    for (thai, run) in runs(text) {
        let face = if thai { &faces.thai } else { &faces.latin };
        let mut buf = UnicodeBuffer::new();
        buf.push_str(run);
        buf.guess_segment_properties();
        let shaped = rustybuzz::shape(face, &[], buf);
        let s = TEXT_PX / face.units_per_em() as f32;
        for (info, pos) in shaped.glyph_infos().iter().zip(shaped.glyph_positions()) {
            if let Some((pm, base, paint)) = pm.as_mut() {
                let mut o = Outline(PathBuilder::new());
                let id = ttf_parser::GlyphId(info.glyph_id as u16);
                if face.outline_glyph(id, &mut o).is_some()
                    && let Some(path) = o.0.finish()
                {
                    let gx = pen + pos.x_offset as f32 * s;
                    let gy = baseline - pos.y_offset as f32 * s;
                    let ts = base.pre_concat(Transform::from_row(s, 0.0, 0.0, -s, gx, gy));
                    pm.fill_path(&path, paint, FillRule::Winding, ts, None);
                }
            }
            pen += pos.x_advance as f32 * s;
        }
    }
    pen - x
}

fn paint(c: Color) -> Paint<'static> {
    let mut p = Paint::default();
    p.set_color(c);
    p.anti_alias = true;
    p
}

fn circle(cx: f32, cy: f32, r: f32) -> Path {
    PathBuilder::from_circle(cx, cy, r).unwrap()
}

fn rounded(x: f32, y: f32, w: f32, h: f32, r: f32) -> Path {
    let r = r.min(w / 2.0).min(h / 2.0);
    let mut b = PathBuilder::new();
    b.move_to(x + r, y);
    b.line_to(x + w - r, y);
    b.quad_to(x + w, y, x + w, y + r);
    b.line_to(x + w, y + h - r);
    b.quad_to(x + w, y + h, x + w - r, y + h);
    b.line_to(x + r, y + h);
    b.quad_to(x, y + h, x, y + h - r);
    b.line_to(x, y + r);
    b.quad_to(x, y, x + r, y);
    b.close();
    b.finish().unwrap()
}

fn with_alpha(mut c: Color, a: f32) -> Color {
    c.set_alpha(c.alpha() * a.clamp(0.0, 1.0));
    c
}

/// Map an RMS reading to a bar height fraction: speech sits well below full
/// scale, so lift the quiet end.
pub fn bar_height(rms: f32) -> f32 {
    (rms * 7.0).powf(0.6).clamp(0.0, 1.0)
}

/// Rise fast, fall slowly, so the bars look soft but still follow the voice.
pub fn smooth(prev: f32, next: f32) -> f32 {
    let k = if next > prev { 0.6 } else { 0.25 };
    prev + (next - prev) * k
}

pub fn render(pm: &mut PixmapMut, scale: f32, pal: &Palette, fonts: Option<&Fonts>, view: &View) {
    pm.fill(Color::TRANSPARENT);
    let base = Transform::from_scale(scale, scale);
    let faces = fonts.and_then(|f| {
        Some(Faces {
            thai: Face::from_slice(&f.thai, 0)?,
            latin: Face::from_slice(&f.latin, 0)?,
        })
    });
    let measure = |t: &str| {
        faces
            .as_ref()
            .map_or(0.0, |f| text_run(f, None, t, 0.0, 0.0))
    };

    let cy = H as f32 / 2.0;
    let (content_w, pad) = match view {
        View::Recording { .. } => (BARS as f32 * (BAR_W + BAR_GAP) - BAR_GAP, 24.0),
        View::Processing { .. } => (36.0 + 12.0 + measure("กำลังแปลง…"), 22.0),
        View::Notice { text, .. } => (20.0 + 10.0 + measure(text), 20.0),
    };
    // Long notices stop at the surface edge rather than being cut off mid-glyph.
    let pill_w = (content_w + 2.0 * pad).min(W as f32 - 4.0);
    let x0 = (W as f32 - pill_w) / 2.0;
    let y0 = (H as f32 - PILL_H) / 2.0;

    let body = rounded(x0, y0, pill_w, PILL_H, PILL_H / 2.0);
    pm.fill_path(&body, &paint(pal.bg), FillRule::Winding, base, None);
    let stroke = Stroke {
        width: 1.0,
        ..Stroke::default()
    };
    let edge = rounded(x0 + 0.5, y0 + 0.5, pill_w - 1.0, PILL_H - 1.0, PILL_H / 2.0);
    pm.stroke_path(&edge, &paint(pal.border), &stroke, base, None);

    let mut x = x0 + pad;
    let label = |pm: &mut PixmapMut, t: &str, x: f32, color: Color| {
        if let Some(f) = &faces {
            text_run(
                f,
                Some((pm, base, &paint(color))),
                t,
                x,
                cy + TEXT_PX * 0.36,
            );
        }
    };
    match view {
        View::Recording { bars } => {
            // `bars` is oldest first, so the newest reading lands at the right edge.
            for i in 0..BARS {
                let v = bars.get(i).copied().unwrap_or(0.0);
                let h = 4.0 + v * (PILL_H - 16.0);
                let path = rounded(x, cy - h / 2.0, BAR_W, h, BAR_W / 2.0);
                pm.fill_path(&path, &paint(pal.accent), FillRule::Winding, base, None);
                x += BAR_W + BAR_GAP;
            }
        }
        View::Processing { phase } => {
            for i in 0..3 {
                let wave = 0.5 + 0.5 * (phase * TAU - i as f32 * 0.9).sin();
                let r = 3.0 + 1.5 * wave;
                let dot = circle(x + 4.0 + i as f32 * 14.0, cy, r);
                let c = with_alpha(pal.accent, 0.4 + 0.6 * wave);
                pm.fill_path(&dot, &paint(c), FillRule::Winding, base, None);
            }
            label(pm, "กำลังแปลง…", x + 36.0 + 12.0, pal.text);
        }
        View::Notice { kind, text } => {
            let color = if *kind == Kind::Error {
                pal.err
            } else {
                pal.warn
            };
            pm.fill_path(
                &circle(x + 10.0, cy, 10.0),
                &paint(color),
                FillRule::Winding,
                base,
                None,
            );
            // "!" cut out of the disc in the pill's own colour.
            let mark = paint(with_alpha(pal.bg, 1.0));
            let stem = rounded(x + 8.75, cy - 5.5, 2.5, 7.0, 1.25);
            pm.fill_path(&stem, &mark, FillRule::Winding, base, None);
            pm.fill_path(
                &circle(x + 10.0, cy + 5.0, 1.4),
                &mark,
                FillRule::Winding,
                base,
                None,
            );
            label(pm, text, x + 30.0, pal.text);
        }
    }
}

/// Premultiplied RGBA (tiny-skia) to the BGRA byte order of `wl_shm` Argb8888.
pub fn to_argb8888(src: &[u8], dst: &mut [u8]) {
    for (s, d) in src
        .as_chunks::<4>()
        .0
        .iter()
        .zip(dst.as_chunks_mut::<4>().0)
    {
        d.copy_from_slice(&[s[2], s[1], s[0], s[3]]);
    }
}

#[cfg(test)]
mod tests {
    use tiny_skia::Pixmap;

    use super::*;

    #[test]
    fn splits_thai_from_latin() {
        assert_eq!(runs(""), vec![]);
        assert_eq!(
            runs("สั่ง oliv retry ภายหลัง"),
            vec![(true, "สั่ง"), (false, " oliv retry "), (true, "ภายหลัง")]
        );
        assert_eq!(runs("abc"), vec![(false, "abc")]);
    }

    #[test]
    fn theme_colors_parse_with_fallbacks() {
        let p = Palette::from_toml("accent = \"#ff0000\"\nred = \"nope\"").unwrap();
        assert_eq!(p.accent.to_color_u8().red(), 255);
        assert_eq!(p.err, hex("#f7768e").unwrap(), "bad value falls back");
        assert!(Palette::from_toml("= broken").is_none());
    }

    #[test]
    fn bars_are_soft_and_bounded() {
        assert_eq!(bar_height(0.0), 0.0);
        assert_eq!(bar_height(1.0), 1.0);
        assert!(bar_height(0.05) > 0.05, "quiet end is lifted");
        assert!(
            smooth(0.0, 1.0) > 1.0 - smooth(1.0, 0.0),
            "attack faster than release"
        );
    }

    /// `OLIV_PREVIEW=<dir> cargo test preview -- --ignored` writes PNGs to look at.
    #[test]
    #[ignore]
    fn preview() {
        let dir = std::env::var("OLIV_PREVIEW").unwrap();
        let fonts = Fonts::load();
        assert!(fonts.is_some(), "fonts missing");
        let pal = Palette::load();
        let bars: Vec<f32> = (0..BARS)
            .map(|i| bar_height(0.02 + 0.1 * ((i as f32) * 0.5).sin().abs()))
            .collect();
        let views = [
            ("rec", View::Recording { bars: &bars }),
            ("proc", View::Processing { phase: 0.2 }),
            (
                "info",
                View::Notice {
                    kind: Kind::Info,
                    text: "ไม่ได้ยินเสียงพูด",
                },
            ),
            (
                "err",
                View::Notice {
                    kind: Kind::Error,
                    text: "ส่งไม่สำเร็จ เก็บเสียงไว้แล้ว สั่ง oliv retry ภายหลัง",
                },
            ),
        ];
        for (name, v) in &views {
            let mut pm = Pixmap::new(W * 2, H * 2).unwrap();
            render(&mut pm.as_mut(), 2.0, &pal, fonts.as_ref(), v);
            pm.save_png(format!("{dir}/{name}.png")).unwrap();
        }
    }
}
