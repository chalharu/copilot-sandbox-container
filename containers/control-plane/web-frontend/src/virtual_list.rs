#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VisibleWindow {
    pub start: usize,
    pub end: usize,
    pub top_padding: i32,
    pub bottom_padding: i32,
}

pub fn visible_window(
    total_items: usize,
    scroll_top: i32,
    viewport_height: i32,
    row_height: i32,
    overscan: usize,
) -> VisibleWindow {
    if total_items == 0 || row_height <= 0 || viewport_height <= 0 {
        return VisibleWindow {
            start: 0,
            end: 0,
            top_padding: 0,
            bottom_padding: 0,
        };
    }

    let scrolled_rows = (scroll_top.max(0) / row_height) as usize;
    let visible_rows = ((viewport_height.max(row_height) + row_height - 1) / row_height) as usize;
    let start = scrolled_rows.saturating_sub(overscan);
    let end = (scrolled_rows + visible_rows + overscan).min(total_items);
    let top_padding = (start as i32) * row_height;
    let bottom_padding = ((total_items.saturating_sub(end)) as i32) * row_height;

    VisibleWindow {
        start,
        end,
        top_padding,
        bottom_padding,
    }
}

#[cfg(test)]
mod tests {
    use super::{VisibleWindow, visible_window};

    #[test]
    fn returns_empty_window_for_empty_list() {
        assert_eq!(
            visible_window(0, 0, 420, 112, 4),
            VisibleWindow {
                start: 0,
                end: 0,
                top_padding: 0,
                bottom_padding: 0,
            }
        );
    }

    #[test]
    fn overscans_visible_rows() {
        assert_eq!(
            visible_window(100, 224, 420, 112, 2),
            VisibleWindow {
                start: 0,
                end: 8,
                top_padding: 0,
                bottom_padding: 10304,
            }
        );
    }

    #[test]
    fn clamps_window_at_end() {
        assert_eq!(
            visible_window(10, 900, 420, 112, 2),
            VisibleWindow {
                start: 6,
                end: 10,
                top_padding: 672,
                bottom_padding: 0,
            }
        );
    }
}

