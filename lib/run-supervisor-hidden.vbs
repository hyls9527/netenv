' run-supervisor-hidden.vbs - zero-window launcher for NetEnv scheduled tasks
' wscript.exe is a GUI-subsystem host: no conhost window is ever created.
CreateObject("WScript.Shell").Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\Deepseek Agent\netenv\lib\supervisor.ps1""", 0, False
