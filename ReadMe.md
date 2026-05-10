# CyberArk Get Accounts

PowerShell tooling for exporting and filtering CyberArk account metadata from a self-hosted PVWA environment.

The API paths are aligned with the CyberArk REST API Postman collection:

- `POST /PasswordVault/API/Auth/{CyberArk|LDAP}/Logon`
- `GET /PasswordVault/API/Accounts`
- `POST /PasswordVault/API/Auth/Logoff`

Passwords and secrets are not exported.

## Files

- `Get-CyberArkAccounts.ps1` - authenticates to PVWA and exports account metadata.
- `Filter-CyberArkAccounts.ps1` - filters exported CSV files by safe, platform, CPM status, username, onboarding date, and other fields.
- `config/cyberark.example.ini` - safe example configuration.

## Basic Usage

Copy the example config to a local config file:

```powershell
Copy-Item .\config\cyberark.example.ini .\cyberark.ini
```

Edit `cyberark.ini` for your environment. Do not commit it.

Run the account export:

```powershell
.\Get-CyberArkAccounts.ps1 -ConfigPath .\cyberark.ini
```

Filter an export:

```powershell
.\Filter-CyberArkAccounts.ps1 -InputCSV .\reports\accounts_batch1.csv -SafeFilter Windows
```

## Notes

- This repo is intended for self-hosted CyberArk PVWA.
- Use `CyberArk` or `LDAP` auth, depending on your environment.
- Prefer prompting or Windows Credential Manager over storing passwords in a file.
