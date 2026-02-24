#pragma once

// FLTK 1.4 ships Fl_Grid, but FLTK 1.3 does not.
// This wrapper keeps the same include path for both versions.
#if defined(__has_include)
#  if __has_include(<FL/Fl_Grid.H>)
#    include <FL/Fl_Grid.H>
#    define SHARK_HAS_FL_GRID 1
#  endif
#endif

#ifndef SHARK_HAS_FL_GRID
#include <FL/Fl_Group.H>
#include <algorithm>
#include <vector>

class Fl_Grid : public Fl_Group {
 public:
  Fl_Grid(int X, int Y, int W, int H, const char* L = nullptr)
      : Fl_Group(X, Y, W, H, L) {}

  void layout(int rows, int cols, int margin = 0, int gap = 0) {
    rows_ = std::max(0, rows);
    cols_ = std::max(0, cols);
    margin_ = std::max(0, margin);
    gap_ = std::max(0, gap);
    row_heights_.assign(rows_, 0);
    col_widths_.assign(cols_, 0);
    row_weights_.assign(rows_, 1);
    col_weights_.assign(cols_, 1);
    relayout();
  }

  void widget(Fl_Widget* w, int row, int col) {
    if (!w || row < 0 || col < 0 || row >= rows_ || col >= cols_) {
      return;
    }
    if (w->parent() != this) {
      add(w);
    }
    for (auto& cell : cells_) {
      if (cell.widget == w) {
        cell.row = row;
        cell.col = col;
        relayout();
        return;
      }
    }
    cells_.push_back({w, row, col});
    relayout();
  }

  void row_height(int row, int height) {
    if (row >= 0 && row < rows_) {
      row_heights_[row] = std::max(0, height);
      relayout();
    }
  }

  void col_width(int col, int width) {
    if (col >= 0 && col < cols_) {
      col_widths_[col] = std::max(0, width);
      relayout();
    }
  }

  void row_weight(int row, int weight) {
    if (row >= 0 && row < rows_) {
      row_weights_[row] = std::max(0, weight);
      relayout();
    }
  }

  void col_weight(int col, int weight) {
    if (col >= 0 && col < cols_) {
      col_weights_[col] = std::max(0, weight);
      relayout();
    }
  }

  void clear_layout() {
    cells_.clear();
  }

  void resize(int X, int Y, int W, int H) override {
    Fl_Group::resize(X, Y, W, H);
    relayout();
  }

 private:
  struct Cell {
    Fl_Widget* widget;
    int row;
    int col;
  };

  static void compute_track_sizes(const std::vector<int>& fixed_sizes,
                                  const std::vector<int>& weights,
                                  int available,
                                  int count,
                                  std::vector<int>* out) {
    out->assign(count, 0);
    if (count <= 0) {
      return;
    }

    int fixed_total = 0;
    int flex_weight_total = 0;
    int flex_count = 0;

    for (int i = 0; i < count; ++i) {
      const int fixed = fixed_sizes[i];
      if (fixed > 0) {
        (*out)[i] = fixed;
        fixed_total += fixed;
      } else {
        ++flex_count;
        flex_weight_total += std::max(0, weights[i]);
      }
    }

    int flexible_space = std::max(0, available - fixed_total);
    if (flex_count <= 0 || flexible_space <= 0) {
      return;
    }

    if (flex_weight_total <= 0) {
      const int base = flexible_space / flex_count;
      int rem = flexible_space % flex_count;
      for (int i = 0; i < count; ++i) {
        if (fixed_sizes[i] > 0) {
          continue;
        }
        (*out)[i] = base + (rem > 0 ? 1 : 0);
        if (rem > 0) {
          --rem;
        }
      }
      return;
    }

    int assigned = 0;
    for (int i = 0; i < count; ++i) {
      if (fixed_sizes[i] > 0) {
        continue;
      }
      const int weight = std::max(0, weights[i]);
      const int share = (flexible_space * weight) / flex_weight_total;
      (*out)[i] = share;
      assigned += share;
    }

    int rem = flexible_space - assigned;
    for (int i = 0; i < count && rem > 0; ++i) {
      if (fixed_sizes[i] > 0 || std::max(0, weights[i]) <= 0) {
        continue;
      }
      ++(*out)[i];
      --rem;
    }
  }

  void relayout() {
    if (rows_ <= 0 || cols_ <= 0) {
      return;
    }

    const int avail_w = std::max(0, w() - (2 * margin_) - std::max(0, cols_ - 1) * gap_);
    const int avail_h = std::max(0, h() - (2 * margin_) - std::max(0, rows_ - 1) * gap_);

    std::vector<int> col_sizes;
    std::vector<int> row_sizes;
    compute_track_sizes(col_widths_, col_weights_, avail_w, cols_, &col_sizes);
    compute_track_sizes(row_heights_, row_weights_, avail_h, rows_, &row_sizes);

    std::vector<int> col_offsets(cols_, 0);
    std::vector<int> row_offsets(rows_, 0);
    int running = margin_;
    for (int c = 0; c < cols_; ++c) {
      col_offsets[c] = running;
      running += col_sizes[c] + gap_;
    }
    running = margin_;
    for (int r = 0; r < rows_; ++r) {
      row_offsets[r] = running;
      running += row_sizes[r] + gap_;
    }

    for (const auto& cell : cells_) {
      if (!cell.widget || cell.row < 0 || cell.col < 0 || cell.row >= rows_ || cell.col >= cols_) {
        continue;
      }
      cell.widget->resize(x() + col_offsets[cell.col], y() + row_offsets[cell.row], col_sizes[cell.col],
                          row_sizes[cell.row]);
    }
    redraw();
  }

  int rows_{0};
  int cols_{0};
  int margin_{0};
  int gap_{0};

  std::vector<int> row_heights_;
  std::vector<int> col_widths_;
  std::vector<int> row_weights_;
  std::vector<int> col_weights_;
  std::vector<Cell> cells_;
};
#endif
