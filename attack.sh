#!/bin/bash
source ~/agentbox/.env
run() {
  echo "=== $1"
  P=$(python3 -c 'import json,sys; print(json.dumps({"action":"run","cmd":sys.argv[1],"timeout":int(sys.argv[2])}))' "$2" "${3:-10}")
  curl -s -m 100 -X POST "$AGENTBOX_URL" -H "x-api-key: $API_KEY" -H "Content-Type: application/json" -d "$P"; echo; echo
}
CRED='python3 -c "import os,json,urllib.request as r; print(json.load(r.urlopen(\"http://169.254.170.2\"+os.environ[\"AWS_CONTAINER_CREDENTIALS_RELATIVE_URI\"]))[\"RoleArn\"])"'
NET='python3 -c "import urllib.request as r; print(r.urlopen(\"https://example.com\",timeout=5).status)"'
run "1. Write to the root filesystem" "touch /app/pwned"
run "2. Credential theft: which role do I get?" "$CRED"
run "3. Data exfiltration: reach the internet" "$NET"
run "4. Fork bomb" ':(){ :|:& };:' 8
