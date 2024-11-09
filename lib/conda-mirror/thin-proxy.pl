#!/usr/bin/perl -w
use strict;

package GoogleCloudDataproc::CondaMirror::ThinProxy;
use Plack::Handler::Apache2;
use Plack::Request;
use Data::Dumper;
use File::LibMagic;
use WWW::Mechanize;
use APR::Const -compile => qw(:error SUCCESS);

my $app = sub {
  my $env = shift; # PSGI env
  my $req = Plack::Request->new($env);
  my $path_info = $req->path_info;
  my $requested_file=join('','/var/www/html',$path_info);

  my $s = $GoogleCloudDataproc::CondaMirror::ThinProxy::svr;
  my $mech = $GoogleCloudDataproc::CondaMirror::ThinProxy::mech;

  # When requesting repodata.json, always fetch from upstream
  if ( $path_info =~ /repodata\.json(\.zst|\.gz|\.xz|.zip)?$/ ){
    my $suffix = $1;
    $requested_file='/tmp/repodata.json' . ( $suffix ? $suffix : '' );
    unlink $requested_file if -f $requested_file;
  }

  if( ! -f $requested_file ) {
    $s->log_serror(Apache2::Log::LOG_MARK, Apache2::Const::LOG_INFO,
                     APR::Const::SUCCESS, "requested file ${path_info}");
    # Unless the file already exists, fetch it from upstream
    my $src_url = join('','https://conda.anaconda.org', $path_info);

    if ( my $response = $mech->get( $src_url )->is_success() ) {
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
