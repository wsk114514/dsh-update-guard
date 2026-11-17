' dsh-update-guard silent launcher.
'
' Task Scheduler starts this file through wscript.exe, which is a GUI-subsystem
' program: it never owns a console. The launcher then starts the guard script
' with window style 0 (hidden), so nothing flashes on screen every few minutes.
'
' Why not run powershell.exe directly as the task action? Because powershell.exe
' is a console program: Windows creates its console window first and only then
' applies -WindowStyle Hidden, which shows up as a black window flashing every
' 5 minutes.
'
' ASCII only on purpose: VBScript is decoded with the system code page, so
' non-ASCII text here would break on some machines.

Option Explicit

Dim fso, shell, powershell, guard, command, i, arg

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

powershell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
guard = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "dsh-update-guard.ps1")

command = """" & powershell & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & guard & """"

For i = 0 To WScript.Arguments.Count - 1
    arg = WScript.Arguments(i)
    If InStr(arg, " ") > 0 Then arg = """" & arg & """"
    command = command & " " & arg
Next

' 0 = hidden window, False = do not wait for the guard to finish.
shell.Run command, 0, False
