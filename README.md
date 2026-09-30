# Bulk Classic Release Pipeline Creator (PowerShell)

Creates one classic release pipeline per CSV row, cloned from template release definition **27**.

## How it works
For each row (`ApiName`, `BuildName`):
1. If a release pipeline named `ApiName` already exists -> prints an `EXISTS` message and skips it.
2. Looks up the build pipeline `BuildName` (must match exactly one pipeline).
3. Clones template 27, sets the name to `ApiName`, and re-points the template's Build artifact to that build
   (artifact alias is preserved, so stage tasks/triggers keep working).
4. Creates the release pipeline. A `results.csv` report is written at the end.

## Setup
Works on Windows PowerShell 5.1 and PowerShell 7+. No modules required.

```powershell
$env:ADO_ORG     = "your-org"
$env:ADO_PROJECT = "Your Project"
$env:ADO_PAT     = "xxxxxxxx"
```
PAT scopes: **Release: Read, write & execute** and **Build: Read**.

## Run
```powershell
.\New-BulkReleasePipelines.ps1 -CsvPath .\apis.csv -DryRun   # validate first
.\New-BulkReleasePipelines.ps1 -CsvPath .\apis.csv           # create
```
Optional: `-TemplateId 27` (default), `-ArtifactAlias <alias>` (only if the template has several Build artifacts),
`-ReportPath .\results.csv`, or pass `-Organization` / `-Project` / `-Pat` instead of env vars.

## CSV format
```
ApiName,BuildName
Orders-API,Orders-API-CI
```

## Statuses
| Status  | Meaning |
|---------|---------|
| CREATED | Release pipeline created |
| EXISTS  | A release pipeline with that name already exists - skipped |
| FAILED  | Build not found/ambiguous, bad CSV row, or API error |
| SKIPPED | Duplicate ApiName inside the CSV |
| OK-DRY  | Dry run - would be created |

Exit code is `1` if any row FAILED (useful in CI).

## Notes
- Stages, approvals, agent pools, tasks and variables are copied as-is from template 27. For per-API variables, add logic in `New-ReleasePayload`.
- Secret variables aren't returned by the API; re-enter them on the created pipelines if needed.
