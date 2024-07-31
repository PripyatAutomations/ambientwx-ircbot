#!/usr/bin/perl
# Handle incoming HTTP GETs from the weather station
# - Sanitize them to remove sensors we don't want to export
# - Upload (GET or POST) to other URLs
# - Save to a local file for various backends/sharing options
use strict;
use warnings;
use Data::Dumper;
use HTTP::Daemon;
use HTTP::Status;
use LWP::UserAgent;
use URI::Escape;
use YAML::XS;

my $version = "20240729.01";
my $config_file = "config.yml";
$config_file = $ENV{HOME} . "/ambientwx.yml" if (! -e $config_file);
die "No config file at ~/ambientwx.yml or ./config.yml! Exiting!" if (! -e $config_file);

my $config = YAML::XS::LoadFile($config_file) or die("Unable to load config $config_file\n");
my $wx_file = $config->{cache}->{wx}->{path};
my $sensors_data_file = $config->{cache}->{sensors}->{path};
my $debug = $config->{httpd}->{debug};

my $http_addr = $config->{httpd}->{bind};
my $http_port = $config->{httpd}->{port};

my $d = HTTP::Daemon->new(
   LocalAddr => $http_addr,
   LocalPort => $http_port,
   ReuseAddr => 1,
) || die "Cannot create HTTP daemon: $!\n";

print "ambientwx-proxy $version started on port ${http_addr}:${http_port}\n";

# Function to create a proper GET URI
sub create_get_url {
   my ($query_params_ref, $prefix) = @_;

   my @params;
   foreach my $key (keys %$query_params_ref) {
      my $value = $query_params_ref->{$key};
      push @params, "$key=$value";
   }

   my $uri = $prefix;
   if (@params) {
      $uri .= '?' . join('&', @params);
   }

   return $uri;
}

sub handle_report_data {
    my ($query_params, $post_data, $c) = @_;
    open(my $fh, '>', $wx_file) or die("Can't open data file $wx_file");
    my $default_value = 'Not provided';
    my $outbuf = '';
    my $method = "";

    # GET request?
    if (defined($query_params)) {
       $method = "GET";
       while (my ($key, $value) = each %$query_params) {
          # Convert object references or complex types to strings
          if (ref($value)) {
             $value = ref($value);
          }
           
          $value = $default_value if !defined $value || $value eq '';
          $outbuf .= "$key: $value\n";
       }
    } elsif (defined($post_data)) {
       # POST request
       $method = "POST";
       $outbuf = $post_data;
    } else {
       die "handle_report_data with unknown method (neither query_params nor post_data supplied!)\n";
    }

    print " = $outbuf\n" if ($debug > 1);

    print $fh $outbuf;
    close $fh;

    # Dispatch it to the other backends
    foreach my $fwd (keys %{$config->{httpd}->{forwarders}}) {
        my $target = $config->{httpd}->{forwarders}->{$fwd};
        my $enabled = $target->{enabled};

        if ($enabled) {
           my $req;
           # Create LWP instance and submit
           my $ua = LWP::UserAgent->new;
           $ua->agent("ambientwx-proxy.pl/$version");

           my $url = $target->{url};
           my $res;

           if ($method eq "GET") {
              my $tmp_url = create_get_url($query_params, $url);
              print "   * Submitting to $fwd via GET\n";

              if ($debug > 1) {
                 print "   -> GET URL: $tmp_url\n";
               }

               $req = HTTP::Request->new(GET => $tmp_url);
           } elsif ($method eq "POST") {
              print "   * Submitting to $fwd via POST to $url\n";
              $req = HTTP::Request->net(POST => $url);
              $req->content($post_data);
              $res = $ua->request($req);
           } else {
              print " * Invalid configuration, skipping this forwarder ($fwd)\n";
              next;
           }

           if (defined($res)) {
              if ($res->is_success) {
                 print "    -> Success: ", $res->content, "\n";
              } else {
                 print "    -> ERROR: ", $res->status_line, "\n";
              }
           }
       } else {
           print "   * Skipping $fwd (disabled)\n";
       }
    }
}

