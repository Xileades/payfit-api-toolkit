# Pitfalls

What the PayFit documentation does not say, or says differently from how the
API behaves. Verified against the live API in September 2026.

## `/introspect` wants the key twice

The docs say "make a POST request to `https://oauth.payfit.com/introspect` with
your API key". Taken literally - Bearer header only - it returns **400**. Body
only, no header, returns **401**.

It needs both: the `Authorization: Bearer <key>` header **and** a
`token=<key>` parameter in a form-urlencoded body, as in RFC 7662.

```powershell
Invoke-RestMethod -Uri 'https://oauth.payfit.com/introspect' -Method Post `
    -Headers @{ Authorization = "Bearer $key" } `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{ token = $key }
```

The response carries `company_id`, `scope`, `customer_token_name` and
`active`. It is also the cheapest way to audit what a key is actually allowed
to do.

## `maxResults` defaults to 10 and caps at 50

Every list endpoint is paginated, and the default page is **10 items**. A
company of 200 employees returns 10 and looks nearly empty. The cap is **50** -
asking for more is silently ignored rather than rejected, which is worse.

Pagination is by `nextPageToken`, present in the response while pages remain.
`PFGetAll` handles it. If you paginate by hand, do not stop at the first batch.

## A missing scope returns 403, not 401

401 means the key is absent or revoked - regenerate it. **403 means the key is
valid but lacks the scope.** Retrying will never succeed: the key has to be
reissued with the right scope, since scopes are fixed at creation.

Only `429`, `500` and `503` are worth retrying.

## 404 can mean "belongs to another company"

A key is bound to one company. Querying an id that exists, but under a
different company, returns 404 - indistinguishable from a genuinely unknown
resource. Confirm the entity before concluding the record does not exist.

## `/company` is not an endpoint

The company object is served at the collection path itself,
`GET /companies/{companyId}`, not at `/companies/{companyId}/company`. The
latter returns 404.

It returns `name`, `country`, `identificationNumber`, `address`, `city`,
`postalCode` and `nbActiveContracts` - useful as a cheap sanity check that you
are talking to the company you think you are.

## Absence dates are objects, not strings

`startDate` and `endDate` on `/absences` are objects:

```json
{ "date": "2026-07-24", "moment": "beginning-of-day" }
```

Formatting them directly yields `@{date=...; moment=...}`. Read `.date`, and
`.moment` when the half-day matters.

Absence `type` uses country-prefixed identifiers such as
`fr_maladie_ordinaire` or `fr_paternite`.

## The key is displayed once

There is no way to read an API key back from the PayFit interface after
creation. Losing it means creating a new one and revoking the old.

## Scopes are broader than they look

A key created with a generous set can carry `collaborators:write`,
`collaborators:contracts:write`, `time:write` and `health-insurance:write` -
the ability to modify employees and contracts, on a payroll system. Check what
you actually granted with `PFMe`, and reissue a read-only key if writing was
never the intention.
