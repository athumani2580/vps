# 1. Save the script
echo '#!/bin/bash
echo "Enter token:"
read token
bash <(curl -s -H "Authorization: token \$token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/1.sh")' > installer.sh

# 2. Host it anywhere (GitHub Gist, Pastebin, your server)
# 3. Share link: bash <(curl -s YOUR_LINK)
