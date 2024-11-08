#!/usr/bin/perl

use v5.36;

use strict;
#use warnings;
use Cpanel::JSON::XS;
use WWW::Mechanize ();
use Data::Dumper;
use DateTime;

use POSIX;

use Coro;
use Coro::Semaphore;
use Coro::LWP;
use EV;

use File::Copy;
use File::Spec;

my $mech = WWW::Mechanize->new();

my $repodata = {};

#my $response = $mech->get('https://conda.anaconda.org/conda-forge/linux-64/repodata.json');
if ( ! -e 'conda-forge-linux-64-repodata.json' ){
  qx(curl -o conda-forge-linux-64-repodata.json https://conda.anaconda.org/conda-forge/linux-64/repodata.json > /dev/null 2>&1)
}
my $response = $mech->get('file:conda-forge-linux-64-repodata.json');
if( $response->is_success ){
  $repodata->{'linux-64'}  = decode_json $response->decoded_content;
}
#$response = $mech->get('https://conda.anaconda.org/conda-forge/noarch/repodata.json');
if ( ! -e 'conda-forge-noarch-repodata.json' ){
  qx(curl -o conda-forge-noarch-repodata.json https://conda.anaconda.org/conda-forge/noarch/repodata.json > /dev/null 2>&1)
}
$response = $mech->get('file:conda-forge-noarch-repodata.json');
if( $response->is_success ){
  $repodata->{'noarch'}  = decode_json $response->decoded_content;
}


my @url=();
my @skipped=();
my @not_found=();
my @malformed=();

foreach my $platform ( qw{ linux-64 noarch } ){
  while( my( $pkg, $pkgobj ) = each %{$repodata->{"$platform"}->{packages}} ){
    if( -e "/var/www/html/conda-forge/$pkgobj->{subdir}/$pkg" ){
#      print('.');
#      say "file [$pkg] already exists.  skipping";
      push(@skipped, $pkg);
    } else {
      push(@url, "https://conda.anaconda.org/conda-forge/${platform}/$pkg");
    }
  }
}

=pod

my $files; # Gathered from the output of the python conda-mirror program
$response = $mech->get('file:package-list.txt');
if( $response->is_success ){
  $files  = decode_json $response->decoded_content;
}
foreach my $filename ( @$files ) {
  my $fileobj = undef;
  if( exists $repodata->{'linux-64'}->{packages}->{$filename} ){
    $fileobj = $repodata->{'linux-64'}->{packages}->{$filename};
  }elsif( exists $repodata->{'noarch'}->{packages}->{$filename} ){
    $fileobj = $repodata->{'noarch'}->{packages}->{$filename};
  }else{
    if( -e "/var/www/html/conda-forge/$fileobj->{subdir}/$filename" ){
      say "file [$filename] already exists.  skipping";
      next;
    }
    push(@url, "https://conda.anaconda.org/conda-forge/linux-64/$filename");
    push(@url, "https://conda.anaconda.org/conda-forge/noarch/$filename");
    next;
  }
  if( -e "/var/www/html/conda-forge/$fileobj->{subdir}/$filename" ){
    say "file [$filename] already exists.  skipping";
  }else{
    push(@url, "https://conda.anaconda.org/conda-forge/$fileobj->{subdir}/$filename");
  }
}

=cut

#say Data::Dumper::Dumper( { malformed =>  \@malformed, not_found => \@not_found } );
#print($/);

say sprintf('There have been %i packages fetched', scalar(@skipped));
say sprintf('there are %i packages left to fetch', scalar(@url));

say "press enter to continue";
my $hold=<STDIN>;

my $sem = Coro::Semaphore->new(16);

sub start_thread($){
  my $url = shift(@_);
  return async {
    my $ua = WWW::Mechanize->new( autocheck => 0 );
    my $path_info = $url;
    $path_info =~ s{^http(?:s)://conda.anaconda.org/(.+)$}{$1};
    my($vol,$tmp_dir,$tmp_filename) = File::Spec->splitpath("/tmp/$path_info");
    my( $tmp_file,            $output_file,               $guard ) =
      ( "/tmp/$tmp_filename", "/var/www/html/$path_info", $sem->guard );
    my $response = $ua->get( $url );
    if ( $response->is_success ) {
      $ua->save_content( $tmp_file );
      # move from temp to final directory - possible failure situation
      move("$tmp_file","$output_file.tmp")  or die "Copy failed [$tmp_file] -> [$output_file.tmp]: $!";
      # rename output file from temporary name - unlikely to cause failure
      move("$output_file.tmp",$output_file) or die "Copy failed [$output_file.tmp] -> [$output_file]: $!";
      my($l)=length $ua->content;
      say sprintf( "Fetched %64s (%12d bytes/%5.2f MB) to %90s", $tmp_filename, $l, $l/1024/1024, $output_file );
    }
    $ua->delete();
  };
}


my $completed = 0;
my($left) = scalar(@url);
my $nproc = qx(nproc);
my($buffer_size) = POSIX::ceil($left / $nproc);
my($length) = $left < $buffer_size ? $left : $buffer_size;

if( $left > 1000 ){
  my(@children) = ();
  while ( @url ) {
    ($length) = $left < $buffer_size ? $left : $buffer_size;
    my(@batch) = splice(@url,0,$length);
    my $pid = fork();
    die "unable to fork: $!" unless defined($pid);
    if (!$pid) {		# child
      start_thread $_ for @batch;
      EV::loop;
      exit 0;
    } else {
      push(@children, $pid);
    }
  }

  foreach my $child ( @children ) {
    waitpid $child, 0;
  }
} else {
  start_thread $_ for @url;
  EV::loop;
}
