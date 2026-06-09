-- FLAC2Watch — drag & drop front-end
-- Drop a folder or audio files onto the app icon: they are copied into the
-- music library and an immediate sync to the watch is triggered.

property libSuffix : "/Music/WatchSync"
property binSuffix : "/.local/bin/flac2watch"

on libDir()
	return (do shell script "echo $HOME") & libSuffix
end libDir

on bin()
	return (do shell script "echo $HOME") & binSuffix
end bin

-- Files/folder dropped onto the icon
on open theItems
	set lib to libDir()
	do shell script "mkdir -p " & quoted form of lib
	repeat with anItem in theItems
		set p to POSIX path of anItem
		do shell script "cp -R " & quoted form of p & " " & quoted form of lib
	end repeat
	display notification "Konvertiere & synce zur Uhr…" with title "FLAC2Watch"
	try
		do shell script quoted form of bin() & " sync --notify"
	on error errMsg
		display notification "Fehler: " & errMsg with title "FLAC2Watch"
	end try
end open

-- Double-clicked without dropping anything → open the library folder
on run
	set lib to libDir()
	do shell script "mkdir -p " & quoted form of lib
	do shell script "open " & quoted form of lib
end run
