#!/usr/bin/env perl

use strict;
use warnings;
use Apache2::ServerUtil ();
use Apache2::Log;
use Cpanel::JSON::XS;
use WWW::Mechanize ();

use vars qw($repodata $mech $svr);

package GoogleCloudDataproc::CondaMirror::ThinProxy;

BEGIN {
  use Apache2::Const -compile => qw(LOG_DEBUG LOG_INFO);
  return unless Apache2::ServerUtil::restart_count() > 1;

  require Plack::Handler::Apache2;
  our $mech = WWW::Mechanize->new();
  our $svr = Apache2::ServerUtil->server;
  $svr->loglevel(Apache2::Const::LOG_INFO);
  our $repodata = {};
#  my $response = $mech->get('https://conda.anaconda.org/conda-forge/linux-64/repodata.json');
#  if( $response->is_success ){
#    $repodata->{'linux-64'}  = decode_json $response->decoded_content;
#  }
#  $mech->get('https://conda.anaconda.org/conda-forge/noarch/repodata.json');
#  if( $response->is_success ){
#    $repodata->{'noarch'}  = decode_json $response->decoded_content;
#  }
}

1; # file must return true!
