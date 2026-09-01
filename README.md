# PayFit API Toolkit

A minimal PowerShell client for the **PayFit API**, plus a Claude skill and a
catalogue of the pitfalls that cost time. Read your own company data:
collaborators, contracts, absences, payslips, payroll journal.

Written for Windows PowerShell 5.1 (the one already on the machine), works on
PowerShell 7. No external dependency.

## Why this exists

PayFit exposes a public API, but two things are not obvious from the docs:
customers can issue their **own** API key without going through the partner
programme, and several behaviours differ from what the documentation states.
The `/introspect` endpoint in particular requires the key twice - once as a
Bearer header, once in the body - and returns 400 if you follow the docs
literally. That cost an afternoon; it is documented here so it costs you
nothing.

## What is in here

| Path | Contents |
|---|---|
| `lib/pf-api.ps1` | the client: auth, companyId resolution, pagination, throttling, bounded retry |
| `config/tokens.example.json` | key file template, one entry per company |
| `docs/PITFALLS.md` | what the documentation does not say |
| `skills/payfit-access/` | Claude skill wrapping the library |
| `examples/` | ready-to-run scripts |

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- A PayFit customer API key

## Quick start

### 1. Create the key

Go to <https://app.payfit.com/integrations/hub/api>, **Create a key**, give it an
explicit label and the scopes you need. **Copy it immediately** - it is shown
once and never again.

Read scopes: `collaborators:read`, `contracts:read`, `accounting:read`,
`time:read`, `health-insurance:read`. Write variants exist; only tick them if
you genuinely intend to write.

### 2. Place the key file

```powershell
New-Item -ItemType Directory -Path "$env:USERPROFILE\.payfit" -Force
Copy-Item .\config\tokens.example.json "$env:USERPROFILE\.payfit\tokens.json"
notepad "$env:USERPROFILE\.payfit\tokens.json"
```

It is JSON: replace the text **inside** the quotes, not the quotes themselves.

This file never belongs on a network share or in a repository. One key per
person: individual traceability and revocation.

### 3. Load and check

```powershell
. .\lib\pf-api.ps1
PFEntites                                    # declared companies
(PFMe 'my-company').company_id               # should return an id
(PFGetAll 'my-company' 'collaborators').Count
```

## Usage

```powershell
# Company information
$id = PFCompanyId 'my-company'
PFGet 'my-company' "/companies/$id"

# All collaborators, pagination handled
$people = PFGetAll 'my-company' 'collaborators'

# Filter by email
PFGetAll 'my-company' 'collaborators' @{ email = 'jane.doe@example.com' }

# Contracts and absences
PFGetAll 'my-company' 'contracts'
PFGetAll 'my-company' 'absences'

# Payslips for one collaborator
PFGetAll 'my-company' "collaborators/$collaboratorId/payslips"
```

## Functions

| Function | Role |
|---|---|
| `PFEntites` | companies declared in `tokens.json` |
| `PFMe $e` | introspection: company and granted scopes |
| `PFCompanyId $e` | `companyId`, resolved once and cached |
| `PFGet $e $path $query` | single GET, path relative to `/companies/{id}` |
| `PFGetAll $e $path $query` | fully paginated GET |
| `PFThrottle` | rate-limit friendly pause |

## The multi-company model

**One PayFit key is bound to one company.** There is no cross-company key.
`tokens.json` therefore holds one entry per company, and every call names the
company it targets:

```powershell
PFGetAll 'company-a' 'collaborators'
PFGetAll 'company-b' 'collaborators'
```

A `404` may simply mean the resource belongs to a different company. Check the
entity before concluding it does not exist.

## Rate limits and safety

PayFit allows **50 reads/s and 20 writes/s per key**. Exceeding that returns
HTTP 429 with `{ "message": "API rate limit exceeded" }`. The response carries
`X-RateLimit-Limit-Second` and `X-RateLimit-Remaining-Second`, on successful
calls too, so you can anticipate.

`PFThrottle` keeps a deliberately low cadence: an aggressive rate buys nothing
against the cost of a 429 in the middle of a batch.

Only **429, 500 and 503** are retried, with exponential back-off. `400`, `401`,
`403` and `404` mean the request or the key must be fixed, not repeated.

This client is read-oriented on purpose. Any write through the PayFit API
touches payslips and statutory social declarations, with legal deadlines
attached. If you extend it: test on one case before a batch, read back after
writing, and remember that a closed payroll period cannot be corrected through
the API - it needs a regularisation in the interface.

## Contributing

Issues and pull requests welcome, particularly additions to `docs/PITFALLS.md`:
undocumented behaviours are the most valuable thing this repository can carry.

## Licence

MIT. See `LICENSE`.

Not affiliated with PayFit. Built by Xileades. API behaviours described here
were verified in September 2026 and may change.
