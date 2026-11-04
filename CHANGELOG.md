# Changelog

## 1.1.1 - 2026-11-04

Fix: a revoked or expired API key was reported as OK. PayFit's `/introspect`
answers `{ "active": false }` without `company_id` for such a key, and `PFMe` /
`PFCompanyId` returned it without error, so callers saw an empty company id.
`PFIntrospect` now throws `PayFit: API key for entity '<slug>' is inactive
(revoked or expired)...` when `active` is not true, and a distinct error when the
key is active but `company_id` is missing. The message never contains the key,
and nothing empty is cached. Offline tests added; `payfit-access` skill notes it.

## 1.1.0 - 2026-11-04

New, optional: keys can be read from **Azure Key Vault** instead of `tokens.json`.
A `%USERPROFILE%\.payfit\config.json` with `"source": "keyvault"` (see
`config/config.example.json`) makes the library fetch one secret per company and
per person at run time, with an access token obtained silently from the Windows
account broker for the signed-in Entra ID user. Keys stay in memory; nothing
secret is written to disk. The vault secret is rebuilt into the same flat
`{<slug>: "<key>"}` object, so `PFToken`, `PFHdr` and the skills are unchanged.
`PFEntites` lists the companies from `config.json` in that mode.

Without `config.json` nothing changes: `tokens.json` is read as before. In vault
mode a failure throws a `Key Vault: ...` error and never falls back to the file.
`$env:PAYFIT_HOME` can now relocate the `.payfit` folder. New helpers: `PFHome`,
`PFConfig`, `PFVaultToken`, `PFVaultUser`, `PFVaultSecret`. New pitfall: the broker
returns `Success` with an empty token unless the v1 `resource` property is set.
The vault key carries the scopes its holder may use; the client has no write helper and writes stay under the skill approval rules.
Offline tests in `tests/`.

## 1.0.0 — 2026-09-22

First stable release. No functional change from 0.1.0: the skills, the PowerShell library and the
pitfall catalogue have been in daily production use, and the version now says so. Pinning this
toolkit at 1.0.0 is safe.

## 0.1.0

Initial public release.