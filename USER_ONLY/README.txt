USER_ONLY script guide
======================

This folder contains the small set of scripts you should run directly.
Each file here is a thin wrapper around the real script in the repo.

Run these from the repo root or by double-clicking/opening them from this folder.

Files
-----

01_run_broad_tail_away.ps1
- Best "leave the PC running" script right now.
- Starts/checks the bridge, resumes the broad-tail offline labeler, starts the watchdog, and opens visible progress tails.
- Use this when you have spare time or are leaving for school and want the repo working on the dataset freeze blocker.

02_preflight_windows.ps1
- Quick environment sanity check.
- Use this after reboot, after setup changes, or if something feels broken before you start deeper work.

03_test_stateful_sim_fast_live.ps1
- Runs a default fast_live stateful sim.
- Use this when you want a quick "is the poker bot loop behaving normally?" check.

04_test_acceptance_turn.ps1
- Runs the turn acceptance suite with the local preset.
- Use this for a stronger targeted regression check on turn behavior.

05_test_acceptance_river.ps1
- Runs the river acceptance suite with the local preset.
- Use this for a stronger targeted regression check on river behavior.

06_tester_ui.ps1
- Launches the manual tester UI.
- Use this when you want to manually play against the 1v1 engine, inspect advice, or generate manual-vs-1v1 capture data.

07_run_hotspot_shallow_pilot.ps1
- Runs the 50-row shallow-salvage pilot for the remaining hotspot bucket.
- Use this now that broad-tail is complete and the repo is testing whether the last 646 rows can be solved with a shallower reference profile.

Notes
-----
- These wrappers do not replace the real scripts in scripts/.
- The real implementation still lives in scripts/ or the repo root.
- Right now the most important scripts in this folder are 01_run_broad_tail_away.ps1 for broad-tail burndown and 07_run_hotspot_shallow_pilot.ps1 for the remaining hotspot pilot.