# Parse reported Sensor messages
sub handle_report_sensors {
    my ($query_params, $post_data, $c) = @_;
    open(my $fh, '>', $sensors_data_file) or die("Can't open data file $sensors_data_file");
    my $default_value = 'Not provided';
    my $outbuf = '';

    if (defined($query_params)) {
       $outbuf = uri_unescape($query_params->{data});
    } elsif (defined($post_data)) {
       $outbuf = $post_data;
    } else {
       die "handle_report_sensors with unknown method (neither query_params nor post_data supplied!)\n";
    }
    print " = $outbuf\n" if ($debug > 1);

    print $fh $outbuf;
    close $fh;

    # Dispatch it to the other backends
    foreach my $fwd (keys %{$config->{httpd}->{sensors_forwarders}}) {
        my $target = $config->{httpd}->{sensors_forwarders}->{$fwd};
        my $enabled = $target->{enabled};

        if ($enabled) {
            my $url = $target->{url};
            my $method = $target->{type};

            # Create LWP instance and submit
            my $ua = LWP::UserAgent->new;
            $ua->agent("ambientwx-proxy.pl/$version");

            my $req;
            if ($method eq 'GET') {
               my $tmp_url = create_get_url($query_params, $url);
               print "   * Submitting SENSOR blob to $fwd via GET\n";

               if ($debug > 1) {
                   print "   -> GET URL: $tmp_url\n";
               }

               $req = HTTP::Request->new(GET => $tmp_url);
            } elsif ($method eq 'POST') {
               my $tmp_url = create_get_url($query_params, $url);
               print "   * Submitting SENSOR blob to $fwd via POST\n";

               if ($debug > 1) {
                   print "   -> POST URL: $tmp_url\n";
               }

               $req = HTTP::Request->new(POST => $tmp_url);
               $req->content($post_data);
            }

            my $res = $ua->request($req);

            if ($res->is_success) {
                print "    -> Success: ", $res->content, "\n";
            } else {
                print "    -> ERROR: ", $res->status_line, "\n";
            }
        } else {
            print "   * Skipping $fwd (disabled)\n";
        }
    }
}

###########################################################
###########################
# Handle HTTP connections #
###########################
while (my $c = $d->accept) {
   my $peer_address = $c->peerhost();
   my $peer_port = $c->peerport();
   print "Accepted connection from $peer_address:$peer_port\n";

   while (my $r = $c->get_request) {
      if ($r->method eq 'GET') {		# handle GETs (most traffic)
         my $uri = $r->uri;
         my $path = $uri->path;

         print "*** Request URL: " . $uri->as_string . "\n" if ($debug > 0);

         my %query_params;
         my $query_string = $uri->query;
         my $post_data;

         print " * GET $path\n";

         if ($query_string) {
            my @pairs = split(/[&?]/, $query_string);
            foreach my $pair (@pairs) {
               my ($key, $value) = split(/=/, $pair, 2);
               $value = uri_unescape($value);

               my @keys_to_sanitize = ('PASSKEY', 'token', 'secret');
               if (grep { $_ eq $key } @keys_to_sanitize) {
                  print "  * Sanitized $key\n" if ($debug > 1);
                  next;
               }
               $query_params{$key} = $value;
            }
         }

         if ($path eq '/graphs/') {
            print "* Request for GRAPHS - NYI\n";
            $c->send_status_line(500, "Not yet implemented");
         } elsif ($path eq '/current/') {
            # shortcut if it doesn't exist to send 204: No content to indicate no data yet
            if (! -e $wx_file) {
               print "* No data file $wx_file, sending 204 No Content\n";
               $c->send_status_line( 204, 'No data available yet, try again later' );
            } else {
               print "* Sending current conditions\n";
               $c->send_status_line(200, "OK");
               $c->send_file_response($wx_file);
            }
         } elsif ($path eq '/current/sensors/') {
            # shortcut if it doesn't exist to send 204: No content to indicate no data yet
            if (! -e $sensors_data_file) {
               print "* No data file $sensors_data_file, sending 204 No Content\n";
               $c->send_status_line( 204, 'No data available yet, try again later' );
            } else {
               print "* Sending current sensor data\n";
               $c->send_file_response($sensors_data_file);
            }
         } elsif ($path eq '/report/') {
            print "* Handling wx report\n";
            $c->send_status_line(200, "OK");
            handle_report_data(\%query_params, $c);
         } elsif ($path eq '/report/sensors/') {
            print "* Handling sensors report\n";
            $c->send_status_line(200, "OK");
            handle_report_sensors(\%query_params, $c);
         } else {
            print "* Unknown path: $path\n";
            $c->send_error(RC_NOT_FOUND);
         }
      } elsif ($r->method eq 'POST') { 		# handle POSTs
         my $post_data = $r->content;
         my $path = $r->uri->path;

         if ($path eq '/report/') {
            print "* Handling wx report (post)\n";
            $c->send_status_line(200, "OK");
            handle_report_data(undef, $post_data, $c);
         } elsif ($path eq '/report/sensors/') {
            print "* Handling sensors report (post)\n";
            $c->send_status_line(200, "OK");
            handle_report_sensors(undef, $post_data, $c);
         } else {
            print "* Unknown path: $path\n";
            $c->send_error(RC_NOT_FOUND);
         }
      } else {	# Not GET or POST
         $c->send_error(RC_METHOD_NOT_ALLOWED);
      }
   }
   $c->close;
   print "Connection closed for $peer_address:$peer_port\n";
   undef($c);
}
