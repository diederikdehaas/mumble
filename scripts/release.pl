#! /usr/bin/perl -w

use strict;
use warnings;
use Carp;
use Switch;
use Archive::Tar;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use Compress::Zlib;
use POSIX;
use File::Copy;

sub adddir($$) {
  my ($dir, $ref) = @_;
  $dir =~ s/^\.\///;
  my $base = $dir;
  $base =~ s/^.+\/([^\/]+)$/$1/;
  if (-f "$dir/$base.pro") {
    push @{$ref}, "$dir/$base.pro";
  }
  opendir(DIR, $dir);
  foreach my $e (grep { ! /^\./ } readdir(DIR)) {
    if (-d "$dir/$e") {
      adddir("$dir/$e", $ref);
    }
  }
}

my %files;
my $ver;
my %filevars = ( 'sources' => 1, 'headers' => 1, 'rc_file' => 1, 'dist' => 1, 'forms' => 1, 'resources' => 1, 'precompiled_header' => 1, 'translations' => 1);

system("rm mumble-*");
chdir("scripts");
system("bash mkini.sh");
chdir("..");

my @pro = ("main.pro");
#, "src/mumble.pri");
#adddir(".", \@pro);

my @resources;

while (my $pro = shift @pro) {
  open(F, $pro) or croak "Failed to open $pro";
  print "Processing $pro\n";
  $files{$pro}=1;
  my $basedir=$pro;
  $basedir =~ s/[^\/]+\Z//g;
  my @vpath = ($basedir);
  while(<F>) {
    chomp();
    if (/^include\((.+)\)/) {
      my $f = $basedir . $1;
      while ($f =~ /\.\./) {
        $f =~ s/(\/|\A)[^\/]+\/\.\.\//$1/g;
      }
      push @pro, $f;
    } elsif (/^\s*(\w+)\s*?[\+\-\*]{0,1}=\s*(.+)$/) {
      my ($var,$value)=(lc $1,$2);
      switch ($var) {
        case "version" {
          if ($basedir !~ /mumble11x/) {
            croak "Versions don't match" if (defined($ver) && ($ver ne $value));
            $ver=$value;
          }
        }
        case "vpath" {
          push @vpath,map { "$basedir$_/"} split(/\s/, $value);
        }
        case "subdirs" {
          push @pro,map { my ($b,$p) = ($_,$_); $p =~ s/^.+\///g; "$basedir$b/$p.pro" } split(/\s/, $value);
        }
        case %filevars {
          foreach my $f (split(/\s+/,$value)) {
              next if ($f =~ /^Murmur\.(h|cpp)$/);
              next if ($f =~ /^Mumble\.pb\.(h|cc)$/);
              my $ok = 0;
              foreach my $d (@vpath) {
                if (-f "$d$f") {
                  $f = $d.$f;
                  $ok = 1;
                  last;
                }
              }
              if (! $ok) {
                croak "Failed to find $f in ".join(" ",@vpath);
              } else {
                while ($f =~ /\.\./) {
                  $f =~ s/(\/|\A)[^\/]+\/\.\.\//$1/g;
                }
                $files{$f}=1;
                if ($var eq "resources") {
                  push @resources,$f;
                }
              }
          }
        }
      }
    }
  }
  close(F);
}

foreach my $resfile (@resources) {
  open(F, $resfile);
  my $basedir=$resfile;
  $basedir =~ s/[^\/]+\Z//g;
  while(<F>) {
    chomp();
    if (/\>(.+)<\/file\>/) {
      my $f = $basedir.$1;
      next if $f =~ /\.qm$/;
      while ($f =~ /\.\./) {
                  $f =~ s/(\/|\A)[^\/]+\/\.\.\//$1/g;
      }
      
      $files{$f}=1;
    }
  }
  close(F);
}

foreach my $dir ('speex','speex/include/speex','speex/libspeex','man','celt','celt/libcelt') {
  opendir(D, $dir) or croak "Could not open $dir";
  foreach my $f (grep(! /^\./,readdir(D))) {
    next if ($f =~ /\~$/);
    my $ff=$dir . '/' . $f;
    if (-f $ff) {
      $files{$ff}=1;
    }
  }
  closedir(D);
}

delete($files{'LICENSE'});

if (($#ARGV < 0) || ($ARGV[0] ne "release")) {
  open(F, "git rev-parse --short=6 origin|"); 
  while (<F>) {
    chomp();   
    $ver .= "~" . strftime("%Y%m%d%H%M",gmtime()) . "-" . $_;
  }
  close(F);
  print "REVISION $ver\n";
}

my $tar = new Archive::Tar();
my $zip = new Archive::Zip();
my $blob;
my $dir="mumble-$ver/";

my $zipdir = $zip->addDirectory($dir);

foreach my $file ('LICENSE', sort keys %files) {
  print "Adding $file\n";
  open(F, $file) or croak "Missing $file";
  sysread(F, $blob, 1000000000);

  if ($file eq "src/Version.h") {
    $blob =~ s/\#ifndef MUMBLE_VERSION/\#define MUMBLE_VERSION $ver\n\#if 0/;
  }

  $tar->add_data($dir . $file, $blob);
  my $zipmember=$zip->addString($blob, $dir . $file);
  $zipmember->desiredCompressionMethod( COMPRESSION_DEFLATED );
  $zipmember->desiredCompressionLevel( 9 );
  close(F);
}

my $gz=gzopen("mumble-${ver}.tar.gz", "w");
$gz->gzwrite($tar->write());
$gz->gzclose();

$zip->writeToFileNamed("mumble-${ver}.zip");

copy("mumble-${ver}.tar.gz", "../deb-mumble/tarballs/mumble_${ver}.orig.tar.gz");
