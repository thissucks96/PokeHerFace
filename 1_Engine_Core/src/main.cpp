// --------------------------------
// Created by Anubhav Parida.
// --------------------------------
#include "hands/PreflopRange.hh"
#include "solver/Solver.hh"
#include "tree/GameTree.hh"
#include "tree/Nodes.hh"
#include "trainer/DCFR.hh"
#include <nlohmann/json.hpp>

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {
using json = nlohmann::json;
using phevaluator::Card;

struct CliOptions {
  bool show_help{false};
  bool quiet{false};
  std::optional<std::string> input_path;
  std::optional<std::string> output_path;
  std::optional<std::string> node_lock_path;
};

struct SolveInput {
  std::string hero_range;
  std::string villain_range;
  std::vector<Card> board;
  int in_position_player{2};
  int starting_stack{100};
  int starting_pot{10};
  int minimum_bet{2};
  float all_in_threshold{0.67f};
  int iterations{100};
  float min_exploitability{-1.0f};
  int thread_count{0};
  bool remove_donk_bets{true};
  int raise_cap{3};
  bool compress_strategy{true};
  BetSizingConfig bet_sizing;
  std::string active_node_path{""};
};

struct ActionSummary {
  std::string action;
  int amount{0};
  float avg_frequency{0.0f};
};

struct NodeLockCatalogEntry {
  std::string node_id;
  std::string street;
  std::vector<std::string> actions;
};

struct SolveResult {
  float final_exploitability{0.0f};
  double tree_build_seconds{0.0};
  double training_seconds{0.0};
  double total_seconds{0.0};
  TreeStatistics tree_stats{};
  std::vector<ActionSummary> root_actions;
  std::vector<NodeLockCatalogEntry> node_lock_catalog;
  bool active_node_found{false};
  std::string active_node_path{""};
  std::vector<ActionSummary> active_node_actions;
};

auto default_thread_count() -> int {
  const unsigned hc = std::thread::hardware_concurrency();
  if (hc <= 1) {
    return 1;
  }
  return static_cast<int>(hc - 1);
}

auto action_to_string(const Action &action) -> std::string {
  switch (action.type) {
  case Action::FOLD:
    return "fold";
  case Action::CHECK:
    return "check";
  case Action::CALL:
    return "call";
  case Action::BET:
    return "bet";
  case Action::RAISE:
    return "raise";
  }
  return "unknown";
}

auto action_to_lock_key(const Action &action) -> std::string {
  const std::string base = action_to_string(action);
  if (action.type == Action::BET || action.type == Action::RAISE) {
    return base + ":" + std::to_string(action.amount);
  }
  return base;
}

auto street_to_string(const Street street) -> std::string {
  switch (street) {
  case Street::FLOP:
    return "flop";
  case Street::TURN:
    return "turn";
  case Street::RIVER:
    return "river";
  }
  return "flop";
}

auto street_from_board_size(const size_t size) -> Street {
  if (size >= 5) {
    return Street::RIVER;
  }
  if (size == 4) {
    return Street::TURN;
  }
  return Street::FLOP;
}

void print_usage() {
  std::cout << "shark_cli usage:\n"
            << "  shark_cli\n"
            << "    Runs built-in benchmark mode.\n\n"
            << "  shark_cli --input <spot.json> --output <result.json> [--node-lock <node_lock.json>] [--quiet]\n"
            << "    Runs headless solve mode with JSON I/O.\n\n"
            << "Options:\n"
            << "  --input      Path to solve input JSON.\n"
            << "  --output     Path to result output JSON.\n"
            << "  --node-lock  Optional node-lock JSON payload (applies matching lock targets by node_id/street).\n"
            << "  --quiet      Suppress progress logs in headless mode.\n"
            << "  --help       Show this help.\n";
}

auto parse_args(int argc, char **argv) -> CliOptions {
  CliOptions options;
  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--help" || arg == "-h") {
      options.show_help = true;
      continue;
    }
    if (arg == "--quiet") {
      options.quiet = true;
      continue;
    }
    if (arg == "--input" || arg == "--output" || arg == "--node-lock") {
      if (i + 1 >= argc) {
        throw std::runtime_error("Missing value for argument: " + arg);
      }
      std::string value = argv[++i];
      if (arg == "--input") {
        options.input_path = value;
      } else if (arg == "--output") {
        options.output_path = value;
      } else {
        options.node_lock_path = value;
      }
      continue;
    }
    throw std::runtime_error("Unknown argument: " + arg);
  }

  if (options.input_path.has_value() != options.output_path.has_value()) {
    throw std::runtime_error("Headless mode requires both --input and --output.");
  }

  if (!options.input_path.has_value() && options.node_lock_path.has_value()) {
    throw std::runtime_error("--node-lock can only be used with --input/--output.");
  }

  return options;
}

