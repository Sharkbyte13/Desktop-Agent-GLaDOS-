# Training "Hey GLaDOS"

> **You no longer need this.** She listens for the phrases in
> `wake_phrases.json` instead: any burst of speech is transcribed and matched
> against that list, so "hey GLaDOS", "wake up GLaDOS" and "good morning
> GLaDOS" all work, each with its own mood, and adding another is a line in a
> text file. Say `/wake` in her chat window to see the list.
>
> Train a model anyway if you want the cheaper always-on path: a trained model
> costs almost no CPU, where the phrase list wakes Whisper for every burst of
> speech in the room. Run the listener with `--use-wake-model` to enable it
> alongside the phrases. Everything below still works.

Nobody ships a pretrained GLaDOS wake word, so you make one. openWakeWord
trains from *synthetic* speech — you do not record yourself hundreds of times.
A text-to-speech model generates thousands of variations of the phrase in
different voices, accents and acoustics, and a small classifier learns to spot
it. Under an hour, free, on Google's GPUs rather than yours.

You end up owning a ~2 MB `.onnx` file outright. No account, no API key, no
license, no service that can revoke it.

---

## Before you start

The listener already runs without this. Until `models\hey_glados.onnx` exists
it falls back to the pretrained `hey_jarvis` model, so you can test the whole
pipeline first and train the real phrase afterwards. Nothing else changes when
you swap it in.

## Steps

1. Open the official training notebook:
   https://github.com/dscripka/openWakeWord  → `notebooks/automatic_model_training.ipynb`
   (there is a "Open in Colab" badge in the README)

2. Runtime → Change runtime type → **T4 GPU**. Free tier is enough.

3. **Check the Python version first.** Run this in a cell:

       !python -V

   If it is 3.12 or lower, continue. If it is 3.13, stop — the phonemizer this
   notebook depends on has no wheel for it and the notebook cannot run.

4. **Apply the dependency fix.** Add a cell BEFORE the sample-generation cell:

       !pip uninstall -y piper-phonemize
       !pip install -q piper-phonemize-cross

   Why: `piper-phonemize` was last released in July 2023 and only ships Linux
   wheels up to Python 3.11. Colab has moved past that, so pip silently
   installs nothing and the notebook dies later with

       ModuleNotFoundError: No module named 'piper_phonemize'

   `piper-phonemize-cross` is a cross-compiled fork with wheels through 3.12.
   Same import name, same functions - a genuine drop-in.

5. Find the configuration cell and set the phrase:

       target_word = "hey glahdoss"

   NOT "hey glados". The string is fed to a text-to-speech model, so what
   matters is how eSpeak pronounces it, not how it is spelled. Measured:

       hey glados     ->  h eI  g l AH d oU z     "GLAH-dohz"  (wrong, z ending)
       GLAD-iss       ->    g l ae d I s          "GLAD-iss"
       hey gladoss    ->  h eI  g l ae d AH s     "GLAD-oss"
       hey glahdoss   ->  h eI  g l AH d AH s     "GLAH-doss"  <- canonical

   Train on the obvious spelling and you get a model that never fires when you
   say the name properly. Pick whichever row matches how you actually say it.

   Keep the "hey" prefix. Three syllables reject false positives far better
   than two, which matters a lot with an always-open microphone.

6. Leave every other setting alone on the first run. The defaults generate
   several thousand positive clips and mix in negatives from real recordings,
   which is what stops it firing at your Discord calls.

7. Run all cells. Roughly 30–50 minutes. It will look idle during synthetic
   speech generation; it is not.

8. Download the `.onnx` file it produces at the end.

9. Put it here, with exactly this name:

       Documents\GLaDOS\voice\models\hey_glados.onnx

10. Restart the listener (`Stop-Voice.cmd` then `Start-Voice.cmd`). The log will
   say `wake model: ...hey_glados.onnx` instead of `built-in 'hey_jarvis'`.

---

## Tuning it afterwards

`--threshold` defaults to 0.5.

- Firing when you did not speak to her → raise it, 0.6 or 0.7
- Not hearing you → lower it, 0.35, and check the microphone level in Windows

`voice.log` records every detection with its score, so tune from what actually
happened rather than by feel. If real wakes score 0.55 and false ones score
0.51, the model needs more training data rather than a different threshold —
re-run the notebook with more negative examples.

## If it keeps triggering on game or video audio

That is the normal failure mode for an always-listening setup, and it is why
push-to-talk exists. Options, in order of effort:

1. Raise the threshold
2. Use a headset mic instead of a desk or webcam mic — proximity does more
   than any amount of tuning
3. Re-run the notebook with your own problem audio added as negative examples
4. Add a push-to-talk key as well; the listener supports being driven
   either way and the two can coexist
