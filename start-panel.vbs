' Launch the Claude Monitor panel with no console window.
' Runs panel.ps1 from this script's own folder, so the whole tool folder is portable.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
here  = fso.GetParentFolderName(WScript.ScriptFullName)
panel = fso.BuildPath(here, "panel.ps1")
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File """ & panel & """", 0, False
