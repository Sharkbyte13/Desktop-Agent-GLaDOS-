' Starts the GLaDOS voice listener with no console window.
Option Explicit
Dim fso, shell, here, py, script, cfgFile, cfg, model, dev, comp, thr, cmd, txt
Set fso   = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

here   = fso.GetParentFolderName(WScript.ScriptFullName)
py     = fso.BuildPath(here, ".venv\Scripts\pythonw.exe")
If Not fso.FileExists(py) Then py = fso.BuildPath(here, ".venv\Scripts\python.exe")
script = fso.BuildPath(here, "listener.py")

If Not fso.FileExists(py) Then
    MsgBox "The voice environment is missing. Run Setup-Voice.cmd first." & vbCrLf & vbCrLf & py, 16, "GLaDOS Voice"
    WScript.Quit 1
End If

' Defaults, overridden by voice-config.json when the installer wrote one.
model = "base.en" : dev = "cpu" : comp = "int8" : thr = "0.5"
cfgFile = fso.BuildPath(here, "voice-config.json")
If fso.FileExists(cfgFile) Then
    txt = fso.OpenTextFile(cfgFile, 1).ReadAll
    model = Extract(txt, "whisperModel", model)
    dev   = Extract(txt, "whisperDevice", dev)
    comp  = Extract(txt, "whisperCompute", comp)
End If

cmd = """" & py & """ """ & script & """ --root """ & here & """" & _
      " --whisper-model " & model & " --whisper-device " & dev & _
      " --whisper-compute " & comp & " --threshold " & thr
shell.Run cmd, 0, False

Function Extract(json, key, fallback)
    Dim re, m
    Set re = New RegExp
    re.Pattern = """" & key & """\s*:\s*""([^""]*)"""
    re.IgnoreCase = True
    Set m = re.Execute(json)
    If m.Count > 0 Then Extract = m(0).SubMatches(0) Else Extract = fallback
End Function
