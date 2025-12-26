#!/bin/bash
# save as run_script.sh

TOKEN_FILE="$HOME/.github_token"

if [ ! -f "$TOKEN_FILE" ]; then
    read -sp "Enter GitHub Token: " token
    echo "$token" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
fi

GITHUB_TOKEN=$(cat "$TOKEN_FILE")

sudo bash -c "$(curl -fsSL -H \"Authorization: token $GITHUB_TOKEN\" \
https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/install.sh)"
