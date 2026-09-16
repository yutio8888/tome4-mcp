#!/usr/bin/env bash
# Print the current map window as structured JSON so it can be filtered with jq.
# Shape: {"ok":true,"result":{"x":..,"y":..,"width":..,"height":..,"rows":[..],
#         "legend":{..},"exits":[{"x":..,"y":..,"name":..,"char":..}],
#         "cells":[{"x":..,"y":..,"char":..,"known":..,"visible":..,"name":..,"blocked":..,
#                   "door":..,"is_exit":..}]}}
# Usage: mapjson.sh | jq -c '.result.exits'
set -eu
dir=/workspace/t-engine4/tmp/mcp-play-support
exec "$dir/send.sh" '{"map":true}'
