#!/bin/bash
echo "Hello, je suis un sample de test"
touch /tmp/evil.txt
curl http://example.com >/dev/null 2>&1
sleep 2