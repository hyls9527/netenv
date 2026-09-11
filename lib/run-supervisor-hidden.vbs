' run-supervisor-hidden.vbs - zero-window launcher for NetEnv supervisor
' wscript.exe is a GUI-subsystem host: no conhost window is ever created.
' 路径相对本脚本解析（便携版换盘符/换目录后无需改脚本）。
Dim fso, here, script, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
script = fso.BuildPath(here, "supervisor-loop.ps1")
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & script & """"
CreateObject("WScript.Shell").Run cmd, 0, False
