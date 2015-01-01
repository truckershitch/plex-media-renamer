plex-media-renamer
==================

This Perl script watches television or movie directories with Linux::Inotify2 and automatically creates Plex-friendly symlinks for Plex Media Server in Linux.

This perl script will create Plex-friendly symlinks from your media using FileBot.

Requirements:
FileBot.jar - path is hard-coded in script
Linux::Inotify2 -- http://search.cpan.org/~mlehmann/Linux-Inotify2-1.22/Inotify2.pm

Please edit the paths at the top of the script to reflect your media paths.  I have combined television and music into one script, as I only have one directory for each type and redundancy seemed silly.  You could run more than one instance, I suppose.  This could be addressed with command-line options, but for my purposes I have not found it necessary to.

I welcome any input you have and I will be happy to try and assist if you need help.

This is my first GitHub repository, so be kind. :)
