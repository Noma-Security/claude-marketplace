#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'

# Resolve NOMA_API_URL (env or default)
$nomaApiUrl = if ($env:NOMA_API_URL) { $env:NOMA_API_URL } else { 'https://api.noma.security' }

# Enforce *.noma.security domain
try {
    $nomaHost = ([System.Uri]$nomaApiUrl).Host
} catch {
    [Console]::Error.WriteLine('[Noma] NOMA_API_URL must point to a *.noma.security host')
    exit 1
}
if ($nomaHost -ne 'noma.security' -and -not $nomaHost.EndsWith('.noma.security')) {
    [Console]::Error.WriteLine('[Noma] NOMA_API_URL must point to a *.noma.security host')
    exit 1
}

# Resolve NOMA_API_KEY from Windows Credential Manager if not set (target: noma-claude-guardrails)
$nomaApiKey = $env:NOMA_API_KEY
if ([string]::IsNullOrEmpty($nomaApiKey)) {
    try {
        $credManagerCode = @'
using System;
using System.Runtime.InteropServices;
public class CredManager {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr cred);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr cred);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL {
        public int Flags; public int Type; public string TargetName; public string Comment;
        public long LastWritten; public int CredentialBlobSize; public IntPtr CredentialBlob;
        public int Persist; public int AttributeCount; public IntPtr Attributes;
        public string TargetAlias; public string UserName;
    }
    public static string Read(string target) {
        IntPtr credPtr;
        if (!CredRead(target, 1, 0, out credPtr)) return null;
        try {
            var cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));
            if (cred.CredentialBlobSize > 0)
                return Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2);
            return null;
        } finally { CredFree(credPtr); }
    }
}
'@
        if (-not ('CredManager' -as [type])) {
            Add-Type -TypeDefinition $credManagerCode -ErrorAction SilentlyContinue
        }
        $nomaApiKey = [CredManager]::Read('noma-claude-guardrails')
    } catch {}
}

if ([string]::IsNullOrEmpty($nomaApiKey)) {
    [Console]::Error.WriteLine('NOMA_API_KEY not found in environment or Windows Credential Manager. HTTP hooks will receive auth errors.')
    exit 1
}

# Read stdin (the hook payload)
$payload = [Console]::In.ReadToEnd()

# Add hostname and username to JSON payload (optional - fails gracefully)
try {
    $hostNameVal = $env:COMPUTERNAME
    $userNameVal = $env:USERNAME
    if ($hostNameVal -or $userNameVal) {
        $obj = $payload | ConvertFrom-Json -ErrorAction Stop
        if ($hostNameVal) { $obj | Add-Member -NotePropertyName 'hostname' -NotePropertyValue $hostNameVal -Force }
        if ($userNameVal) { $obj | Add-Member -NotePropertyName 'username' -NotePropertyValue $userNameVal -Force }
        $payload = $obj | ConvertTo-Json -Depth 100 -Compress
    }
} catch {
    # Leave payload unchanged if JSON manipulation fails
}

# POST to Noma API
try {
    $response = Invoke-WebRequest -Method Post `
        -Uri "$nomaApiUrl/claude/v1/hooks" `
        -Headers @{ 'Authorization' = "Bearer $nomaApiKey" } `
        -ContentType 'application/json' `
        -Body $payload `
        -TimeoutSec 10 `
        -UseBasicParsing
    Write-Output $response.Content
} catch {
    [Console]::Error.WriteLine("[Noma] $($_.Exception.Message)")
    exit 1
}
