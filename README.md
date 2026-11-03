# Paste Clipboard Media

A script for DaVinci Resolve that pastes the image, GIF or video on your clipboard straight
into the timeline at the playhead.

The file is saved to a folder on disk, imported into a Media Pool bin and placed on the
highest free video track. If that spot is taken, a new track is added on top. Nothing on the
timeline gets moved or overwritten.

Works on Windows with DaVinci Resolve 18.5 or newer, free or Studio.


## Install

Open PowerShell (search for it in the Start menu) and run:

    irm https://raw.githubusercontent.com/Jude-sigma/Davinci-image-pasting/main/install.ps1 | iex

Then restart Resolve. The scripts show up under Workspace > Scripts > Paste Clipboard Media.

To update, run the same command again. Your settings are kept.

Manual install: click Code > Download ZIP on this page, extract it, right-click install.ps1
and choose Run with PowerShell. Or copy the "Paste Clipboard Media" folder yourself to:

    %APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Utility

Once installed, the downloaded files can be deleted.


## Shortcut

Open DaVinci Resolve > Keyboard Customization, search for Paste Clipboard Media and give it
a key. Using Ctrl+V would replace Resolve's normal paste, so pick a different key.


## Settings

Run Paste Clipboard Media Settings from the same menu.

Images, GIFs and videos each have their own Media Pool bin and size. Type a bin path to
create a new one. Size is the zoom the clip gets when placed, so 50 % is half size.

Pasted files are saved to %USERPROFILE%\Videos\Resolve Pasted Media\{project} by default.

Images use the still length set in Preferences > User > Editing > Standard still duration.


## Uninstall

Delete the "Paste Clipboard Media" folder from the Scripts\Utility folder above.
