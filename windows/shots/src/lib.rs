//! Pasting an image and taking a screenshot: the parts that need no window.
//!
//! Specification: `dev-docs/poltergeist/screenshot.md`. It is shared with the
//! macOS host, so a rule that looks arbitrary here (the file name, the seven
//! days, text before files before images) is that document's and is changed
//! there first.
//!
//! | module | what it decides |
//! | --- | --- |
//! | [`name`] | what a shot's file is called, and which names are ours |
//! | [`store`] | writing a new shot without overwriting one |
//! | [`sweep`] | which old files startup deletes -- and which it must not |
//! | [`dib`] | what a clipboard `CF_DIB` decodes to |
//! | [`encode`] | pixels to PNG bytes |
//! | [`paste`] | which clipboard format a paste is answered from |
//! | [`geom`] | selections, monitors, windows, handles: where things are |
//! | [`annot`] | annotations as data: the sidecar `.json` and the pasted line |
//! | [`dclick`] | the mouse trigger: one click with modifiers held |
//! | [`overlay`] | what a key does while the frozen screen is up |
//! | [`agent`] | an agent's request: which rectangle, what is blacked out, the answer |
//! | [`style`] | the tools, the nine colours, the five steps of each size |
//! | [`pixels`] | the mosaic, the highlighter, and the one image that leaves |
//! | [`glass`] | the frosted glass outside the selection, and a frame out of it |
//! | [`chrome`] | the toolbar's plate and cells, the selection's outline, a selected annotation's frame |
//! | [`motion`] | what changes over a moment: which shares to mix two pictures by, and until when |
//! | [`paint`] | smooth shapes laid into pixels: rounded rectangles, rings, glows |
//! | [`look`] | what the overlay looks like: sizes, colours, the icons' paths (generated) |
//! | [`icon`] | one icon into a button cell, the same pixels as the macOS host |

pub mod agent;
pub mod annot;
pub mod autoscroll;
pub mod chrome;
pub mod dclick;
pub mod dib;
pub mod editor;
pub mod encode;
pub mod geom;
pub mod glass;
pub mod icon;
pub mod magnifier;
pub mod look;
pub mod motion;
pub mod name;
pub mod overlay;
pub mod paint;
pub mod paste;
pub mod pixels;
pub mod stitch;
pub mod store;
pub mod style;
pub mod sweep;
pub mod textbox;
pub mod toast;
pub mod toolbar;
pub mod undo;

/// Pixels, top row first, four bytes each in R, G, B, A order, not
/// premultiplied. `rgba.len() == width * height * 4`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Image {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

impl Image {
    /// From the bits of a top-down 32-bit GDI bitmap: B, G, R and a fourth
    /// byte per pixel.
    ///
    /// **The fourth byte is ignored and the image is opaque.** GDI drawing
    /// leaves it 0 wherever it draws, so a composed screenshot read as BGRA
    /// would be transparent exactly where the annotations are. `None` when
    /// `bgrx` is not `width * height * 4` bytes.
    pub fn from_bgrx(width: u32, height: u32, bgrx: &[u8]) -> Option<Image> {
        if bgrx.len() != width as usize * height as usize * 4 {
            return None;
        }
        let rgba = bgrx.chunks_exact(4).flat_map(|p| [p[2], p[1], p[0], 255]).collect();
        Some(Image { width, height, rgba })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gdi_bits_become_opaque_rgba() {
        // Two pixels: pure blue with GDI's zero fourth byte, then an orange.
        let i = Image::from_bgrx(2, 1, &[255, 0, 0, 0, 10, 128, 250, 77]).unwrap();
        assert_eq!(i.rgba, [0, 0, 255, 255, 250, 128, 10, 255]);
        assert_eq!(Image::from_bgrx(2, 1, &[0; 7]), None);
        assert_eq!(Image::from_bgrx(2, 2, &[0; 8]), None);
    }
}
