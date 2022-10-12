#!/usr/bin/env bash

# Environment variables that need to be available:
# * PROJECT
# * ENVIRONMENT

# Build up all required variables.
DRUSH_ALIAS="@${PROJECT}.${ENVIRONMENT}"
# Project root is a known path on Acquia Cloud.
PROJECT_ROOT="/var/www/html/${PROJECT}.${ENVIRONMENT}"
DRUSH_PATH=${PROJECT_ROOT}/vendor/bin/drush
FILE_CONFIG=${PROJECT_ROOT}/letsencrypt_drupal/config_${PROJECT}.${ENVIRONMENT}.sh
DIRECTORY_DEHYDRATED_CONFIG=${PROJECT_ROOT}/letsencrypt_drupal/dehydrated
FILE_DOMAINSTXT=${PROJECT_ROOT}/letsencrypt_drupal/domains_${PROJECT}.${ENVIRONMENT}.txt
DEHYDRATED="https://github.com/dehydrated-io/dehydrated.git"
CERT_DIR=~/.letsencrypt_drupal
TMP_DIR=/tmp/letsencrypt_drupal
FILE_BASECONFIG=${TMP_DIR}/baseconfig

# Detect core version
DRUPAL_VERSION="9"
if grep -q -r -i --include Drupal.php "const version = '8" ${PROJECT_ROOT}; then DRUPAL_VERSION="8"; fi
if grep -q -r -i --include bootstrap.inc "define('VERSION', '" ${PROJECT_ROOT}; then DRUPAL_VERSION="7"; fi

# Load all variables provided by the project.
. ${FILE_CONFIG}

#---------------------------------------------------------------------
acquire_lock_or_exit()
{
  # Check we are not running already: http://mywiki.wooledge.org/BashFAQ/045
  # @ToDo: Platform specific lock.
  exec 8>/tmp/cert_renew_lock
  if ! flock -n 8  ; then
    logline "Another instance of this script running.";
    exit 1
  fi
  # This now runs under the lock until 8 is closed (it will be closed automatically when the script ends)
}

#---------------------------------------------------------------------
slackpost()
{
  # Can either be one of 'good', 'warning', 'danger', or any hex color code
  COLOR="${2}"
  USERNAME="${3}"
  TEXT="${4}"

  if [[ "$SLACK_WEBHOOK_URL" =~ ^https:\/\/hooks.slack.com* ]]; then
    # based on https://gist.github.com/dopiaza/6449505
    escapedText=$(echo $TEXT | sed 's/"/\"/g' | sed "s/'/\'/g")
    json="{\"channel\": \"$SLACK_CHANNEL\", \"username\":\"$USERNAME\", \"icon_emoji\":\"ghost\", \"attachments\":[{\"color\":\"$COLOR\" , \"text\": \"$escapedText\"}]}"
    curl -s -d "payload=$json" "$SLACK_WEBHOOK_URL" || logline "Failed to send message to slack: ${USERNAME}: ${TEXT}"
  else
    logline "No Slack: ${USERNAME}: ${TEXT}"
  fi
}

