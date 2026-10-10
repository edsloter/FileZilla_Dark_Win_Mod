# tarballs/

Drop source archives here instead of letting the build download them.

Every fetcher in this kit checks this directory **before** it touches the network.
If a file is present it is verified against the SHA-512 pinned in `versions.ps1` and
used as-is. Only if a file is absent does anything get downloaded.

## Naming

Use exactly the pinned filenames as listed in `versions.ps1`. The current set is:

    FileZilla_3.71.1_src.tar.xz
    libfilezilla-0.57.0.tar.xz
    fzssh-1.4.0.tar.xz
    boost_1_88_0.tar.bz2
    sqlite-amalgamation-3530400.zip
    wxWidgets-3.3.3.tar.bz2

Bootstrap installers honor the same directory, using the names pinned in
`versions.ps1`. The FileZilla `.tar.bz2` variant is **not** currently seeded by the
drop box, because only one source digest is pinned; drop the `.tar.xz`.

The canonical names are derived from `versions.ps1`, so after a release bump read
them from there rather than guessing.

## If a file here is wrong

A file that is present but fails its digest is a **hard error**, not a re-download.
The build stops and tells you, because silently replacing something you placed by
hand is how a wrong-but-plausible archive ends up in a release. Delete or rename
the bad file yourself once you have worked out where it came from.

## This directory is ignored by git

The archives are large and are not source. `.gitkeep` and this file are tracked so
the directory exists in a fresh clone; everything else in here is ignored.
