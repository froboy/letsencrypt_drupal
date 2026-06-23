#!/usr/bin/env php
<?php

/**
 * cert_cleanup.php
 *
 * Removes expired or inactive Let's Encrypt certificates previously installed
 * by letsencrypt_drupal from an Acquia Cloud environment via the Acquia Cloud
 * API v2.
 *
 * Usage:
 *   php cert_cleanup.php [--dry-run]
 *
 * Options:
 *   --dry-run   List certificates that would be removed without actually
 *               deleting them.
 *
 * Credentials are read from the project's secrets.settings.php file (the same
 * file used by cert_deploy.php and Drupal itself). It is expected to define:
 *   $acquia_cloud_token   — Acquia Cloud API key.
 *   $acquia_cloud_secret  — Acquia Cloud API secret.
 *
 * The secrets file is located at the standard Acquia path:
 *   /mnt/files/{AH_SITE_NAME}.{AH_SITE_ENVIRONMENT}/secrets.settings.php
 *
 * CERT_DEPLOY_ENVIRONMENT_UUID must be set in config_<project>.<env>.sh as
 * it already is for cert_deploy.php.
 *
 * The script is intentionally conservative: it will never remove a certificate
 * that is currently marked "active" by Acquia, and it will always deactivate
 * a certificate before deleting it (per Acquia best-practice).
 */

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Write a timestamped log line to STDOUT (mirrors logline() in functions.sh).
 */
function logline(string $message): void {
  printf("\n[%s] %s\n", date('Y-m-d H:i:s'), $message);
}

/**
 * Make an authenticated request to the Acquia Cloud API v2.
 *
 * @param string $method   HTTP method (GET, DELETE, POST).
 * @param string $path     API path, e.g. "/environments/{uuid}/ssl/certificates".
 * @param string $key      Acquia API key.
 * @param string $secret   Acquia API secret.
 * @param array  $body     Optional request body (will be JSON-encoded).
 *
 * @return array{status: int, body: mixed}
 */
function acquia_api_request(
  string $method,
  string $path,
  string $key,
  string $secret,
  array $body = []
): array {
  $base_url = 'https://cloud.acquia.com/api';
  $url = $base_url . $path;

  $ch = curl_init();
  curl_setopt_array($ch, [
    CURLOPT_URL            => $url,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_USERPWD        => $key . ':' . $secret,
    CURLOPT_HTTPAUTH       => CURLAUTH_BASIC,
    CURLOPT_CUSTOMREQUEST  => strtoupper($method),
    CURLOPT_HTTPHEADER     => [
      'Accept: application/json',
      'Content-Type: application/json',
    ],
  ]);

  if (!empty($body)) {
    curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body));
  }

  $raw      = curl_exec($ch);
  $status   = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
  $curl_err = curl_error($ch);
  curl_close($ch);

  if ($curl_err) {
    throw new \RuntimeException("cURL error: $curl_err");
  }

  $decoded = json_decode($raw, true);

  return ['status' => $status, 'body' => $decoded];
}

// ---------------------------------------------------------------------------
// Bootstrap
// ---------------------------------------------------------------------------

$dry_run = in_array('--dry-run', $argv ?? [], true);

if ($dry_run) {
  logline('DRY-RUN mode enabled — no certificates will actually be removed.');
}

// Load credentials from secrets.settings.php — the same file used by
// cert_deploy.php. It defines $acquia_cloud_token and $acquia_cloud_secret.
$secrets_file = sprintf(
  '/mnt/files/%s.%s/secrets.settings.php',
  $_ENV['AH_SITE_NAME'] ?? '',
  $_ENV['AH_SITE_ENVIRONMENT'] ?? ''
);

if (!file_exists($secrets_file)) {
  logline("ERROR: Secrets file not found at: $secrets_file");
  exit(1);
}

require $secrets_file;

$api_key    = $acquia_cloud_token  ?? '';
$api_secret = $acquia_cloud_secret ?? '';
$env_uuid   = getenv('CERT_DEPLOY_ENVIRONMENT_UUID') ?: '';

if (!$api_key || !$api_secret) {
  logline(
    'ERROR: $acquia_cloud_token and $acquia_cloud_secret must be defined '
    . "in $secrets_file"
  );
  exit(1);
}

if (!$env_uuid) {
  logline('ERROR: CERT_DEPLOY_ENVIRONMENT_UUID is not set.');
  exit(1);
}

// ---------------------------------------------------------------------------
// Fetch all certificates for the environment
// ---------------------------------------------------------------------------

logline("Fetching certificate list for environment: $env_uuid");

$list_response = acquia_api_request(
  'GET',
  "/environments/$env_uuid/ssl/certificates",
  $api_key,
  $api_secret
);