auto read_json_file(const std::string &path) -> json {
  std::ifstream in(path);
  if (!in.is_open()) {
    throw std::runtime_error("Unable to open JSON file: " + path);
  }
  json payload;
  in >> payload;
  return payload;
}

void write_json_file(const std::string &path, const json &payload) {
  const std::filesystem::path out_path(path);
  if (!out_path.parent_path().empty()) {
    std::filesystem::create_directories(out_path.parent_path());
  }
  std::ofstream out(path);
  if (!out.is_open()) {
    throw std::runtime_error("Unable to write JSON file: " + path);
  }
  out << payload.dump(2) << '\n';
}

auto parse_cards(const json &board_json) -> std::vector<Card> {
  if (!board_json.is_array()) {
    throw std::runtime_error("spot.json 'board' must be an array.");
  }

  if (board_json.size() < 3 || board_json.size() > 5) {
    throw std::runtime_error("spot.json 'board' must have 3 to 5 cards.");
  }

  std::vector<Card> board;
  board.reserve(board_json.size());
  for (const auto &value : board_json) {
    if (!value.is_string()) {
      throw std::runtime_error("spot.json 'board' entries must be strings (example: \"Ks\").");
    }
    const std::string card_str = value.get<std::string>();
    if (card_str.size() < 2) {
      throw std::runtime_error("Invalid board card: " + card_str);
    }
    board.emplace_back(card_str);
  }
  return board;
}

auto parse_float_vec(const json &arr, const std::string &key_name) -> std::vector<float> {
  if (!arr.is_array()) {
    throw std::runtime_error(key_name + " must be an array.");
  }
  std::vector<float> out;
  out.reserve(arr.size());
  for (const auto &v : arr) {
    if (!v.is_number()) {
      throw std::runtime_error(key_name + " entries must be numeric.");
    }
    const float value = v.get<float>();
    if (value <= 0.0f) {
      throw std::runtime_error(key_name + " entries must be > 0.");
    }
    out.push_back(value);
  }
  return out;
}

void parse_street_bet_cfg(const json &cfg, StreetBetConfig &out_cfg, const std::string &street_name) {
  if (!cfg.is_object()) {
    throw std::runtime_error("spot.json bet_sizing." + street_name + " must be an object.");
  }
  if (cfg.contains("bet_sizes")) {
    out_cfg.bet_sizes = parse_float_vec(cfg.at("bet_sizes"), "spot.json bet_sizing." + street_name + ".bet_sizes");
  }
  if (cfg.contains("raise_sizes")) {
    out_cfg.raise_sizes =
        parse_float_vec(cfg.at("raise_sizes"), "spot.json bet_sizing." + street_name + ".raise_sizes");
  }
}

