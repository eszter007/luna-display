#!/bin/bash
# Double-clickable build: runs make-apps.sh in a Terminal window and leaves
# the two apps in the dist folder next to this file.
cd "$(dirname "$0")"
/bin/bash make-apps.sh
status=$?
echo
if [ $status -eq 0 ]; then
  echo "Done — LunaSender.app and LunaReceiver.app are in the dist folder."
else
  echo "The build failed — see the messages above."
fi
read -r -n 1 -s -p "Press any key to close this window..."
echo
exit $status
