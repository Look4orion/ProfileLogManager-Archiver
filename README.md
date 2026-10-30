# Profile Log Manager Archiver

A small PowerShell script that backs up the logs your DayZ server's Profile Log Manager (PLM) mod has tidied, and tells the mod which of them are safe to delete.

It copies every log listed in the server's `ProfileLogManager/Index.txt`, checks each copy, packs the copies into one zip per day, and only then lists them in `Archived.txt`. With PLM set to `"Archived"` delete mode, the mod deletes exactly the logs listed there at its next start, and nothing else.

You need nothing but Windows and, for a rented server, WinSCP. There is no exe and no Python. The whole tool is the one file `PLMArchiver.ps1`, and you can read every line of it.

## Before you start

- **Profile Log Manager** must be on your server and must have run at least once, so that `ProfileLogManager/Settings.json` and `Index.txt` exist in the server's profile folder.
- **WinSCP** is needed for a rented server (remote mode), where the script reaches your files over SFTP. It is free, from winscp.net. It is not needed if you run the script on the server machine itself (local mode). Two downloads work:
  - **The installation package** (the main download button). Install it and the script finds it on its own.
  - **The ".NET assembly / COM library" zip**, if you cannot install programs on your PC. Unzip it into a folder of its own, for example `C:\Tools\WinSCP`. Then tell the script where it is: in PowerShell, run `setx WinSCP_PATH "C:\Tools\WinSCP"` with your folder, and sign out of Windows and back in.

  The "Portable executables" zip does not work: it lacks the file the script needs (`WinSCPnet.dll`).
- **For logs to be deleted after they are backed up**, set `PLM_DeleteMode` to `"Archived"` in PLM's `Settings.json`. In `"Days"` mode the mod deletes by age and ignores `Archived.txt`; the archiver still backs up, but it cannot keep anything from being deleted. The run log tells you when this is the case.
- **Remote mode** also needs an SFTP login (host, port, user name, password) from your host.

If your host gives only a web file manager and no SFTP, the archiver cannot reach your files. Turn on PLM's `PLM_GatherModLogs` instead. The mod then moves every log into one folder per day, `<PLM_LogFolder>/<day>/`, laid out like the zips below. Download that day folder by hand from the file manager.

## Get it and start it

1. Download `PLMArchiver.ps1` from the download page into a folder of its own, for example `C:\PLMArchiver`. Settings and logs are kept next to the script, so keep it in a folder you will not move.
2. If you downloaded it, Windows may mark it as blocked. Right-click the file, choose Properties, tick **Unblock** at the bottom if it is there, and press OK.
3. Right-click the file and choose **Run with PowerShell**.

The first start asks the setup questions. Running it again later asks the same questions with your saved answers as defaults: press Enter to keep an answer, or type a new one.

## Setup questions

1. **Which server.** On the first start, give a short name for it (letters, digits, `_` and `-`, up to 20), for example `MyServer`. Later you pick a saved one by number, `N` for a new one, or `D` to delete one. You can keep several servers in one copy of the script.
2. **Remote or local.** `R` for a rented server reached over SFTP, `L` for a server on the PC the script runs on.
3. **Remote only: host, port, user name and password.** The password is typed hidden. On a rerun, Enter keeps the saved one.
4. **Remote only: the host key.** The script asks the server for its host key, shows it, and asks `Is this your server? (Y/N)`. Answer Y only if you expect this server. The key is saved, and every later run checks it. If it ever changes, the run stops with nothing copied or written. If you moved to a new host on purpose, run setup again for that server. On a rerun, setup compares the key with the saved one: if it matches it says so and does not ask again; if it differs it warns that the key has CHANGED before asking.
5. **The server profile folder.** For remote mode, the path of the profile folder as your SFTP login sees it. For local mode, the folder on this PC. It is the folder that holds `ProfileLogManager`. A local folder typed as a relative path is saved as a full path, worked out from the folder setup was started in.
6. **The backup folder.** Where the zips go. Pick a folder that your cloud drive (Google Drive, OneDrive, Dropbox) syncs if you want an off-site copy; the archiver does not upload anywhere itself. It is created if it does not exist. A relative path is saved as a full path, like the profile folder.
7. **How often to run, in hours.** The default is 168 (one week). `0` means no schedule. The most is 744 (31 days), the longest repeat Windows Task Scheduler allows.

Setup then tests the connection and prints the `PLM_LogFolder` and `PLM_DeleteMode` it found. If the test fails it tells you why and asks whether to save anyway. At the very end it waits with `Press Enter to close`, so you can read the last messages before the window goes away.

## Where things go

Backups, one zip per server and day, named by the day folder's date:

    <backup folder>\MyServer\2026-10-27.zip
      Server/DayZServer_x64_2026-10-27_04-02-11.RPT
      Server/script_2026-10-27_04-02-11.log
      VPPAdminTools/Log_2026-10-27_4-2-11.txt
      ExpansionMod/ExpLog_2026-10-27_04-02-11.log
      CommunityOnlineTools/cot-2026-10-27-04-02-11.log

Each zip has one folder per source of log. Later runs add new files to an existing day's zip; a file already in the zip is never replaced.

**The zips are the record of what is saved.** The archiver reads them to know what it has backed up. Do not edit, rename or move them. If you move a zip away, the archiver backs those logs up again as long as they are still on the server.