auto parse_solve_input(const json &spot) -> SolveInput {
  SolveInput input;

  if (!spot.contains("hero_range") || !spot.contains("villain_range") || !spot.contains("board")) {
    throw std::runtime_error("spot.json requires keys: hero_range, villain_range, board.");
  }

  input.hero_range = spot.at("hero_range").get<std::string>();
  input.villain_range = spot.at("villain_range").get<std::string>();
  input.board = parse_cards(spot.at("board"));

  if (spot.contains("in_position_player")) {
    input.in_position_player = spot.at("in_position_player").get<int>();
    if (input.in_position_player != 1 && input.in_position_player != 2) {
      throw std::runtime_error("spot.json in_position_player must be 1 or 2.");
    }
  }
  if (spot.contains("starting_stack")) {
    input.starting_stack = spot.at("starting_stack").get<int>();
  }
  if (spot.contains("starting_pot")) {
    input.starting_pot = spot.at("starting_pot").get<int>();
  }
  if (spot.contains("minimum_bet")) {
    input.minimum_bet = spot.at("minimum_bet").get<int>();
  }
  if (spot.contains("all_in_threshold")) {
    input.all_in_threshold = spot.at("all_in_threshold").get<float>();
  }
  if (spot.contains("iterations")) {
    input.iterations = spot.at("iterations").get<int>();
  }
  if (spot.contains("min_exploitability")) {
    input.min_exploitability = spot.at("min_exploitability").get<float>();
  }
  if (spot.contains("thread_count")) {
    input.thread_count = spot.at("thread_count").get<int>();
  }
  if (spot.contains("remove_donk_bets")) {
    input.remove_donk_bets = spot.at("remove_donk_bets").get<bool>();
  }
  if (spot.contains("raise_cap")) {
    input.raise_cap = spot.at("raise_cap").get<int>();
  }
  if (spot.contains("compress_strategy")) {
    input.compress_strategy = spot.at("compress_strategy").get<bool>();
  }
  if (spot.contains("active_node_path")) {
    if (!spot.at("active_node_path").is_string()) {
      throw std::runtime_error("spot.json active_node_path must be a string.");
    }
    input.active_node_path = spot.at("active_node_path").get<std::string>();
  }

  if (spot.contains("bet_sizing")) {
    const json &bet_cfg = spot.at("bet_sizing");
    if (!bet_cfg.is_object()) {
      throw std::runtime_error("spot.json bet_sizing must be an object.");
    }
    if (bet_cfg.contains("flop")) {
      parse_street_bet_cfg(bet_cfg.at("flop"), input.bet_sizing.flop, "flop");
    }
    if (bet_cfg.contains("turn")) {
      parse_street_bet_cfg(bet_cfg.at("turn"), input.bet_sizing.turn, "turn");
    }
    if (bet_cfg.contains("river")) {
      parse_street_bet_cfg(bet_cfg.at("river"), input.bet_sizing.river, "river");
    }
  }

  if (input.thread_count <= 0) {
    input.thread_count = default_thread_count();
  }

  if (input.starting_stack <= 0 || input.starting_pot <= 0 || input.minimum_bet <= 0) {
    throw std::runtime_error("spot.json stack/pot/minimum_bet must be > 0.");
  }
  if (input.iterations <= 0) {
    throw std::runtime_error("spot.json iterations must be > 0.");
  }
  if (input.all_in_threshold <= 0.0f || input.all_in_threshold > 1.0f) {
    throw std::runtime_error("spot.json all_in_threshold must be in (0,1].");
  }

  return input;
}

auto parse_node_lock_target(const json &payload) -> NodeLockTarget {
  if (!payload.is_object()) {
    throw std::runtime_error("node_lock target must be an object.");
  }

  NodeLockTarget target;
  if (payload.contains("node_id") && payload.at("node_id").is_string()) {
    target.node_id = payload.at("node_id").get<std::string>();
  } else {
    target.node_id = "root";
  }
  if (payload.contains("street") && payload.at("street").is_string()) {
    target.street = payload.at("street").get<std::string>();
  }
  if (payload.contains("confidence") && payload.at("confidence").is_number()) {
    target.confidence = payload.at("confidence").get<float>();
  }

  if (payload.contains("locks")) {
    if (!payload.at("locks").is_array()) {
      throw std::runtime_error("node_lock target 'locks' must be an array.");
    }
    for (const auto &item : payload.at("locks")) {
      if (!item.is_object()) {
        continue;
      }
      if (!item.contains("action") || !item.contains("frequency")) {
        continue;
      }
      NodeLockItem lock;
      lock.action = item.at("action").get<std::string>();
      lock.frequency = item.at("frequency").get<float>();
      if (lock.frequency < 0.0f || lock.frequency > 1.0f) {
        throw std::runtime_error("node_lock lock frequency must be in [0,1].");
      }
      if (item.contains("notes") && item.at("notes").is_string()) {
        lock.notes = item.at("notes").get<std::string>();
      }
      target.locks.push_back(lock);
    }
  }
  return target;
}

