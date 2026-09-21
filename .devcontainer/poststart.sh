#!/bin/bash
# Copyright 2025 Carnegie Mellon University. All Rights Reserved.
# Released under a MIT (SEI)-style license. See LICENSE.md in the project root for license information.

claude update &

if [ -x /home/vscode/.local/bin/codex ]; then
  /home/vscode/.local/bin/codex update &
fi

# Optionally start the t3code server so the t3client on a developer's own machine can
# pair with this container over forwarded port 3939. Opt-in per developer via
# CRUCIBLE_ENABLE_T3 (set on the host); off by default because not everyone uses t3code.
# Direct LAN pairing only — no cloud relay, no account login. Pair with `t3 pair`.
case "${CRUCIBLE_ENABLE_T3:-}" in
  "" | 0 | false | no) ;;
  *)
    if ! pgrep -f 't3 serve' >/dev/null 2>&1; then
      echo "Starting t3code server on 0.0.0.0:3939 (CRUCIBLE_ENABLE_T3 set)..."
      mkdir -p "$HOME/.t3"
      nohup t3 serve --mode web --host 0.0.0.0 --port 3939 --no-browser \
        >"$HOME/.t3/serve.log" 2>&1 &
    fi
    ;;
esac

scripts/sync-repos.sh --pull

# Welcome message
cat <<'EOF'

                         @@@@
                       @@@@@@@@
                     @@@@@@@@@@@@
                    @@@@@@@@@@@@@@@
                  @@@@@@@@@@@@@@@@@@@
                @@@@@@           @@@@@@
              @@@@@                 @@@@
            @@@@@                   @@@@@@
          @@@@@@         @@@@@     @@@@@@@@@
         @@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@
       @@@@@@@@      @@@@@@@@@@@@@@@@@@@@@@@@@@
      @@@@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@
      @@@@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@
     @@@@@@@@@@      @@@@@@@@@@@@@@@@@@@@@@@@@@@
     @@@@@@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@@
     @@@@@@@@@@@         @@@@@     @@@@@@@@@@
     @@@@@@@@@@@@                   @@@@@@@
     @@@@@@@@@@@@@@                 @@@@@
      @@@@@@@@@@@@@@@@           @@@@@@
       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@
          @@@@@@@@@@@@@@@@@@@@@@@@
            @@@@@@@@@@@@@@@@@@@@
               @@@@@@@@@@@@@@

      Welcome to the Crucible Dev Container!

Getting started:
  - Open Run and Debug (Ctrl+Shift+D) to select a launch profile or press F5
    to run the Default or last selected profile.
  - Default admin credentials: admin / admin
  - See the README for more details.

Type Ctrl-Shift-` (backtick) to open a new terminal.

EOF
