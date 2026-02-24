// --------------------------------
// Created by Anubhav Parida.
// --------------------------------
#include "Helper.hh"
#include "Solver.hh"
#include "Isomorphism.hh"
#include "tree/Nodes.hh"
#include <oneapi/tbb/blocked_range.h>
#include <oneapi/tbb/parallel_for.h>
#include <algorithm>
#include <array>
#include <cctype>
#include <map>
#include <cmath>
#include <iostream>
#include <optional>

namespace {
auto to_lower_copy(std::string s) -> std::string {
  std::transform(s.begin(), s.end(), s.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return s;
}

auto parse_int_suffix(const std::string &value) -> std::optional<int> {
  if (value.empty()) {
    return std::nullopt;
  }
  try {
    size_t consumed = 0;
    int parsed = std::stoi(value, &consumed);
    if (consumed != value.size()) {
      return std::nullopt;
    }
    return parsed;
  } catch (...) {
    return std::nullopt;
  }
}

auto is_root_action_node(const ActionNode *node) -> bool {
  return node && node->get_parent() == node;
}

auto lock_matches_action(const NodeLockItem &lock, const Action &action) -> bool {
  const std::string key = to_lower_copy(lock.action);
  if (key == "fold") {
    return action.type == Action::FOLD;
  }
  if (key == "check") {
    return action.type == Action::CHECK;
  }
  if (key == "call") {
    return action.type == Action::CALL;
  }
  if (key == "bet") {
    return action.type == Action::BET;
  }
  if (key == "raise") {
    return action.type == Action::RAISE;
  }

  const size_t colon = key.find(':');
  if (colon == std::string::npos) {
    return false;
  }

  const std::string prefix = key.substr(0, colon);
  const std::string suffix = key.substr(colon + 1);
  const auto amount = parse_int_suffix(suffix);
  if (!amount.has_value()) {
    return false;
  }

  if (prefix == "bet") {
    return action.type == Action::BET && action.amount == amount.value();
  }
  if (prefix == "raise") {
    return action.type == Action::RAISE && action.amount == amount.value();
  }
  return false;
}

void apply_locked_root_strategy(const ActionNode *node, std::vector<float> &strategy,
                                int num_hands, int num_actions, NodeLockData *node_lock,
                                bool *lock_applied_for_node) {
  if (!node_lock || !node_lock->provided || node_lock->node_id != "root" || !is_root_action_node(node)) {
    return;
  }

  if (num_hands <= 0 || num_actions <= 0) {
    return;
  }

  std::vector<float> locked_values(static_cast<size_t>(num_actions), -1.0f);
  bool has_any_lock = false;
  for (int a = 0; a < num_actions; ++a) {
    const Action action = node->get_action(a);
    for (const auto &lock : node_lock->locks) {
      if (!lock_matches_action(lock, action)) {
        continue;
      }
      float freq = lock.frequency;
      if (freq < 0.0f) {
        freq = 0.0f;
      } else if (freq > 1.0f) {
        freq = 1.0f;
      }
      locked_values[static_cast<size_t>(a)] = freq;
      has_any_lock = true;
    }
  }

  if (!has_any_lock) {
    return;
  }

  for (int h = 0; h < num_hands; ++h) {
    float locked_sum = 0.0f;
    float unlocked_sum = 0.0f;
    int unlocked_count = 0;
    for (int a = 0; a < num_actions; ++a) {
      const size_t idx = static_cast<size_t>(h + a * num_hands);
      const float locked = locked_values[static_cast<size_t>(a)];
      if (locked >= 0.0f) {
        strategy[idx] = locked;
        locked_sum += locked;
      } else {
        unlocked_sum += strategy[idx];
        ++unlocked_count;
      }
    }

    if (locked_sum >= 1.0f) {
      const float denom = (locked_sum > 0.0f) ? locked_sum : 1.0f;
      for (int a = 0; a < num_actions; ++a) {
        const size_t idx = static_cast<size_t>(h + a * num_hands);
        if (locked_values[static_cast<size_t>(a)] >= 0.0f) {
          strategy[idx] /= denom;
        } else {
          strategy[idx] = 0.0f;
        }
      }
      continue;
    }

    const float remaining = 1.0f - locked_sum;
    if (unlocked_count <= 0) {
      const float denom = (locked_sum > 0.0f) ? locked_sum : 1.0f;
      for (int a = 0; a < num_actions; ++a) {
        const size_t idx = static_cast<size_t>(h + a * num_hands);
        if (locked_values[static_cast<size_t>(a)] >= 0.0f) {
          strategy[idx] /= denom;
        }
      }
      continue;
    }

    if (unlocked_sum > 0.0f) {
      for (int a = 0; a < num_actions; ++a) {
        if (locked_values[static_cast<size_t>(a)] >= 0.0f) {
          continue;
        }
        const size_t idx = static_cast<size_t>(h + a * num_hands);
        strategy[idx] = (strategy[idx] / unlocked_sum) * remaining;
      }
    } else {
      const float split = remaining / static_cast<float>(unlocked_count);
      for (int a = 0; a < num_actions; ++a) {
        if (locked_values[static_cast<size_t>(a)] >= 0.0f) {
          continue;
        }
        const size_t idx = static_cast<size_t>(h + a * num_hands);
        strategy[idx] = split;
      }
    }
  }

  if (lock_applied_for_node) {
    *lock_applied_for_node = true;
  }
  node_lock->applied = true;
  node_lock->applications += 1;
}
} // namespace

void CFRHelper::compute() {
  initialize_combo_index();

  if (m_node->get_node_type() == NodeType::ACTION_NODE) {
    action_node_utility(static_cast<ActionNode *>(m_node), m_hero_reach_probs,
                        m_villain_reach_probs);
  } else if (m_node->get_node_type() == NodeType::CHANCE_NODE) {
    chance_node_utility(static_cast<ChanceNode *>(m_node), m_hero_reach_probs,
                        m_villain_reach_probs, m_board);
  } else {
    terminal_node_utility(static_cast<TerminalNode *>(m_node),
                          m_villain_reach_probs, m_board);
  }
}

void CFRHelper::initialize_combo_index() {
  if (m_combo_index_initialized)
    return;

  constexpr int NC = 52;
  for (int i = 0; i < NC; ++i)
    for (int j = 0; j < NC; ++j)
      m_villain_combo_index[i][j] = -1;

  for (int v = 0; v < m_num_villain_hands; ++v) {
    auto &vc = m_villain_preflop_combos[v];
    m_villain_combo_index[vc.hand1][vc.hand2] = v;
    m_villain_combo_index[vc.hand2][vc.hand1] = v;
  }

  m_combo_index_initialized = true;
}

auto CFRHelper::get_isomorphic_card_groups(const std::vector<Card> &board,
                                            const ChanceNode *node)
    -> std::vector<std::vector<int>> {
  std::array<int, 4> suit_count{};
  for (const auto &card : board) {
    suit_count[int(card) % 4]++;
  }

  std::map<int, int> count_to_canonical;
  std::vector<int> unique_counts;
  for (int c : suit_count) {
    if (std::find(unique_counts.begin(), unique_counts.end(), c) == unique_counts.end()) {
      unique_counts.push_back(c);
    }
  }
  std::sort(unique_counts.begin(), unique_counts.end(), std::greater<int>());

  int next_canonical = 0;
  for (int count : unique_counts) {
    count_to_canonical[count] = next_canonical++;
  }

  std::array<int, 4> canonical_suit;
  for (int s = 0; s < 4; ++s) {
    canonical_suit[s] = count_to_canonical[suit_count[s]];
  }

  std::map<std::pair<int, int>, std::vector<int>> groups;
  for (int card = 0; card < 52; ++card) {
    if (!node->get_child(card))
      continue;

    Card c(card);
    int rank = int(c) / 4;
    int can_suit = canonical_suit[int(c) % 4];
    groups[{rank, can_suit}].push_back(card);
  }

  std::vector<std::vector<int>> result;
  for (auto &[key, group] : groups) {
    if (!group.empty()) {
      result.push_back(std::move(group));
    }
  }

  return result;
}

void CFRHelper::action_node_utility(
    ActionNode *const node, const std::vector<float> &hero_reach_pr,
    const std::vector<float> &villain_reach_pr) {
  const int player{node->get_player()};
  const int num_actions{node->get_num_actions()};
  const int num_hands = (player == m_hero) ? m_num_hero_hands : m_num_villain_hands;

  std::vector<float> strategy(num_hands * num_actions);
  node->get_trainer()->get_current_strat(strategy);
  bool lock_applied_for_node = false;
  apply_locked_root_strategy(node, strategy, num_hands, num_actions, m_node_lock, &lock_applied_for_node);

  std::vector<float> subgame_utils_flat(num_actions * m_num_hero_hands);
  auto get_utils = [&](int action, int hand) -> float& {
    return subgame_utils_flat[action * m_num_hero_hands + hand];
  };

  tbb::parallel_for(
      tbb::blocked_range<int>(0, num_actions),
      [&](const tbb::blocked_range<int> &r) {
        std::vector<float> hero_buffer(m_num_hero_hands);
        std::vector<float> villain_buffer(m_num_villain_hands);

        for (auto i = r.begin(); i < r.end(); ++i) {
          if (player == m_hero) {
            // VECTORIZED: GCC emits SSE packed multiply (mulps xmm0, xmm1) processing 4 floats/iter
            // Assembly: movups (%r13,%rcx), %xmm6; mulps %xmm6, %xmm0; movups %xmm0, (%rdi,%rcx)
            for (std::size_t hand{0}; hand < m_num_hero_hands; ++hand) {
              hero_buffer[hand] =
                  strategy[hand + i * m_num_hero_hands] * hero_reach_pr[hand];
            }
            // VECTORIZED: Simple copy uses movups (16-byte unaligned move)
            for (std::size_t hand{0}; hand < m_num_villain_hands; ++hand) {
              villain_buffer[hand] = villain_reach_pr[hand];
            }
          } else {
            // VECTORIZED: Simple copy uses movups (16-byte unaligned move)
            for (std::size_t hand{0}; hand < m_num_hero_hands; ++hand) {
              hero_buffer[hand] = hero_reach_pr[hand];
            }
            // VECTORIZED: GCC emits SSE packed multiply (mulps) processing 4 floats/iter
            for (std::size_t hand{0}; hand < m_num_villain_hands; ++hand) {
              villain_buffer[hand] =
                  strategy[hand + i * m_num_villain_hands] *
                  villain_reach_pr[hand];
            }
          }
          CFRHelper rec{node->get_child(i),
                        m_hero,
                        m_villain,
                        m_hero_preflop_combos,
                        m_villain_preflop_combos,
                        hero_buffer,
                        villain_buffer,
                        m_board,
                        m_iteration_count,
                        m_rrm,
                        m_hero_to_villain,
                        m_node_lock};
          rec.compute();
          auto result = rec.get_result();
          for (std::size_t hand{0}; hand < m_num_hero_hands; ++hand) {
            get_utils(i, hand) = result[hand];
          }
        }
      });

  auto *trainer{node->get_trainer()};
  if (trainer->get_current() != m_hero) {
    for (std::size_t action{0}; action < num_actions; ++action) {
      for (std::size_t hand{0}; hand < m_num_hero_hands; ++hand) {
        m_result[hand] += get_utils(action, hand);
      }
    }
  } else {
    for (std::size_t action{0}; action < num_actions; ++action) {
      for (std::size_t hand{0}; hand < m_num_hero_hands; ++hand) {
        m_result[hand] += get_utils(action, hand) *
                          strategy[hand + action * m_num_hero_hands];
      }
    }

    if (!lock_applied_for_node) {
      trainer->update_regrets(subgame_utils_flat, m_result, m_iteration_count);
    }
    trainer->update_cum_strategy(strategy, hero_reach_pr, m_iteration_count);
  }
};

void CFRHelper::chance_node_utility(const ChanceNode *node,
                                    const std::vector<float> &hero_reach_pr,
                                    const std::vector<float> &villain_reach_pr,
                                    const std::vector<Card> &board) {
  const uint64_t board_mask = CardUtility::board_to_mask(board);
  const auto& iso_data = node->get_isomorphism_data();

  std::vector<int> rep_cards;
  rep_cards.reserve(52);
  for (int card = 0; card < 52; ++card) {
    if (!((1ULL << card) & board_mask) && node->get_child(card)) {
      rep_cards.push_back(card);
    }
  }

  const int num_rep_cards = static_cast<int>(rep_cards.size());
  if (num_rep_cards == 0) return;

  const int num_iso_cards = static_cast<int>(iso_data.isomorphism_card.size());
  const int chance_factor = num_rep_cards + num_iso_cards;
  const float reach_scale = 1.0f / static_cast<float>(chance_factor);

  std::vector<float> cfv_actions(num_rep_cards * m_num_hero_hands);
  auto get_utils = [&](int card_idx, int hand) -> float& {
    return cfv_actions[card_idx * m_num_hero_hands + hand];
  };

  tbb::parallel_for(
      tbb::blocked_range<int>(0, num_rep_cards),
      [&](const tbb::blocked_range<int> &r) {
        std::vector<float> hero_buffer(m_num_hero_hands);
        std::vector<float> villain_buffer(m_num_villain_hands);
        std::vector<Card> board_buffer;
        board_buffer.reserve(6);

        for (auto i = r.begin(); i < r.end(); ++i) {
          int card = rep_cards[i];

          board_buffer = board;
          board_buffer.push_back(card);

          std::fill(hero_buffer.begin(), hero_buffer.end(), 0.0f);
          std::fill(villain_buffer.begin(), villain_buffer.end(), 0.0f);

          for (std::size_t hand{0}; hand < m_num_hero_hands; ++hand) {
            if (!CardUtility::overlap(m_hero_preflop_combos[hand], card)) {
              hero_buffer[hand] = hero_reach_pr[hand];
            }
          }

          for (std::size_t hand{0}; hand < m_num_villain_hands; ++hand) {
            if (!CardUtility::overlap(m_villain_preflop_combos[hand], card)) {
              villain_buffer[hand] = villain_reach_pr[hand] * reach_scale;
            }
          }

          CFRHelper rec{node->get_child(card),
                        m_hero,
                        m_villain,
                        m_hero_preflop_combos,
                        m_villain_preflop_combos,
                        hero_buffer,
                        villain_buffer,
                        board_buffer,
                        m_iteration_count,
                        m_rrm,
                        m_hero_to_villain,
                        m_node_lock};
          rec.compute();
          auto result = rec.get_result();
          for (std::size_t hand{0}; hand < m_num_hero_hands; ++hand) {
            get_utils(i, hand) = result[hand];
          }
        }
      });

  // VECTORIZED: GCC converts f32->f64 and accumulates using SSE2 packed doubles
  // Assembly: cvtps2pd %xmm0, %xmm0; addpd %xmm7, %xmm1; movupd %xmm1, -16(%rax)
  std::vector<double> result_f64(m_num_hero_hands, 0.0);
  for (int i = 0; i < num_rep_cards; ++i) {
    for (std::size_t h{0}; h < m_num_hero_hands; ++h) {
      result_f64[h] += static_cast<double>(get_utils(i, h));
    }
  }

  for (std::size_t i = 0; i < iso_data.isomorphism_ref.size(); ++i) {
    int iso_card = iso_data.isomorphism_card[i];
    int iso_suit = iso_card & 3;
    int rep_action_idx = iso_data.isomorphism_ref[i];

    const auto& swap_list = iso_data.swap_list[iso_suit][m_hero - 1];

    float* tmp = &cfv_actions[rep_action_idx * m_num_hero_hands];

    IsomorphismComputer::apply_swap(tmp, m_num_hero_hands, swap_list);

    // VECTORIZED: Same as above - cvtps2pd + addpd for 2 doubles/iter
    for (std::size_t h{0}; h < m_num_hero_hands; ++h) {
      result_f64[h] += static_cast<double>(tmp[h]);
    }

    IsomorphismComputer::apply_swap(tmp, m_num_hero_hands, swap_list);
  }

  // VECTORIZED: GCC emits cvtpd2ps (packed double to single) + movups
  // Assembly: cvtpd2ps %xmm0, %xmm0; movlps %xmm0, (%rax)
  for (std::size_t h{0}; h < m_num_hero_hands; ++h) {
    m_result[h] = static_cast<float>(result_f64[h]);
  }
}

auto CFRHelper::get_card_weights(const std::vector<float> &villain_reach_pr,
                                 const std::vector<Card> &board)
    -> std::vector<float> {
  constexpr int NC = 52;

  float p_total = 0.0f;
  std::array<float, NC> p_card{};
  for (int v = 0; v < m_num_villain_hands; ++v) {
    const auto &vc = m_villain_preflop_combos[v];
    if (CardUtility::overlap(vc, board))
      continue;
    float pr = villain_reach_pr[v];
    p_total += pr;
    p_card[int(vc.hand1)] += pr;
    p_card[int(vc.hand2)] += pr;
  }

  uint64_t board_mask_bits = CardUtility::board_to_mask(board);

  std::vector<float> card_weights(m_num_hero_hands * NC, 0.0f);
  for (size_t h = 0; h < m_num_hero_hands; ++h) {
    const auto &hc = m_hero_preflop_combos[h];
    int h1 = int(hc.hand1), h2 = int(hc.hand2);
    uint64_t hero_mask = (1ULL << h1) | (1ULL << h2);
    if ((hero_mask & board_mask_bits) != 0)
      continue;

    int v_self = m_hero_to_villain[h];
    float self_pr = (v_self >= 0 ? villain_reach_pr[v_self] : 0.0f);
    float S_h = p_total - p_card[h1] - p_card[h2] + self_pr;

    uint64_t unavailable = board_mask_bits | hero_mask;

    thread_local std::vector<int> available_cards;
    available_cards.clear();
    for (int c = 0; c < NC; ++c) {
      if (!((1ULL << c) & unavailable)) {
        available_cards.push_back(c);
      }
    }

    float total_w = 0.0f;
    for (int c : available_cards) {
      float excl = 0.0f;
      int idx = m_villain_combo_index[h1][c];
      if (idx >= 0)
        excl += villain_reach_pr[idx];
      idx = m_villain_combo_index[h2][c];
      if (idx >= 0)
        excl += villain_reach_pr[idx];

      float w = S_h - (p_card[c] - excl);
      card_weights[h + c * m_num_hero_hands] = w;
      total_w += w;
    }

    if (total_w > 0.0f) {
      float inv_total = 1.0f / total_w;
      for (int c : available_cards) {
        card_weights[h + c * m_num_hero_hands] *= inv_total;
      }
    }
  }

  return card_weights;
}

void CFRHelper::terminal_node_utility(
    const TerminalNode *const node, const std::vector<float> &villain_reach_pr,
    const std::vector<Card> &board) {
  switch (node->get_type()) {
  case TerminalNode::ALLIN:
    m_result = get_all_in_utils(node, villain_reach_pr, board);
    break;
  case TerminalNode::UNCONTESTED:
    m_result = get_uncontested_utils(node, villain_reach_pr, board);
    break;
  case TerminalNode::SHOWDOWN:
    m_result = get_showdown_utils(node, villain_reach_pr, board);
    break;
  }
}

auto CFRHelper::get_all_in_utils(const TerminalNode *node,
                                 const std::vector<float> &villain_reach_pr,
                                 const std::vector<Card> &board)
    -> std::vector<float> {
  assert(board.size() <= 5 && "get_all_in_utils unexpected all in board size");
  if (board.size() == 5) {
    return get_showdown_utils(node, villain_reach_pr, board);
  }

  std::vector<float> preflop_combo_evs(m_num_hero_hands);
  std::vector<int> card_counts(m_num_hero_hands, 0);

  for (int card = 0; card < 52; ++card) {
    if (CardUtility::overlap(card, board))
      continue;

    auto new_board{board};
    new_board.push_back(card);

    std::vector<float> new_villain_reach_probs(m_num_villain_hands);
    for (int hand = 0; hand < m_num_villain_hands; ++hand) {
      if (!CardUtility::overlap(m_villain_preflop_combos[hand], card))
        new_villain_reach_probs[hand] = villain_reach_pr[hand];
    }

    const auto subgame_evs{
        get_all_in_utils(node, new_villain_reach_probs, new_board)};

    for (int hand = 0; hand < m_num_hero_hands; ++hand) {
      if (!CardUtility::overlap(m_hero_preflop_combos[hand], card)) {
        preflop_combo_evs[hand] += subgame_evs[hand];
        card_counts[hand]++;
      }
    }
  }

  for (int hand = 0; hand < m_num_hero_hands; ++hand) {
    if (card_counts[hand] > 0) {
      preflop_combo_evs[hand] /= static_cast<float>(card_counts[hand]);
    }
  }

  return preflop_combo_evs;
}

auto CFRHelper::get_showdown_utils(const TerminalNode *node,
                                   const std::vector<float> &villain_reach_pr,
                                   const std::vector<Card> &board)
    -> std::vector<float> {
  const std::vector<RiverCombo> hero_river_combos{
      m_rrm.get_river_combos(m_hero, m_hero_preflop_combos, board)};
  const std::vector<RiverCombo> villain_river_combos{
      m_rrm.get_river_combos(m_villain, m_villain_preflop_combos, board)};

  std::vector<float> utils(m_num_hero_hands);

  float win_sum{0.0f};
  const float value{static_cast<float>(node->get_pot() / 2.0)};
  std::array<float, 52> card_win_sum{};

  // Two-pointer showdown algorithm (NOT VECTORIZED)
  // Cannot vectorize because:
  //   1. Variable array indices: card_win_sum[villain_combo.hand1] requires scatter/gather
  //   2. Data-dependent loop bounds: while(hero.rank > villain.rank) is sequential
  // Assembly: scalar movss/addss operations (single float at a time)
  int j{0};
  for (std::size_t i{0}; i < hero_river_combos.size(); ++i) {
    const auto &hero_combo{hero_river_combos[i]};

    while (j < villain_river_combos.size() &&
           hero_combo.rank > villain_river_combos[j].rank) {
      const auto &villain_combo{villain_river_combos[j]};
      const float reach = villain_reach_pr[villain_combo.reach_probs_index];
      win_sum += reach;
      card_win_sum[villain_combo.hand1] += reach;
      card_win_sum[villain_combo.hand2] += reach;
      j++;
    }

    utils[hero_combo.reach_probs_index] =
        value * (win_sum - card_win_sum[hero_combo.hand1] -
                 card_win_sum[hero_combo.hand2]);
  }

  float lose_sum{0.0f};
  std::array<float, 52> card_lose_sum{};
  j = static_cast<int>(villain_river_combos.size()) - 1;
  for (int i{static_cast<int>(hero_river_combos.size()) - 1}; i >= 0; i--) {
    const auto &hero_combo{hero_river_combos[i]};

    while (j >= 0 && hero_combo.rank < villain_river_combos[j].rank) {
      const auto &villain_combo{villain_river_combos[j]};
      const float reach = villain_reach_pr[villain_combo.reach_probs_index];
      lose_sum += reach;
      card_lose_sum[villain_combo.hand1] += reach;
      card_lose_sum[villain_combo.hand2] += reach;
      j--;
    }

    utils[hero_combo.reach_probs_index] -=
        value * (lose_sum - card_lose_sum[hero_combo.hand1] -
                 card_lose_sum[hero_combo.hand2]);
  }

  return utils;
}
auto CFRHelper::get_uncontested_utils(
    const TerminalNode *node, const std::vector<float> &villain_reach_pr,
    const std::vector<Card> &board) -> std::vector<float> {
  const bool hero_last = (m_hero == node->get_last_to_act());
  const float value =
      hero_last ? -0.5f * node->get_pot() : 0.5f * node->get_pot();

  float p_total = 0.0f;
  std::array<float, 52> sum_with_card{};
  for (size_t v = 0; v < m_num_villain_hands; ++v) {
    const auto &vc = m_villain_preflop_combos[v];
    if (CardUtility::overlap(vc, board))
      continue;
    const float pr = villain_reach_pr[v];
    p_total += pr;
    sum_with_card[vc.hand1] += pr;
    sum_with_card[vc.hand2] += pr;
  }

  std::vector<float> utils(m_num_hero_hands, 0.0f);
  for (size_t h = 0; h < m_num_hero_hands; ++h) {
    const auto &hc = m_hero_preflop_combos[h];
    if (CardUtility::overlap(hc, board))
      continue;

    int h1 = hc.hand1, h2 = hc.hand2;
    int v_self = m_hero_to_villain[h];
    float self_pr = (v_self >= 0 ? villain_reach_pr[v_self] : 0.0f);

    float p_disjoint =
        p_total - sum_with_card[h1] - sum_with_card[h2] + self_pr;

    utils[h] = value * p_disjoint;
  }

  return utils;
}