auto parse_node_lock(const std::optional<std::string> &node_lock_path) -> NodeLockData {
  NodeLockData lock_data;
  if (!node_lock_path.has_value()) {
    return lock_data;
  }
  lock_data.provided = true;

  const json payload = read_json_file(node_lock_path.value());
  if (!payload.is_object()) {
    throw std::runtime_error("node_lock.json must be an object.");
  }

  if (payload.contains("node_locks")) {
    if (!payload.at("node_locks").is_array()) {
      throw std::runtime_error("node_lock.json 'node_locks' must be an array.");
    }
    for (const auto &entry : payload.at("node_locks")) {
      NodeLockTarget target = parse_node_lock_target(entry);
      if (!target.locks.empty()) {
        lock_data.targets.push_back(std::move(target));
      }
    }
  } else {
    NodeLockTarget target = parse_node_lock_target(payload);
    if (!target.locks.empty()) {
      lock_data.targets.push_back(std::move(target));
    }
  }

  return lock_data;
}

auto summarize_action_node(Node *node) -> std::vector<ActionSummary> {
  std::vector<ActionSummary> summary;
  if (!node || node->get_node_type() != NodeType::ACTION_NODE) {
    return summary;
  }

  auto *action_node = dynamic_cast<ActionNode *>(node);
  if (!action_node) {
    return summary;
  }

  const std::vector<float> avg = action_node->get_average_strat();
  const int num_hands = action_node->get_num_hands();
  const int num_actions = action_node->get_num_actions();
  if (num_hands <= 0 || num_actions <= 0 || avg.empty()) {
    return summary;
  }

  summary.reserve(static_cast<size_t>(num_actions));
  for (int a = 0; a < num_actions; ++a) {
    float freq_sum = 0.0f;
    for (int h = 0; h < num_hands; ++h) {
      const size_t idx = static_cast<size_t>(h + a * num_hands);
      if (idx < avg.size()) {
        freq_sum += avg[idx];
      }
    }

    ActionSummary item;
    item.action = action_to_string(action_node->get_action(a));
    item.amount = action_node->get_action(a).amount;
    item.avg_frequency = freq_sum / static_cast<float>(num_hands);
    summary.push_back(item);
  }

  return summary;
}

auto summarize_root_actions(Node *root) -> std::vector<ActionSummary> {
  return summarize_action_node(root);
}

auto find_node_by_id(Node *node, const std::string &target_id) -> Node * {
  if (!node) {
    return nullptr;
  }

  if (node->get_node_type() == NodeType::ACTION_NODE) {
    auto *action_node = dynamic_cast<ActionNode *>(node);
    if (!action_node) {
      return nullptr;
    }
    if (action_node->get_node_id() == target_id) {
      return node;
    }
    for (int i = 0; i < action_node->get_num_actions(); ++i) {
      if (Node *found = find_node_by_id(action_node->get_child(i), target_id)) {
        return found;
      }
    }
    return nullptr;
  }

  if (node->get_node_type() == NodeType::CHANCE_NODE) {
    auto *chance_node = dynamic_cast<ChanceNode *>(node);
    if (!chance_node) {
      return nullptr;
    }
    for (int i = 0; i < 52; ++i) {
      if (!chance_node->get_child(i)) {
        continue;
      }
      if (Node *found = find_node_by_id(chance_node->get_child(i), target_id)) {
        return found;
      }
    }
  }

  return nullptr;
}