Next to the script:

- `servers\` holds your saved settings, one file per server.
- `logs\<server>\` holds one run log per run, named `PLMArchiver_<date>_<time>.log`. The last 20 are kept.
- `work\` holds temporary files while a run is going.

## Reading the run log

The first line of each run log is the result, also printed in the window:

- `OK: 142 files saved in 7 day zips, Archived.txt uploaded` - all went well. `0 files saved` is normal when nothing is new. `Archived.txt already up to date` means there was nothing new to list.
- `OK with warnings: ...` - the backup worked, but a line below needs a look.
- `FAILED: ...` - something stopped the run. The reason is in the same line.

Problem lines are listed below the first line:

- `skipped unsafe index line: ...` - a line in `Index.txt` did not look like a normal log path, so it was ignored. Nothing was fetched for it.
- `listed but missing on the server: <line>` - the log is in `Index.txt` but gone from the server. It is left out and not listed in `Archived.txt`.
- `size on the server differs from the saved copy, not replaced and not listed: <line>` - a file with this name is already in the zip, but the server's file is a different size. The zip is not changed and the log is not listed.
- `size changed while copying, not saved: <line>` - the log was still being written. It is picked up on a later run.
- `Days mode: the mod deletes by age, the archiver backs up but cannot keep anything from deletion` - set `PLM_DeleteMode` to `"Archived"` if you want logs kept until backed up.
- `PLM_KeepDays (N days) is shorter than the schedule (N hours): logs may be deleted before a run reaches them` - in Days mode, make `PLM_KeepDays` longer than the interval, or run more often.
- `PLM_DeleteMode "..." deletes nothing; Archived.txt not written` - the mode in `Settings.json` is not one the archiver writes for.
- `Archived.txt holds the first 100000 lines; N more wait for the next run` - the list is capped; the rest follows on the next run.

Failures you may meet:

- `FAILED: another run of <name> is going` - a run of that server is already in progress. Nothing was written. A lock left behind by a run that was stopped (`work\<name>.lock`) is cleared by the next run on its own.
- `FAILED: settings for <name> could not be read - run setup` - the file in `servers\` is damaged. Run setup and enter that server again, or delete it with `D`.
- `FAILED: the backup folder '...' is not a full path - run setup again` (or `the profile folder`) - the saved folder is relative, which a scheduled run cannot use. Run setup for that server again and press Enter at each question; the folder is then saved as a full path.
- `FAILED: WinSCP not found - install it from winscp.net` - install WinSCP from its installation package, or set `WinSCP_PATH` to the folder of the unzipped ".NET assembly / COM library" zip (see "Before you start").
- `FAILED: the server's host key has changed, nothing copied or written ...` - see the host key step above. Do not rerun setup unless you know why the key changed.
- `FAILED: could not open the source: ...` - could not connect or log in. The text after the colon says what the connection said.
- `FAILED: could not read ProfileLogManager/Settings.json ...` or `no ProfileLogManager/Index.txt ...` - the mod has not run yet, or the profile folder in setup is wrong.
- `FAILED: two logs would share a zip path, nothing copied or written` - two different logs would land on the same path inside a day's zip. Both are named below the line. The run does nothing until this is sorted out on the server.
- `FAILED: day <date> not saved: <zip> is not a readable zip (...)` (or another reason after `not saved:`) - that day was left as it was and its logs were not listed. Other days carry on. Check the zip named.
- `FAILED: Archived.txt could not be written: ...` - the backup is fine, but the server refused the list. The next run tries again.

## The schedule

If you set hours above 0, setup makes one Windows scheduled task per server, named `PLMArchiver_<name>`. It runs under your own Windows user, with no admin rights needed. The first run is about five minutes after setup, then every N hours. If the PC was off at a run time, it runs as soon as it can afterwards.

Runs happen while you are logged in to Windows. Runs while logged off are not promised.

To stop the schedule, rerun setup for that server and set the hours to `0`.

You can also run a server by hand at any time:

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\PLMArchiver\PLMArchiver.ps1" -Run MyServer

The exit code is 0 for OK, 1 for OK with warnings, 2 for FAILED.

## What it does to your server

It reads `Settings.json`, `Index.txt`, any waiting `Archived.txt`, and the logs it backs up. The only things it writes on the server are `ProfileLogManager/Archived.tmp` (a temporary upload) and `ProfileLogManager/Archived.txt`. It never deletes or renames a server log; that is the mod's job. If a server refuses to rename the new list over an existing `Archived.txt`, the script removes the old `Archived.txt` just before renaming. A server start in that gap finds no `Archived.txt` and deletes nothing.

A log is listed in `Archived.txt` only when it is in its day zip, with the server's size and a checked copy. Lines already waiting in `Archived.txt` are kept, and no line appears twice.

## Deleting a server

Run the script, choose `D`, pick the server by its number, then confirm with `Y`. This removes its saved settings and its scheduled task. Your backups and run logs are left alone.

## Your password

The password is stored with Windows data protection, in your server's file under `servers\`. Only your Windows user, on this PC, can read it. Copying the file to another PC or user does not work; run setup there instead. The password is never written to a log or shown on screen.

## Licence

MIT. See `LICENSE`.
