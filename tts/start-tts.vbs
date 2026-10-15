' Starts the GLaDOS TTS daemon with no console window.
Option Explicit
Dim fso, shell, here, py, script, cmd
Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here   = fso.GetParentFolderName(WScript.ScriptFullName)
py     = fso.BuildPath(here, ".venv\Scripts\pythonw.exe")
If Not fso.FileExists(py) Then py = fso.BuildPath(here, ".venv\Scripts\python.exe")
script = fso.BuildPath(here, "daemon.py")
If Not fso.FileExists(py) Then
    MsgBox "The TTS environment is missing. Run Setup-TTS.cmd first." & vbCrLf & vbCrLf & py, 16, "GLaDOS TTS"
    WScript.Quit 1
End If
cmd = """" & py & """ """ & script & """ --root """ & here & """ --preload"
shell.Run cmd, 0, False
