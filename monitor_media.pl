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
# Version 2.1 -- January 11, 2017
#
# Inspired by a script created by Ryan Babchishin
# Ryan Babchishin <rbabchishin@win2ix.ca>
# http://www.win2ix.ca
#
# Refactored with tons of help from this page
# https://jmorano.moretrix.com/2012/10/recursive-inotify-daemon/
# This new version has better garbage collection.
# Copyright 2012 Johnny Morano
#
# Copyright 2014-2016 truckershitch
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
use warnings;

# Load the inotify perl module
use Linux::Inotify2;
use File::Find;
use POSIX;
use AnyEvent;


my $mediaType = $ARGV[0];
if ($mediaType ne 'tv' && $mediaType ne 'movies') {
    die "Wrong media type.\n\nUsage: monitor_media.pl <media type>\nwhere <media type> is either tv or movies\n";
}

my $scriptPath = "/home/truckershitch/bin/monitor_media.pl";

my $mediaDir = "";
if ($mediaType eq 'tv') {
    $mediaDir = "/storage/videos/samba/TV";
}
else { #movies
    $mediaDir = "/storage/videos/samba/Movies";
}

my $plexDir = "/storage/videos/plex/";

my $FileBotCmd = "java -jar /home/truckershitch/bin/FileBot.jar";

my $cv = AnyEvent->condvar;

# Create inotify object
my $inotify = Linux::Inotify2->new or die "unable to create new inotify object: $!";

my %watches;

ScanDirs($mediaDir);

# Create event loop poller
my $poller = AnyEvent->io(
    fh   => $inotify->fileno,
    poll => 'r',
    cb   => sub { $inotify->poll }
);

# Receive event signals (inotify signals)
$cv->recv;

sub SendFYI { # Mail changes to recipient
    my $datestring = localtime();
    my $to = 'you@wish.com';
    my $from = 'root';
    my $subject = 'Media Update';
    my $message = $_[0];

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
    my $escaped = quotemeta($_[0]); # escape out evil characters
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
        if ($line =~ /^\[SYMLINK\].*\/(.*)\]/) { # extract filename, keep extension
#        if ($line =~ /^\[SYMLINK\].*\/(.*)\..*\]/) { # extract filename, toss extension
            $newmail .= "$1\n";
        }
    }
    if ($newmail ne "") {
        print "Sending mail\n";
        SendFYI($newmail);
    }
}

sub RemoveStaleSymlinks { # get rid of bogus symlinks
    system("find -L " . $plexDir . " -type l -delete");
}

sub ScanDirs {
    my $topdir = $_[0];
    find({ wanted => sub { -d $_ && CreateWatcher($inotify, $File::Find::name) } } , $topdir);
    print "Scanned $topdir\n";
}


sub CreateWatcher {
    my ($inotify, $dir) = @_;
    my $watcher = $inotify->watch($dir, IN_CREATE | IN_CLOSE_WRITE | IN_MOVE | IN_DELETE, sub {
    #added IN_CLOSE_WRITE event to catch events that were slipping through
        my $e = shift;
        my $filename  = $e->fullname;

        if(-d $filename) { # is directory
            if ($e->IN_CREATE | $e->IN_CLOSE_WRITE) {
                print "New directory.  Adding watch for $filename\n";
                CreateWatcher($inotify, $filename);
                ScanDirs($filename);
                FileBotMagic($filename);
                return;
            }
            elsif($e->IN_MOVED_TO) {
                # dir moved to watched directory
                print "Renamed directory.  Scanning path: $filename\n";
                ScanDirs($filename);
                RemoveStaleSymlinks();
                FileBotMagic($filename);
            }
        }
        elsif(-f $filename) { # is a file
            if($e->IN_CREATE | $e->IN_CLOSE_WRITE) {
                FileBotMagic($e->fullname);
            }
            elsif($e->IN_MOVED_TO) {
                # file moved to watched directory
                RemoveStaleSymlinks();
                FileBotMagic($filename);
            }
            elsif($e->IN_MOVED_FROM || $e->IN_DELETE) {
                # moved from watched directory
                # IN_DELETE may not be needed
                RemoveStaleSymlinks();
            }
        }
        else { # filename is now invalid
            if($e->IN_MOVED_FROM || $e->IN_DELETE) { # file/dir moved to new path
                if($e->IN_ISDIR) {
                    foreach my $subdir(sort keys %watches) { # put in nice order
                        # recursively remove watches
                        if (index($subdir, $filename) != -1) {
                            print "Deleting watch: $subdir\n";
                            my $watchtodelete = $watches{$subdir};
                            $watchtodelete->cancel;
                            delete $watches{$subdir};
                        }
                    }
                }
                RemoveStaleSymlinks();
            }
        }
    });
    $watches{$dir} = $watcher;
}