void collect_node_lock_catalog(Node *node, Street street, size_t limit,
                               std::vector<NodeLockCatalogEntry> &out) {
  if (!node || out.size() >= limit) {
    return;
  }

  if (node->get_node_type() == NodeType::ACTION_NODE) {
    auto *action_node = dynamic_cast<ActionNode *>(node);
    if (!action_node) {
      return;
    }

    NodeLockCatalogEntry entry;
    entry.node_id = action_node->get_node_id();
    entry.street = street_to_string(street);
    entry.actions.reserve(static_cast<size_t>(action_node->get_num_actions()));
    for (int i = 0; i < action_node->get_num_actions(); ++i) {
      entry.actions.push_back(action_to_lock_key(action_node->get_action(i)));
    }
    out.push_back(std::move(entry));
    if (out.size() >= limit) {
      return;
    }

    for (int i = 0; i < action_node->get_num_actions(); ++i) {
      collect_node_lock_catalog(action_node->get_child(i), street, limit, out);
      if (out.size() >= limit) {
        return;
      }
    }
    return;
  }

  if (node->get_node_type() == NodeType::CHANCE_NODE) {
    auto *chance_node = dynamic_cast<ChanceNode *>(node);
    if (!chance_node) {
      return;
    }
    const Street next_street =
        chance_node->get_type() == ChanceNode::ChanceType::DEAL_TURN ? Street::TURN : Street::RIVER;
    for (int i = 0; i < 52; ++i) {
      if (!chance_node->get_child(i)) {
        continue;
      }
      collect_node_lock_catalog(chance_node->get_child(i), next_street, limit, out);
      if (out.size() >= limit) {
        return;
      }
    }
  }
}

auto run_solve(const SolveInput &input, NodeLockData *node_lock, bool verbose) -> SolveResult {
  SolveResult result;

  PreflopRange range1{input.hero_range};
  PreflopRange range2{input.villain_range};
  if (range1.num_hands <= 0 || range2.num_hands <= 0) {
    throw std::runtime_error("One of the preflop ranges produced zero combos.");
  }

  if (verbose) {
    std::cout << "Range1: " << range1.num_hands << " combos\n";
    std::cout << "Range2: " << range2.num_hands << " combos\n";
    std::cout << "Board:";
    for (const auto &card : input.board) {
      std::cout << " " << card.describeCard();
    }
    std::cout << "\n";
  }

  TreeBuilderSettings settings{
      range1, range2, input.in_position_player, input.board, input.starting_stack, input.starting_pot,
      input.minimum_bet, input.all_in_threshold};
  settings.remove_donk_bets = input.remove_donk_bets;
  settings.raise_cap = input.raise_cap;
  settings.bet_sizing = input.bet_sizing;

  DCFR::compress_strategy = input.compress_strategy;

  if (verbose) {
    std::cout << "\nBuilding tree...\n";
  }
  const auto t0 = std::chrono::high_resolution_clock::now();

  PreflopRangeManager prm{range1.preflop_combos, range2.preflop_combos, input.board};
  GameTree game_tree{settings};
  std::unique_ptr<Node> root{game_tree.build()};

  result.tree_stats = game_tree.getTreeStats();

  const auto t1 = std::chrono::high_resolution_clock::now();
  result.tree_build_seconds = std::chrono::duration<double>(t1 - t0).count();

  if (verbose) {
    std::cout << "Action nodes: " << result.tree_stats.total_action_nodes << "\n";
    std::cout << "Est. memory: " << (result.tree_stats.estimateMemoryBytes() / 1024 / 1024) << " MB\n";
    std::cout << "Tree built in " << result.tree_build_seconds << "s\n\n";
    std::cout << "Training " << input.iterations << " iterations...\n";
    std::cout << "Using " << input.thread_count << " threads\n";
  }

  ParallelDCFR trainer{prm, input.board, input.starting_pot, input.in_position_player, input.thread_count, node_lock};
  BestResponse br{prm};

  trainer.train(root.get(), input.iterations, input.min_exploitability,
                [&](int i, int total, float exploit) {
                  if (!verbose) {
                    return;
                  }
                  if (i % 20 == 0 || i == total) {
                    const auto now = std::chrono::high_resolution_clock::now();
                    const double elapsed = std::chrono::duration<double>(now - t1).count();
                    std::cout << "Iter " << i << "/" << total << " - " << std::fixed << std::setprecision(1) << elapsed
                              << "s";
                    if (exploit >= 0) {
                      std::cout << " - Exploit: " << std::setprecision(2) << exploit << "%";
                    }
                    std::cout << "\n";
                  }
                });

  const auto t2 = std::chrono::high_resolution_clock::now();
  result.training_seconds = std::chrono::duration<double>(t2 - t1).count();
  result.total_seconds = std::chrono::duration<double>(t2 - t0).count();
  result.final_exploitability =
      br.get_exploitability(root.get(), input.iterations, input.board, input.starting_pot, input.in_position_player);
  result.root_actions = summarize_root_actions(root.get());
  collect_node_lock_catalog(root.get(), street_from_board_size(input.board.size()), 128, result.node_lock_catalog);
  if (!input.active_node_path.empty()) {
    result.active_node_path = input.active_node_path;
    if (Node *target_node = find_node_by_id(root.get(), input.active_node_path)) {
      result.active_node_found = true;
      result.active_node_actions = summarize_action_node(target_node);
    } else {
      result.active_node_found = false;
    }
  }

  if (verbose) {
    std::cout << "\n=== Results ===\n";
    std::cout << "Final exploitability: " << std::fixed << std::setprecision(3) << result.final_exploitability
              << "%\n";
    std::cout << "Training time: " << std::setprecision(1) << result.training_seconds << "s\n";
    std::cout << "Total time: " << result.total_seconds << "s\n";
  }

  return result;
}

