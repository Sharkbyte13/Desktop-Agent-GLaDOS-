' Launches GLaDOS with no console window.
' PowerShell must run in STA mode for WinForms to behave.
'
' Standard error is redirected to startup-error.txt rather than discarded.
' It is almost always empty. It matters on the day it is not: a script that
' Windows Defender refuses to run, or that fails to parse, never executes a
' single line, so it cannot log anything about itself - and launched hidden
' and non-interactive, the reason went nowhere at all. That cost a round trip
' of "she just does not start" with no evidence on the machine. Not again.
Option Explicit

Dim fso, shell, here, ps1, err, cmd
Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = fso.BuildPath(here, "glados.ps1")
err  = fso.BuildPath(here, "startup-error.txt")

If Not fso.FileExists(ps1) Then
    MsgBox "glados.ps1 was not found next to this launcher." & vbCrLf & vbCrLf & _
           "Expected: " & ps1, 16, "GLaDOS"
    WScript.Quit 1
End If

' A stale file from a previous failure would be read as this launch's.
If fso.FileExists(err) Then
    On Error Resume Next
    fso.DeleteFile err, True
    On Error Goto 0
End If

' cmd.exe does the redirect; window style 0 keeps both windows invisible.
cmd = "cmd.exe /c """"" & shell.ExpandEnvironmentStrings("%SystemRoot%") & _
      "\System32\WindowsPowerShell\v1.0\powershell.exe"" -STA -NoProfile -NonInteractive " & _
      "-WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps1 & """ 2>""" & err & """"""

' 0 = hidden window, False = do not wait
shell.Run cmd, 0, False
