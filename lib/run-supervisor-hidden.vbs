' run-supervisor-hidden.vbs - zero-window launcher for the NetEnv supervisor loop
' wscript.exe is a GUI-subsystem host: no conhost window is ever created.
' Path is resolved relative to this script (portable: moving the repo needs no edit).
'
' Single-instance guard: the periodic scheduled task reuses this launcher, so it must
' never spawn a second loop (double loops = duplicate restarts + log races).
' The match is deliberately narrow: a powershell/pwsh process running THIS path with
' "-File" -- a broad LIKE '%supervisor-loop.ps1%' also matches unrelated shells whose
' command line merely mentions the name, which silently blocks a needed restart.
Option Explicit

Dim fso, here, script, cmd, wmi, procs, query, pat
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "supervisor-loop.ps1")

Set wmi = GetObject("winmgmts:\\.\root\cimv2")
' In WQL string literals a backslash must be escaped as \\ or the query throws.
' (also: "Like" is a reserved word in VBScript - do not name a variable that.)
pat = "%" & Replace(script, "\", "\\") & "%"
query = "SELECT ProcessId FROM Win32_Process WHERE (Name = 'powershell.exe' OR Name = 'pwsh.exe')" & _
        " AND CommandLine LIKE '%-File%' AND CommandLine LIKE '" & pat & "'"
On Error Resume Next
Set procs = wmi.ExecQuery(query)
If Err.Number <> 0 Then
  Set procs = Nothing
  Err.Clear
End If
On Error GoTo 0
If Not procs Is Nothing Then
  If procs.Count > 0 Then
    WScript.Quit 0
  End If
End If

cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """"
CreateObject("WScript.Shell").Run cmd, 0, False
