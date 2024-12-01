#!/usr/bin/perl
package CTL78::Conda::Mirror::Sync;

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

my( @url, @present )=();

my $mntpt = '/var/www/html';

foreach my $platform ( qw( linux-64 noarch ) ){
  foreach my $channel ( qw(  nvidia rapidsai r main conda-forge  ) ){
#foreach my $platform ( qw( linux-64 ) ){
#  foreach my $channel ( qw( main ) ){
    qx(mkdir -p ${mntpt}/conda.anaconda.org/${channel}/${platform});
    my $cache_file = "/tmp/${channel}-${platform}-repodata.json";
    if ( -e  $cache_file ){
      $mech->get( "file:$cache_file" );
    }else{
      $mech->get( "https://conda.anaconda.org/${channel}/${platform}/repodata.json");
      $mech->save_content( $cache_file );
    }
    my $repodata = decode_json $mech->response()->decoded_content;
    my @this_url;
    my @this_present;

    #    foreach my $pkg ( keys %{$repodata->{packages}}, keys %{$repodata->{'packages.conda'}} ){
    foreach my $repokey ( qw{ packages packages.conda } ){
      printf( 'loading %15s data for %21s... ', $repokey, "${channel}/${platform}" );
      my $pkghash = $repodata->{$repokey};
#    foreach my $pkghash ( $repodata->{packages}, $repodata->{'packages.conda'} ){
      while ( my( $pkg, $pkgobj ) = each ( %$pkghash ) ) {

=pod

      die Data::Dumper::Dumper($pkgobj);

$VAR1 = {
          'timestamp' => '1584021296829',
          'build_number' => 0,
          'requires' => [],
          'size' => 1169424,
          'subdir' => 'linux-64',
          'license' => 'BSD-3-Clause',
          'platform' => 'linux',
          'md5' => '30840c82232dbf1c1c38582ff635980e',
          'depends' => [
                         'backcall',
                         'decorator',
                         'jedi >=0.10,<0.18',
                         'pexpect',
                         'pickleshare',
                         'prompt_toolkit >=2.0.0,<4,!=3.0.0,!=3.0.1',
                         'pygments',
                         'python >=3.7,<3.8.0a0',
                         'setuptools >=18.5',
                         'traitlets >=4.2'
                       ],
          'sha256' => 'cf3c42ac3b6b9b07bcdb07166c1200a435e9a7f56d7024e2cc35cec4b461b177',
          'license_family' => 'BSD',
          'version' => '7.13.0',
          'source_url' => 'http://repo.continuum.io/pkgs/main/linux-64/ipython-7.13.0-py37h5ca1d4c_0.tar.bz2',
          'binstar' => {
                         'package_id' => '5df1f4ff7870580d1c9ead3a',
                         'owner_id' => '59b17b630c9b040aed6464a8',
                         'channel' => 'main'
                       },
          'arch' => 'x86_64',
          'name' => 'ipython',
          'build' => 'py37h5ca1d4c_0'
        };

=cut

	# Do some filtering here, optionally
	# my $epoch2017 = 1514764799000;
	# next if( $pkgobj->{timestamp} < $epoch2017 );
	if ( -e "${mntpt}/conda.anaconda.org/${channel}/${platform}/${pkg}" ) {
	  push(@this_present, $pkg);
	} else {
	  push(@this_url, "https://conda.anaconda.org/${channel}/${platform}/${pkg}");
	}
      }

      say( printf('%6i present, %6i to fetch', scalar( @this_present ), scalar(@this_url) ) );
      push(@present, @this_present);
      push(@url, @this_url);
    }
  }
}

my $num_coroutines=8;
my $sem = Coro::Semaphore->new($num_coroutines);

sub start_thread($){
  my $url = shift(@_);
  return async {
    my $ua = WWW::Mechanize->new( autocheck => 0 );
    my $path_info = $url;
    $path_info =~ s{^http(?:s)://conda.anaconda.org/(.+)$}{$1};

    my($vol,$tmp_dir,$tmp_filename) = File::Spec->splitpath("/mnt/shm/$path_info");
    my( $tmp_path,                $output_file,                                  $guard ) =
      ( "/mnt/shm/$tmp_filename", "${mntpt}/conda.anaconda.org/$path_info", $sem->guard );
    my $response = $ua->get( $url );
    my $tries = 0;
    until( $ua->response()->is_success || $tries++ > 5){
      $ua->get( $url );
    }
    if ( $response->is_success ) {
      $ua->save_content( $tmp_path );
      # move from temp to final directory - possible failure situation
      move("$tmp_path","$output_file.tmp")  or die "Copy failed [$tmp_path] -> [$output_file.tmp]: $!";
      # rename output file from temporary name - unlikely to cause failure
      move("$output_file.tmp",$output_file) or die "Copy failed [$output_file.tmp] -> [$output_file]: $!";
      my($l)=length $ua->content;
      print('.');
#      say sprintf( "Fetched %64s (%12d bytes/%09.2f MB) to %90s", $tmp_filename, $l, $l/1024/1024, $output_file );
    }else{
      say sprintf( "Failed to fetch: curl -o %s %s (%s)", $output_file, $url, $response->status_line );
    }
    $ua->delete();
  };
}


my $completed = 0;
my $nproc = qx(nproc);
my $num_forks = $nproc * 0.8;
my($left) = scalar(@url);
my($buffer_size) = POSIX::ceil($left / $num_forks);

say('-'x80, $/, "total: ", scalar( @present ), " present, $left to fetch");

if( $left == 0 ){
  say "all packages present.  Exiting now.";
  exit 0;
}elsif( $left > 1000 ){
  say spritnf('running as %i coroutines in %i new forked processes', $num_coroutines, POSIX::floor( $num_forks ));
  my(@children) = ();
  while ( @url ) {
    $left = scalar(@url);
    my($length) = $left < $buffer_size ? $left : $buffer_size;
    my(@batch) = splice(@url,0,$length);
    my $pid = fork();
    die "unable to fork: $!" unless defined($pid);
    if (!$pid) {		# child
#      say "processing batch of ", scalar @batch, " in process $$";
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
  say "all children waited for"
} else {
  say "running as $num_coroutines coroutines";
  start_thread $_ for @url;
  EV::loop;
}

print $/, "Download complete.  Now compressing repodata.json...";
# Now that we have downloaded all files in the repodata.json files, copy them to the mirror mountpoint
foreach my $platform ( qw( linux-64 noarch ) ){
  foreach my $channel ( qw(  nvidia rapidsai r main conda-forge  ) ){
    my( $cache_file, $dst_file ) =
      ( "/tmp/${channel}-${platform}-repodata.json",
	"${mntpt}/conda.anaconda.org/${channel}/${platform}/repodata.json" );
    copy $cache_file, $dst_file;
    qx{zstd  -fk "$dst_file" > /dev/null 2>&1};
    qx{bzip2 -fk "$dst_file" > /dev/null 2>&1};
  }
}
say "done.";
