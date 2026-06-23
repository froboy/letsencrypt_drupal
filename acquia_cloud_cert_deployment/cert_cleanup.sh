#!/usr/bin/env bash

# cert_cleanup.sh
#
# Thin shell wrapper around acquia_cloud_cert_deployment/cert_cleanup.php.
# Intended to be called from letsencrypt_drupal.sh (or directly from cron)
# after the main certificate renewal flow.
#
# Pre-conditions:
#   * functions.sh has already been sourced, so PROJECT, ENVIRONMENT, and all
#     related path/config variables are available.
#   * The project's config_<project>.<env>.sh has been sourced, so
#     CERT_DEPLOY_ENVIRONMENT_UUID, ACQUIA_API_KEY, and ACQUIA_API_SECRET are set.
#
# Optional arguments:
#   --dry-run   Pass through to cert_cleanup.php for a non-destructive preview.

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Validate required variables.
if [[ -z "${CERT_DEPLOY_ENVIRONMENT_UUID}" ]]; then
  echo "[cert_cleanup] CERT_DEPLOY_ENVIRONMENT_UUID is not set — skipping cleanup."
  exit 0
fi

CLEANUP_SCRIPT="${CURRENT_DIR}/cert_cleanup.php"

if [[ ! -f "${CLEANUP_SCRIPT}" ]]; then
  echo "[cert_cleanup] cert_cleanup.php not found at ${CLEANUP_SCRIPT} — skipping."
  exit 1
fi

# Export so PHP's getenv() can pick it up.
export CERT_DEPLOY_ENVIRONMENT_UUID

logline() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

logline "Starting expired certificate cleanup for environment: ${CERT_DEPLOY_ENVIRONMENT_UUID}"

php "${CLEANUP_SCRIPT}" "$@"
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
  logline "Certificate cleanup finished successfully."
else
  logline "Certificate cleanup exited with code ${EXIT_CODE}."
fi

exit $EXIT_CODE