#---------------------------------------------------------------------
logline()
{
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

#---------------------------------------------------------------------
cd_or_exit()
{
  rv=0
  cd "$1" || rv=$?
  if [ $rv -ne 0 ]; then
    logline "Failed to cd into $1 directory. exiting."
    exit 31
  fi
}

#---------------------------------------------------------------------
drush_set_challenge()
{
  DRUSH_ALIAS="${1}"
  DRUPAL_VERSION="${2}"
  DOMAIN="${3}"
  TOKEN_VALUE="${4}"

  if [[ "${DRUPAL_VERSION}" == "7" ]]; then
    echo "EXECUTING: drush8 ${DRUSH_ALIAS} en -y --uri=${DOMAIN} letsencrypt_challenge"
    drush8 ${DRUSH_ALIAS} en -y --uri=${DOMAIN} letsencrypt_challenge
    echo "EXECUTING: drush8 ${DRUSH_ALIAS} vset -y --uri=${DOMAIN} letsencrypt_challenge \"${TOKEN_VALUE}\""
    echo "$TOKEN_VALUE" | drush8 ${DRUSH_ALIAS} vset -y --uri=${DOMAIN} letsencrypt_challenge -
    echo "EXECUTING: drush8 ${DRUSH_ALIAS} vset -y --uri=${DOMAIN} letsencrypt_challenge.${DOMAIN} \"${TOKEN_VALUE}\""
    echo "$TOKEN_VALUE" | drush8 ${DRUSH_ALIAS} vset -y --uri=${DOMAIN} letsencrypt_challenge.${DOMAIN} -
  elif [[ "${DRUPAL_VERSION}" == "8" ]]; then
    echo "EXECUTING: drush9 ${DRUSH_ALIAS} en -y --uri=${DOMAIN} letsencrypt_challenge"
    drush9 ${DRUSH_ALIAS} en -y --uri=${DOMAIN} letsencrypt_challenge
    echo "EXECUTING: drush9 ${DRUSH_ALIAS} sset -y --uri=${DOMAIN} letsencrypt_challenge.challenge \"${TOKEN_VALUE}\""
    echo "$TOKEN_VALUE" | drush9 ${DRUSH_ALIAS} sset -y --uri=${DOMAIN} letsencrypt_challenge.challenge -
    echo "EXECUTING: drush9 ${DRUSH_ALIAS} sset -y --uri=${DOMAIN} letsencrypt_challenge.challenge.${DOMAIN} \"${TOKEN_VALUE}\""
    echo "$TOKEN_VALUE" | drush9 ${DRUSH_ALIAS} sset -y --uri=${DOMAIN} letsencrypt_challenge.challenge.${DOMAIN} -
  elif [[ "${DRUPAL_VERSION}" == "9" ]]; then
    echo "EXECUTING: ${DRUSH_PATH} ${DRUSH_ALIAS} en -y --uri=${DOMAIN} letsencrypt_challenge"
    ${DRUSH_PATH} ${DRUSH_ALIAS} en -y --uri=${DOMAIN} letsencrypt_challenge
    # Since all of our domains point to the same root, we need to set multiple as per
    # https://www.drupal.org/project/letsencrypt_challenge/issues/2976683
    PRIOR_VALUE=$(${DRUSH_PATH} ${DRUSH_ALIAS} sget --uri=${DOMAIN} letsencrypt_challenge.challenge --format=list)
    echo "PRIOR_VALUE: ${PRIOR_VALUE}"
    # Set the new value as the PRIOR_VALUE + TOKEN_VALUE (the lack of indent MATTERS here).
    echo "EXECUTING: ${DRUSH_PATH} ${DRUSH_ALIAS} sset -y --uri=${DOMAIN} letsencrypt_challenge.challenge \"${PRIOR_VALUE}
${TOKEN_VALUE}\""
    echo "$PRIOR_VALUE
$TOKEN_VALUE" | ${DRUSH_PATH} ${DRUSH_ALIAS} sset -y --uri=${DOMAIN} letsencrypt_challenge.challenge -
  fi
}

drush_clean_challenge()
{
  DRUSH_ALIAS="${1}"
  DRUPAL_VERSION="${2}"
  DOMAIN="${3}"

  if [[ "${DRUPAL_VERSION}" == "7" ]]; then
    echo "EXECUTING: drush8 ${DRUSH_ALIAS} dis -y --uri=${DOMAIN} letsencrypt_challenge"
    drush8 ${DRUSH_ALIAS} dis -y --uri=${DOMAIN} letsencrypt_challenge
    echo "EXECUTING: drush8 ${DRUSH_ALIAS} pmu -y --uri=${DOMAIN} letsencrypt_challenge"
    drush8 ${DRUSH_ALIAS} pmu -y --uri=${DOMAIN} letsencrypt_challenge
  elif [[ "${DRUPAL_VERSION}" == "8" ]]; then
    echo "EXECUTING: drush9 ${DRUSH_ALIAS} pmu -y --uri=${DOMAIN} letsencrypt_challenge"
    drush9 ${DRUSH_ALIAS} pmu -y --uri=${DOMAIN} letsencrypt_challenge
  elif [[ "${DRUPAL_VERSION}" == "9" ]]; then
    echo "EXECUTING: ${DRUSH_PATH} ${DRUSH_ALIAS} pmu -y --uri=${DOMAIN} letsencrypt_challenge"
    ${DRUSH_PATH} ${DRUSH_ALIAS} pmu -y --uri=${DOMAIN} letsencrypt_challenge
  fi
}
