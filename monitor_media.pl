#!/usr/bin/perl
#
# monitor_media.pl
#
# Script using Inotify2 and Filebot to watch directories
# and automatically create Plex-friendly symlinks for Plex Media Server
# New in Version 1.1 - mail report of new files
#
# Usage: monitor_media.pl <movies|tv>
#
# Version 1.1 -- October 24, 2016
#
# Based on a script created by Ryan Babchishin
# Ryan Babchishin <rbabchishin@win2ix.ca>
# http://www.win2ix.ca
#
# Copyright 2016 Jerry Chapman
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

use strict;

# Load the inotify perl module
use Linux::Inotify2;

my $mediaType = @ARGV[0];
if ($mediaType ne 'tv' && $mediaType ne 'movies') {
    die "Wrong media type.  Valid options are 'tv' and 'movies'";
}

my $scriptPath = "/home/truckershitch/bin/monitor_media.pl";

my $mediaDir = ""; # initalze this to satisfy 'use strict'
if ($mediaType eq 'tv') {
    $mediaDir = "/storage/videos/samba/TV";
}
else { #movies
    $mediaDir = "/storage/videos/samba/Movies";
}

my $plexDir = "/storage/videos/plex/";
 
my $FileBotCmd = "java -jar /home/truckershitch/bin/FileBot.jar";

# Create inotify object
my $inotify = Linux::Inotify2->new or die "unable to create new inotify object: $!";

sub SendFYI { # Mail changes to recipient
    my $datestring = localtime();
    my $to = 'you@wish.com';
    my $from = 'truckershitch@localhost';
    my $subject = 'Media Update';
    my $message = @_[0];

    open(MAIL, "|/usr/sbin/sendmail -t");

    # Email Header
    print MAIL "To: $to\n";
    print MAIL "From: $from\n";
    print MAIL "Subject: $subject\n\n";
    # Email Body
    print MAIL "Local Time: " . "$datestring\n\n";
    print MAIL $message;

    close(MAIL);
}

sub FileBotMagic { # Create new symlinks with FileBot for PLEX
    my $escaped = quotemeta(@_[0]); # escape out evil characters
    my $FileBotPrequel = " -rename " . $escaped . " --action symlink --output ";
    my $FileBotTVSuffix = " --db TheTVDB --format \"TV/{n}/Season {s}/{n} - {s00e00} - {t}\" -non-strict -r";
    my $FileBotMoviesSuffix = " --db TheMovieDB --format \"Movies/{n} ({y})\" -non-strict -r";
    my $FileBotFullCmd = $FileBotCmd . $FileBotPrequel . $plexDir;

    if ($mediaType eq 'tv') { # tv
        $FileBotFullCmd .= $FileBotTVSuffix;
    }
    else { # movies
        $FileBotFullCmd .= $FileBotMoviesSuffix;
    }

    my $FileBotOutput = `$FileBotFullCmd`; # run FileBot and capture output

    print $FileBotOutput; # send to STDOUT

    my $newmail = "";
    my @lines = split /\n/, $FileBotOutput;
    foreach my $line (@lines) {
        chomp($line);
        if ($line =~ /^\[SYMLINK\].*\/(.*)$\]/) {
            $newmail .= "$1\n";
        }
    }
    if ($newmail ne "") {
        SendFYI($newmail);
    }
}

sub GetNewName { # return new full path of file/directory because event->fullname has old name
    my $oldname = @_[0];
    my $slashdex = rindex $oldname, '/'; # index of rightmost forward slash
    my $basepath = substr $oldname, 0, $slashdex + 1;
    chdir $basepath;
    my $latest_changed = (`stat * --format '%Z %z :%n' | sort -nr | cut -d: -f4 | head -n 1`);
    #my alt_cmd = "find " . quotemeta($basepath) . " -maxdepth 1 -exec stat --format '%Z %z :%n' {} \; |" .
    #             " sort -nr | cut -d: -f4- | head -n 1";
    # see http://stackoverflow.com/questions/5566310/how-to-recursively-find-and-list-the-latest-modified-files-in-a-directory-with-s
    chomp($latest_changed); # lose newline character

    return $basepath . $latest_changed;
}

sub AddDirectoryWatch { # this mouthful tends to repeat
    my $dir = @_[0];
    $inotify->watch($dir, IN_CLOSE_WRITE | IN_MODIFY | IN_CREATE | IN_DELETE| IN_MOVED_FROM | IN_MOVED_TO);
}

sub RemoveStaleSymlinks { # get rid of bogus symlinks
    system("find -L " . $plexDir . " -type l -delete");
}


# Get a list of subdirectories to watch for changes
open(FIND, "find $mediaDir -type d |");
while(my $dir = <FIND>) {
    chomp($dir); # Remove newline
    print "Adding watcher for: $dir\n";
    # Create new inotify watcher for this directory
    AddDirectoryWatch($dir);
}

# Process inotify events
while () {
    # Get a new inotify event
    my @events = $inotify->read;
    unless (@events > 0){
        print "read error: $!";
        last ;
    }

    my $dir_rename_count = 1; # two events come up for a renamed directory

    # Loop for each event encountered
    foreach my $event (@events) {
        print $event->fullname . " was modified\n" ;

        # If a new directory is created, add a watcher for it
        if (($event->IN_ISDIR) && ($event->IN_CREATE)) { # new directory
            print "Is a new directory, adding watcher\n";
            # Create new inotify watcher for this directory
            AddDirectoryWatch($event->fullname);
            FileBotMagic($event->fullname);
        }

        elsif (($event->IN_ISDIR) && ($event->IN_MOVED_TO)) { # renamed directory
            # Getting double hits -- one is IN_ISDIR && IN_MOVED_FROM and one is IN_ISDIR && IN_MOVED_TO
            if ($dir_rename_count++ == 1) {
                print "Renamed directory -- add new watch.\n";
                my $newfilename = GetNewName($event->fullname);
                AddDirectoryWatch($newfilename);
                RemoveStaleSymlinks();
                FileBotMagic($newfilename);
                #print "Restarting script to fix renaming bug in inotify2.\n";
                #exec $^X, $0, $arg; # restart script -- interesting but doesn't work
                #exec $scriptPath, @ARGV  # restart script
            }
        }

        elsif (($event->IN_CREATE)) { # file has been created
            FileBotMagic($event->fullname);
        }

        elsif (($event->IN_MOVED_TO)) { # file has moved/changed
            RemoveStaleSymlinks(); # might not need this
            FileBotMagic($event->fullname);
        }

        elsif (($event->IN_DELETE) || ($event->IN_MOVED_FROM)) { # file/dir has been deleted/moved from
            #if (($event->IN_ISDIR)) {
            #    $event->w->cancel; # trying to just remove one watch removes entire object
            #}
            RemoveStaleSymlinks();
        }
    }
}