if ($list_response['status'] !== 200) {
  logline(sprintf(
    'ERROR: Failed to retrieve certificate list (HTTP %d). Response: %s',
    $list_response['status'],
    json_encode($list_response['body'])
  ));
  exit(1);
}

$certs = $list_response['body']['_embedded']['items'] ?? [];

if (empty($certs)) {
  logline('No certificates found on this environment. Nothing to clean up.');
  exit(0);
}

logline(sprintf('Found %d certificate(s) on this environment.', count($certs)));

// ---------------------------------------------------------------------------
// Identify stale Let's Encrypt certificates
//
// A certificate is considered a candidate for removal when ALL of the
// following are true:
//   1. It was issued by Let's Encrypt (issuer CN contains "Let's Encrypt").
//   2. It is NOT currently active (active === false).
//   3. Its expiry date is in the past.
//
// The active certificate is never touched, even if it has expired, because
// removing it could take the site offline. (The renewal flow in
// letsencrypt_drupal.sh will replace it with a fresh cert anyway.)
// ---------------------------------------------------------------------------

$now     = new \DateTimeImmutable('now', new \DateTimeZone('UTC'));
$removed = 0;
$skipped = 0;

foreach ($certs as $cert) {
  $cert_id  = $cert['id']     ?? null;
  $label    = $cert['label']  ?? '(no label)';
  $active   = $cert['flags']['active'] ?? false;

  // Parse the certificate text to determine issuer and expiry.
  $cert_pem = $cert['certificate'] ?? '';
  $parsed   = openssl_x509_parse($cert_pem);

  if ($parsed === false) {
    logline("  [SKIP] Certificate ID $cert_id ($label): could not parse PEM — skipping.");
    $skipped++;
    continue;
  }

  $issuer_cn  = $parsed['issuer']['CN'] ?? '';
  $valid_to   = isset($parsed['validTo_time_t'])
                ? (new \DateTimeImmutable('@' . $parsed['validTo_time_t']))
                : null;

  $is_letsencrypt = stripos($issuer_cn, "Let's Encrypt") !== false
                    || stripos($issuer_cn, 'LetsEncrypt') !== false
                    || stripos($issuer_cn, 'ISRG') !== false;

  $is_expired = $valid_to !== null && $valid_to < $now;

  $expiry_str = $valid_to ? $valid_to->format('Y-m-d') : 'unknown';

  logline(sprintf(
    '  Certificate ID %s | Label: %s | Issuer: %s | Expires: %s | Active: %s',
    $cert_id,
    $label,
    $issuer_cn ?: '(unknown)',
    $expiry_str,
    $active ? 'yes' : 'no'
  ));

  // --- Safety checks ---

  if ($active) {
    logline("    → SKIP: certificate is currently active.");
    $skipped++;
    continue;
  }

  if (!$is_letsencrypt) {
    logline("    → SKIP: not a Let's Encrypt certificate.");
    $skipped++;
    continue;
  }

  if (!$is_expired) {
    logline("    → SKIP: certificate has not yet expired (expires $expiry_str).");
    $skipped++;
    continue;
  }

  // --- Candidate for removal ---

  logline("    → REMOVE: inactive, Let's Encrypt, expired ($expiry_str).");

  if ($dry_run) {
    logline("    (dry-run) Would deactivate + delete certificate ID $cert_id.");
    $removed++;
    continue;
  }

  // Per Acquia guidance: deactivate first, then delete.
  // Note: deactivating an already-inactive cert is a no-op but the API call
  // can return 409; we tolerate that gracefully.
  $deactivate_response = acquia_api_request(
    'POST',
    "/environments/$env_uuid/ssl/certificates/$cert_id/actions/deactivate",
    $api_key,
    $api_secret
  );

  if (!in_array($deactivate_response['status'], [200, 202, 409], true)) {
    logline(sprintf(
      '    WARNING: Deactivate returned HTTP %d — proceeding with delete anyway.',
      $deactivate_response['status']
    ));
  }

  $delete_response = acquia_api_request(
    'DELETE',
    "/environments/$env_uuid/ssl/certificates/$cert_id",
    $api_key,
    $api_secret
  );

  if (in_array($delete_response['status'], [200, 202, 204], true)) {
    logline("    Deleted certificate ID $cert_id.");
    $removed++;
  }
  else {
    logline(sprintf(
      '    ERROR: Failed to delete certificate ID %s (HTTP %d). Response: %s',
      $cert_id,
      $delete_response['status'],
      json_encode($delete_response['body'])
    ));
    $skipped++;
  }
}

// ---------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------

logline(sprintf(
  'Cleanup complete. Removed: %d | Skipped: %d.',
  $removed,
  $skipped
));