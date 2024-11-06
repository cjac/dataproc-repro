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

my $files;
$response = $mech->get('file:package-list.txt');
if( $response->is_success ){
  $files  = decode_json $response->decoded_content;
}

my @url=();
my @not_found=();
my @malformed=();

foreach my $filename ( @$files ) {
  my $fileobj = undef;
  if( exists $repodata->{'linux-64'}->{packages}->{$filename} ){
    $fileobj = $repodata->{'linux-64'}->{packages}->{$filename};
  }elsif( exists $repodata->{'noarch'}->{packages}->{$filename} ){
    $fileobj = $repodata->{'noarch'}->{packages}->{$filename};
  }else{
    $fileobj = { subdir => 'linux-64' }
  }
  if( -e "/var/www/html/conda-forge/$fileobj->{subdir}/$filename" ){
    say "file [$filename] already exists.  skipping";
  }else{
    push(@url, "https://conda.anaconda.org/conda-forge/$fileobj->{subdir}/$filename");
  }
}

#say Data::Dumper::Dumper( { malformed =>  \@malformed, not_found => \@not_found } );

say sprintf('there are %i packages to fetch', scalar(@url));

say "press enter to continue";
my $hold=<STDIN>;

my $sem = Coro::Semaphore->new(384);

sub start_thread($){
  my $src_url = shift;
  return async {
    my $path_info = $src_url;
    $path_info =~ s{^http(?:s)://conda.anaconda.org/(.+)$}{$1};
    my($vol,$tmp_dir,$tmp_filename) = File::Spec->splitpath("/tmp/$path_info");
    my $tmp_file = "/tmp/$tmp_filename";
    my $output_file = "/var/www/html/$path_info";
    say "Waiting for semaphore";
    my $guard = $sem->guard;
    my $ua = WWW::Mechanize->new();
    my $response = $ua->get( $src_url );
    if ( $response->is_success ) { $ua->save_content( $tmp_file ); }
    move("$tmp_file","$output_file") or die "Copy failed: $!";
    my($l)=length $ua->content;
    say sprintf( "Fetched $src_url (%d bytes/%.2f MB) to $output_file", $l, $l/1024/1024 );
  };
}

start_thread $_ for @url;

EV::loop;
