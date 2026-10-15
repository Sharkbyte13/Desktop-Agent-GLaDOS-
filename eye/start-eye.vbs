' Starts the GLaDOS screen-capture daemon with no console window.
' Any arguments passed to this script are forwarded to eye.py, so the overlay
' can set --max-width / --quality from config without editing anything here.
Option Explicit
Dim fso, shell, here, py, script, cmd, i
Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here   = fso.GetParentFolderName(WScript.ScriptFullName)
py     = fso.BuildPath(here, ".venv\Scripts\pythonw.exe")
If Not fso.FileExists(py) Then py = fso.BuildPath(here, ".venv\Scripts\python.exe")
script = fso.BuildPath(here, "eye.py")
If Not fso.FileExists(py) Then
    MsgBox "The eye environment is missing. Run Setup-Eye.cmd first." & vbCrLf & vbCrLf & py, 16, "GLaDOS eye"
    WScript.Quit 1
End If
cmd = """" & py & """ """ & script & """ --root """ & here & """"
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & " " & WScript.Arguments(i)
Next
shell.Run cmd, 0, False