auto solve_input_to_json(const SolveInput &input) -> json {
  json board = json::array();
  for (const auto &c : input.board) {
    board.push_back(c.describeCard());
  }

  return json{
      {"hero_range", input.hero_range},
      {"villain_range", input.villain_range},
      {"board", board},
      {"in_position_player", input.in_position_player},
      {"starting_stack", input.starting_stack},
      {"starting_pot", input.starting_pot},
      {"minimum_bet", input.minimum_bet},
      {"all_in_threshold", input.all_in_threshold},
      {"iterations", input.iterations},
      {"min_exploitability", input.min_exploitability},
      {"thread_count", input.thread_count},
      {"remove_donk_bets", input.remove_donk_bets},
      {"raise_cap", input.raise_cap},
      {"compress_strategy", input.compress_strategy},
      {"active_node_path", input.active_node_path},
      {"bet_sizing",
       {{"flop", {{"bet_sizes", input.bet_sizing.flop.bet_sizes}, {"raise_sizes", input.bet_sizing.flop.raise_sizes}}},
        {"turn", {{"bet_sizes", input.bet_sizing.turn.bet_sizes}, {"raise_sizes", input.bet_sizing.turn.raise_sizes}}},
        {"river",
         {{"bet_sizes", input.bet_sizing.river.bet_sizes}, {"raise_sizes", input.bet_sizing.river.raise_sizes}}}}}};
}

