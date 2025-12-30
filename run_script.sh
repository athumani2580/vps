export GITHUB_TOKEN="your-new-token-here"
curl -H "Authorization: token $GITHUB_TOKEN" \
  -L https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/1.sh \
  -o install.sh
