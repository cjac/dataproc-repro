#!/usr/bin/perl -w

use v5.36;

use strict;
use Cpanel::JSON::XS;
use WWW::Mechanize ();
use Data::Dumper;

use Coro;
use Coro::Semaphore;
use Coro::LWP;
use EV;

use File::Copy;
use File::Spec;

my $mech = WWW::Mechanize->new();

my $repodata = {};

#my $response = $mech->get('https://conda.anaconda.org/conda-forge/linux-64/repodata.json');
my $response = $mech->get('file:conda-forge-linux-64-repodata.json');
if( $response->is_success ){
  $repodata->{'linux-64'}  = decode_json $response->decoded_content;
}
#$response = $mech->get('https://conda.anaconda.org/conda-forge/noarch/repodata.json');
$response = $mech->get('file:conda-forge-noarch-repodata.json');
if( $response->is_success ){
  $repodata->{'noarch'}  = decode_json $response->decoded_content;
}


my @fetchable=();
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
      push(@fetchable, { url => "https://conda.anaconda.org/conda-forge/${platform}/$pkg", ua => $mech });
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
print($/);

say sprintf('There have been %i packages fetched', scalar(@skipped));
say sprintf('there are %i packages left to fetch', scalar(@fetchable));

say "press enter to continue";
my $hold=<STDIN>;

my $sem = Coro::Semaphore->new(256);

sub start_thread($){
  my $fetchable = shift;
  return async {
    my $path_info = $fetchable->{url};
    $path_info =~ s{^http(?:s)://conda.anaconda.org/(.+)$}{$1};
    my($vol,$tmp_dir,$tmp_filename) = File::Spec->splitpath("/tmp/$path_info");
    my $tmp_file = "/tmp/$tmp_filename";
    my $output_file = "/var/www/html/$path_info";
    my $guard = $sem->guard;
#    my $ua = WWW::Mechanize->new();
    my $ua = $fetchable->{ua};
    my $response = $ua->get( $fetchable->{url} );
    if ( $response->is_success ) { $ua->save_content( $tmp_file ); }
    move("$tmp_file","$output_file") or die "Copy failed: $!";
    my($l)=length $ua->content;
    say sprintf( "Fetched %64s (%12d bytes/%.6f MB) to %90s", $tmp_filename, $l, $l/1024/1024, $output_file );
  };
}

start_thread $_ for @fetchable;

EV::loop;
