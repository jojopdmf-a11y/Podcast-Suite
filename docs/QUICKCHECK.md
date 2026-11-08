# Quick check

Double-click `Run QuickCheck.command` at the top of the project. It builds PodLeveler and Pod Lounge, clicks through the basic loudness steps, and prints PASS or FAIL for each one. The same steps can be run from a terminal with `scripts/quickcheck.sh`. Exit code 0 means every check passed.

The results replace the previous run in `~/Desktop/PodStudio-QuickCheck-Results/`. That folder holds `summary.txt`, `report.json`, and at most a few failure pictures.

## What is checked

- PodLeveler and the Pod Lounge Limiter each open, load a short test recording, and show loudness numbers.
- Each one exports a 24-bit WAV and a 128 kbps MP3, both at 48 kHz. Each export writes one file, and that file decodes with the right length, sample rate, and channel count.
- In Pod Lounge, Export File to Depot is under Result Name. Saving to the depot leaves the current file selected and does not start another scan. Choosing a file that was already scanned shows the numbers again without measuring it a second time.
- At its smallest size, each window fits on a 1512 by 982 point screen. PodLeveler’s content floor is 1180 by 840.
- Neither app crashes, and no new crash report is left behind.

The test recording is made while the check runs. It is a 30 second stereo 48 kHz file with a tone and short noise bursts. It is not stored in the project.

## What is stubbed

File dialogs are not clicked. A normal launch never sees this. The check starts each app with `-UITestMode` and passes the file, export folder, project, and preset folder on the command line. Choose File, New, Import Audio, and the export buttons still run the real load, scan, and save code. They just skip the open and save panels. Finder is not opened, and Save As, Open, Export Copy, and Show in Finder do nothing during the check so they cannot wander into real files.

The copies that get launched use a throwaway preferences name, so window sizes and recent settings stay out of the real PodLeveler and Pod Lounge preferences.

## Permission prompt

The first run asks for the Mac login password before it can click the apps. A window appears for about a minute. Type the password you use to log in, then click Allow (or OK). Do not click Cancel. The window may mention testmanagerd, Xcode, or QuickCheckUITests-Runner.

If a second window asks about Accessibility or Automation, click Allow there too. If that window does not appear and a later run says a control could not be clicked, open System Settings, then Privacy & Security, then Accessibility, and turn on QuickCheckUITests-Runner, Terminal, or Xcode if they are listed.

The exact clicks are also written to `.ppjob/QUICKCHECK-BLOCKED.txt` when the password window stops a run.

## Cleanup

Every run, pass or fail, deletes the test recordings, the temporary project and depot, the exported files, the throwaway preferences, the test apps, and the Xcode build files it created. A trap does this even when a step fails. The Desktop results folder is the only thing left behind, and the next run replaces it. `summary.txt` records free disk space before and after.
