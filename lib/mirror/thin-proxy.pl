#!/usr/bin/perl -w
use strict;

package GoogleCloudDataproc::CondaMirror::ThinProxy;
use Plack::Handler::Apache2;
use Plack::Request;
use Data::Dumper;
use File::LibMagic;
use File::Spec;
use WWW::Mechanize;
use APR::Const -compile => qw(:error SUCCESS);

my $app = sub {
  my $env = shift; # PSGI env
  my $req = Plack::Request->new($env);
  my $path_info = $req->path_info;
  my $mount_point='/var/www/html';
  my $requested_file=join('',$mount_point,$path_info);

  my $s = $GoogleCloudDataproc::CondaMirror::ThinProxy::svr;
  my $mech = $GoogleCloudDataproc::CondaMirror::ThinProxy::mech;

  my($mirror_hostname,$mirror_path) =
    ( $path_info =~ m{^/([^/]+)(/.+)$} );

  no strict 'subs';
  $s->log_serror(Apache2::Log::LOG_MARK, Apache2::Const::LOG_INFO,
		 APR::Const::SUCCESS, "requested ${mirror_path} from ${mirror_hostname}");
  use strict 'subs';

  if( $mirror_hostname eq 'conda.anaconda.org' ){
    # When requesting repodata.json, always fetch from upstream
    if ( $path_info =~ /repodata\.json(\.zst|\.gz|\.xz|.zip)?$/ ) {
      my $suffix = $1;
      $requested_file='/tmp/repodata.json' . ( $suffix ? $suffix : '' );
      unlink $requested_file if -f $requested_file;
    }
  }elsif( grep { $mirror_hostname eq $_ }
	  qw(
	      archive.debian.org
	      cloud.r-project.org
	      developer.download.nvidia.com
	      download.docker.com
	      packages.adoptium.net
	      packages.cloud.google.com
	      repo.mysql.com
	      storage.googleapis.com
	   ) ){
    if ( $path_info =~ /((InRelease|Release|Release.gpg|Sources|Packages|ls-lR)(\.*))$/ ){
      my( $release_file, $prefix, $suffix ) = ($1,$2);
      $requested_file="/tmp/${release_file}";
      unlink $requested_file if -f $requested_file;
    }
  }else{
    print STDERR "fetched from ${mirror_hostname} folder$/";
  }

  my($vol,$dir,$file) = File::Spec->splitpath($requested_file);
  qx(mkdir -p $dir) unless -d $dir;

  unless ( -f $requested_file ) {
    print STDERR "cache miss on $path_info ; directory: $dir$/";
    no strict 'subs';
    $s->log_serror(Apache2::Log::LOG_MARK, Apache2::Const::LOG_INFO,
                   APR::Const::SUCCESS, "cache miss on ${path_info}");
    use strict 'subs';
    # Unless the file already exists, fetch it from upstream
    my $src_url = join('',"https://${mirror_hostname}", $mirror_path);

    if ( (my $response = $mech->get( $src_url ))->is_success() ) {
      $mech->save_content( $requested_file );
    } else {
      my $res = $req->new_response($response->code); # new Plack::Response
      $res->body("file [$path_info] found neither under file://$requested_file nor on ${src_url}$/");
      return $res->finalize;
    }
  }
  my $size = (stat($requested_file))[7];

  my $res = $req->new_response(200); # new Plack::Response
  $res->headers({ 'Content-Type' => File::LibMagic->new->info_from_filename(qq{$requested_file})->{mime_type} });
  $res->content_length($size);
  open(my($fh), q{<}, $requested_file);
  $res->body($fh);

  $res->finalize;
};
