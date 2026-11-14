#!/bin/zsh
# Nightly (launchd job, label from engine/local.py nightly_label; 04:30): review of yesterday's logs, then the weekly retrain if it is due
# and the Mac is idle and on power (bench/retrain.py decides). Output in data/review/nightly.log.
cd "${0:A:h:h}"
# launchd gives PATH=/usr/bin:/bin:/usr/sbin:/sbin; beeper (npm), gam and claude live outside it (8 November: no Beeper lines)
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
y=$(date -u -v-1d +%Y-%m-%d)
# Logs: app.log keeps 14 days, older lines and big engine logs go gzipped to data/logs/ (8 weeks)
.venv/bin/python scripts/rotate_logs.py
# Includes the optional daily Contacts refresh; missing/slow GAM keeps its cached snapshot.
# his writing as one dated corpus (typed, takes, Claude Code and Codex prompts, Beeper, Voice Notes): training lines,
# phrase memory and the word finisher read it (bench/corpus.py)
.venv/bin/python bench/corpus.py > /dev/null
.venv/bin/python engine/know.py build
.venv/bin/python bench/review.py "$y" > /dev/null
.venv/bin/python bench/retrain.py
# Fridays: the weekly page (data/review/week-*.md)
[[ $(date +%u) == 5 ]] && .venv/bin/python bench/week.py > /dev/null
