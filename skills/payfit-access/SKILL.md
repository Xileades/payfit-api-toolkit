---
name: payfit-access
description: Access layer for the PayFit API (partner-api) using a customer API key - bootstrap, companies, pagination, rate limits, payroll safety rules. Load before any PayFit task.
---

# PayFit - access layer

Any task hitting the PayFit API starts here.

## 1. Bootstrap

```powershell
. .\lib\pf-api.ps1
```

If the library is shared from a network drive, copy it locally first: the
`RemoteSigned` policy refuses an unsigned `.ps1` on a network path. Keep the
share as the source of truth and the local copy as a cache overwritten at every
run. Do **not** work around it by setting the policy to `Bypass`.

If `pf-api.ps1` throws "tokens.json not found", point the user at the README.
Never guess a key, never reuse someone else's, never print one.

## 2. Companies and keys

**One PayFit key is bound to one company.** Hence one entry per company in
`%USERPROFILE%\.payfit\tokens.json`, never on a share, never in git.

Keys are created at <https://app.payfit.com/integrations/hub/api> and are
**displayed once**.

Pre-flight before anything unusual:

```powershell
PFEntites                        # available companies
(PFMe 'my-company').company_id   # confirms which company answers
(PFMe 'my-company').scope        # confirms what the key may do
```

## 3. Calling the API

Base `https://partner-api.payfit.com`, header `Authorization: Bearer <key>`.
`PFGet` and `PFGetAll` take a path relative to `/companies/{companyId}` and
resolve the id themselves.

| Function | Role |
|---|---|
| `PFEntites` | companies in tokens.json |
| `PFMe $e` | introspection: company and scopes |
| `PFCompanyId $e` | companyId, cached |
| `PFGet $e $path $query` | single GET |
| `PFGetAll $e $path $query` | fully paginated GET |
| `PFThrottle` | rate-limit friendly pause |

## 4. Pagination - the trap

`maxResults` defaults to **10** and caps at **50**; the next page comes from
`nextPageToken`. `PFGetAll` handles it. Paginating by hand and stopping at the
first batch makes a full company look nearly empty - the failure is silent.

## 5. Rate limits

50 reads/s, 20 writes/s per key. Over that: HTTP 429. Headers
`X-RateLimit-Limit-Second` and `X-RateLimit-Remaining-Second` let you
anticipate. Retry **only** 429, 500, 503.

## 6. Endpoints

Relative to `/companies/{companyId}`, except the company object itself.

| Path | Use |
|---|---|
| `/companies/{id}` | company record (there is no `/company` sub-path) |
| `collaborators` | employees, paginated |
| `collaborators/{id}` | one employee |
| `collaborators/{id}/payslips` | payslips |
| `contracts` | contracts |
| `absences` | absences - `startDate`/`endDate` are objects, read `.date` |
| `accounting` | payroll journal |

Reference: <https://developers.payfit.io/reference>

## 7. Errors

| Code | Meaning | Reflex |
|---|---|---|
| 400 | malformed request | fix it |
| 401 | key missing or revoked | reissue |
| 403 | **scope missing** | reissue with the right scope - retrying never works |
| 404 | unknown **or owned by another company** | check the entity first |
| 429 | rate limited | wait, then retry |

## 8. Payroll is not ordinary data

Every write touches payslips and statutory declarations, with legal deadlines
and a real risk of penalty assessment. Therefore:

- **summarise and wait for approval before the first write of a batch**;
- test on **one** case before the batch;
- read back after writing;
- when in doubt about the company, the employee or a period, **ask**.

A **closed** payroll period cannot be corrected through the API: it needs a
regularisation in the interface. The month just closed usually stays reopenable
for a few days.

## Verification

```powershell
PFEntites                                       # lists companies
(PFMe 'my-company').company_id                  # returns an id
(PFGetAll 'my-company' 'collaborators').Count   # > 0, and > 10 if headcount is
```
