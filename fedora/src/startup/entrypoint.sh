#!/bin/bash

. "${STARTUPDIR}"/common.sh

export USER=headless

function wait_for_vnc() {
  check_vnc="vncserver -list | grep ${DISPLAY} | awk '{print \$1}'"
  echo "[INFO] Waiting for vnc server..."
  # wait until dbus file is available
  while [[ ! -f $DBUS_ENV_FILE ]]; do
    sleep 5
  done
  # wait until vnserver has started
  while [[ $(eval $check_vnc) != "$DISPLAY" ]]; do
    sleep 5
  done
}

function wait_for_keyring() {
  timeout=30
  starttime=$SECONDS
  unlock_cmd="gnome-keyring-daemon -r --unlock"
  check_cmd="busctl --user get-property org.freedesktop.secrets /org/freedesktop/secrets/collection/login org.freedesktop.Secret.Collection Locked"
  echo "[INFO] Locked:" $($check_cmd)
  # wait for keyring to unlock
  while [[ $($check_cmd) != *"false" ]]; do
    if ((SECONDS - starttime >= timeout)); then
      echo "[ERROR] Timeout waiting for keyring. Exiting..."
      exit 1
    fi
    echo "[INFO] Waiting for keyring to unlock..."

    set -e
    # try to unlock keyring again
    echo -n "${VNC_PW}" | $unlock_cmd
    sleep 1
    set +e
  done
  echo "[INFO] Keyring is ready and unlocked"
}

"${STARTUPDIR}"/vnc_startup.sh &

#maximum time to wait for licenses (before installation of squish + before running tests)
runtime="30 minute"
endtime=$(date -ud "$runtime" +%s)

result=1
installation_report="${HOME}/squish-installation.log"
echo "[SQUISH] Installing squish..."
echo "[SQUISH] Installation report: ${installation_report}"

# retry installing squish if there is an issue to connect the license server
while [[ $result -ne 0 ]]; do
  if [[ $(date -u +%s) -gt $endtime ]]; then
    echo "[SQUISH] Timeout waiting for license server"
    exit 1
  fi

  /opt/squish.run unattended=1 ide=0 doc=0 examples=0 targetdir="${HOME}"/squish licensekey="$LICENSEKEY" >>"${installation_report}" 2>&1
  result=$?

  if [[ $result -ne 0 ]]; then
    echo "[SQUISH] Waiting for license server"
    sleep $((1 + $RANDOM % 30))
  fi
done

cp "${HOME}"/squish/etc/paths.ini "${HOME}"/squish/etc/paths.ini-backup
cp "${STARTUPDIR}"/paths.ini "${HOME}"/squish/etc/

mkdir -p "${HOME}"/.squish/ver1/
cp "${SERVER_INI}" "${HOME}"/.squish/ver1/server.ini

# Set allowed core dump size to an unlimited value, needed for backtracing
ulimit -c unlimited

# Turn off the Squish crash handler by setting this environment variable
export SQUISH_NO_CRASHHANDLER=1

wait_for_vnc

# set DBUS_SESSION_BUS_ADDRESS for squishrunner terminal session
if [ -f "$DBUS_ENV_FILE" ]; then
  source $DBUS_ENV_FILE
else
  timeout=10 # seconds
  echo "[ERROR] 'DBUS_SESSION_BUS_ADDRESS' not set. Waiting for $timeout seconds..."
  sleep $timeout
  if [ -f "$DBUS_ENV_FILE" ]; then
    echo "[TIMEOUT] 'DBUS_SESSION_BUS_ADDRESS' still not set after $timeout seconds. Exiting..."
    exit 1
  fi
  source $DBUS_ENV_FILE
fi

# after dbus session is set, wait for keyring to unlock
wait_for_keyring

# start squishserver
(/home/headless/squish/bin/squishserver >>"${GUI_TEST_REPORT_DIR}"/serverlog.log 2>&1) &

# squishrunner waits itself for a license to become available, but fails with error 37 if it cannot connect to the license server
LICENSE_ERROR_RESULT_CODE=37
result=LICENSE_ERROR_RESULT_CODE
echo "[SQUISH] Starting tests..."
while true; do
  if [[ $(date -u +%s) -gt $endtime ]]; then
    echo "[SQUISH] Timeout waiting for license server"
    exit 1
  fi

  ~/squish/bin/squishrunner ${SQUISH_PARAMETERS} --reportgen stdout --exitCodeOnFail 1
  result=$?
  if [[ $result -eq $LICENSE_ERROR_RESULT_CODE ]]; then
    echo "[SQUISH] Waiting for license server"
    sleep $((1 + $RANDOM % 30))
  else
    exit $result
  fi
done