auto solve_result_to_json(const SolveResult &result, const SolveInput &input, const NodeLockData &lock_data) -> json {
  json root_actions = json::array();
  for (const auto &action : result.root_actions) {
    root_actions.push_back(
        {{"action", action.action}, {"amount", action.amount}, {"avg_frequency", action.avg_frequency}});
  }

  json active_node_actions = json::array();
  for (const auto &action : result.active_node_actions) {
    active_node_actions.push_back(
        {{"action", action.action}, {"amount", action.amount}, {"avg_frequency", action.avg_frequency}});
  }

  json node_lock_catalog = json::array();
  for (const auto &entry : result.node_lock_catalog) {
    node_lock_catalog.push_back(
        {{"node_id", entry.node_id}, {"street", entry.street}, {"actions", entry.actions}});
  }

  json warnings = json::array();
  if (lock_data.provided && !lock_data.applied) {
    warnings.push_back("node_lock payload was provided but no matching lock target was applied.");
  }

  json node_lock_targets = json::array();
  for (const auto &target : lock_data.targets) {
    node_lock_targets.push_back(
        {{"node_id", target.node_id},
         {"street", target.street},
         {"lock_count", target.locks.size()},
         {"confidence", target.confidence},
         {"applied", target.applied},
         {"applications", target.applications}});
  }

  std::string first_node_id;
  std::string first_street;
  size_t first_lock_count = 0;
  if (!lock_data.targets.empty()) {
    first_node_id = lock_data.targets.front().node_id;
    first_street = lock_data.targets.front().street;
    first_lock_count = lock_data.targets.front().locks.size();
  }

  return json{
      {"schema_version", "1.0"},
      {"status", "ok"},
      {"input", solve_input_to_json(input)},
      {"node_lock",
       {{"provided", lock_data.provided},
        {"applied", lock_data.applied},
        {"node_id", first_node_id},
        {"street", first_street},
        {"lock_count", first_lock_count},
        {"target_count", lock_data.targets.size()},
        {"applications", lock_data.applications},
        {"targets", node_lock_targets}}},
      {"tree_stats",
       {{"total_action_nodes", result.tree_stats.total_action_nodes},
        {"flop_action_nodes", result.tree_stats.flop_action_nodes},
        {"turn_action_nodes", result.tree_stats.turn_action_nodes},
        {"river_action_nodes", result.tree_stats.river_action_nodes},
        {"chance_nodes", result.tree_stats.chance_nodes},
        {"terminal_nodes", result.tree_stats.terminal_nodes},
        {"estimated_memory_bytes", result.tree_stats.estimateMemoryBytes()},
        {"p1_num_hands", result.tree_stats.p1_num_hands},
        {"p2_num_hands", result.tree_stats.p2_num_hands}}},
      {"timing_seconds",
       {{"tree_build", result.tree_build_seconds},
        {"training", result.training_seconds},
        {"total", result.total_seconds}}},
      {"final_exploitability_pct", result.final_exploitability},
      {"root_actions", root_actions},
      {"active_node_path", result.active_node_path},
      {"active_node_found", result.active_node_found},
      {"active_node_actions", active_node_actions},
      {"node_lock_catalog", node_lock_catalog},
      {"warnings", warnings}};
}

auto benchmark_input() -> SolveInput {
  SolveInput input;
  input.hero_range = "55+,A2s+,K7s+,Q8s+,J8s+,T8s+,97s+,87s,76s,A9o+,KTo+,QJo";
  input.villain_range = "33+,A2s+,K2s+,Q5s+,J7s+,T7s+,96s+,85s+,75s+,64s+,A5o+,K9o+,Q9o+,J9o+,T9o";
  input.board = {Card{"Ks"}, Card{"Qh"}, Card{"7d"}};
  input.in_position_player = 2;
  input.starting_stack = 100;
  input.starting_pot = 10;
  input.minimum_bet = 2;
  input.all_in_threshold = 0.67f;
  input.iterations = 100;
  input.min_exploitability = -1.0f;
  input.thread_count = 14;
  input.remove_donk_bets = true;
  input.raise_cap = 3;
  input.compress_strategy = true;
  return input;
}
} // namespace

int main(int argc, char **argv) {
  try {
    const CliOptions options = parse_args(argc, argv);
    if (options.show_help) {
      print_usage();
      return 0;
    }

    if (!options.input_path.has_value()) {
      std::cout << "=== Flop Solve Benchmark ===\n";
      const SolveInput input = benchmark_input();
      (void)run_solve(input, nullptr, true);
      return 0;
    }

    const json spot = read_json_file(options.input_path.value());
    const SolveInput input = parse_solve_input(spot);
    NodeLockData node_lock = parse_node_lock(options.node_lock_path);
    const SolveResult result = run_solve(input, &node_lock, !options.quiet);
    const json out = solve_result_to_json(result, input, node_lock);
    write_json_file(options.output_path.value(), out);

    if (!options.quiet) {
      std::cout << "Wrote result JSON to: " << options.output_path.value() << "\n";
    }
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "shark_cli error: " << e.what() << "\n";
    return 1;
  }
}
