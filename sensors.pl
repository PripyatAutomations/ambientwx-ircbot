#!/usr/bin/perl
my $botbrand = "turdbot";
my $version = "20240730.02";
use strict;
use warnings;
use Data::Dumper;
use DBI;
use Digest::SHA qw(sha256_hex);
use Getopt::Long;
use LWP::UserAgent;
use HTTP::Request;
use JSON;
use POE;
use POE::Component::Client::DNS;
use URI::Escape;
use Time::Piece;
use Time::HiRes qw(sleep);  # For high-resolution sleep
use YAML::XS;

my $config_file = "config.yml";
   $config_file = $ENV{HOME} . "/ambientwx.yml" if (! -e $config_file);
die("Missing configuration - place it at $config_file or ./config.yml and try again!\n") if (! -e $config_file);
my $config = YAML::XS::LoadFile($config_file);
my $debug = $config->{sensors}->{debug};
my $save_json_file = $config->{cache}->{sensors}->{path};
my $list = 0;

GetOptions(
    'list' => \$list,
) or die("Error in command line arguments\n");

# Database connection parameters
my $db_file = $config->{sensors}->{database};
my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", "", "", { RaiseError => 1 }) or die $DBI::errstr;

# Main program
my %allowed_sensors;
my @sensors;
my @export_sensors;

# Function to load allowed sensors into %allowed_sensors
sub load_allowed_sensors {
    my %allowed_sensors;
    my $sth = $dbh->prepare("SELECT sensor_name FROM sensor_acl WHERE allowed = 1 AND disabled != 1");
    $sth->execute();
    while (my $row = $sth->fetchrow_arrayref) {
        my $pattern = $row->[0];
        $allowed_sensors{$pattern} = qr/$pattern/;
    }
    return %allowed_sensors;
}

# Function to check if a sensor is allowed
sub check_allowed_sensor {
    my ($sensor_name, %allowed_sensors) = @_;
    foreach my $pattern (keys %allowed_sensors) {
        return 1 if $sensor_name =~ $allowed_sensors{$pattern};
    }
    return 0;
}

sub get_home_assistant_sensors {
    my $ha_url = $config->{sensors}->{hass_api_url};
    my $ha_token = $config->{sensors}->{hass_api_key};

    my $ua = LWP::UserAgent->new;
    my $req = HTTP::Request->new(GET => "${ha_url}/states");
    $req->header('Authorization' => "Bearer $ha_token");
    
    my $res = $ua->request($req);

    if ($res->is_success) {
        my $json = decode_json($res->content);
        
        print "Decoded JSON: ", Dumper($json) if ($debug >= 9);

        # Support storing available sensor in the database, for query later with --list        
        if (ref($json) eq 'ARRAY') {
            # Prepare the insert statement
            my $sth_insert = $dbh->prepare("INSERT OR REPLACE INTO available_sensors (entity_id, last_changed, friendly_name, icon, device_class, state) VALUES (?, ?, ?, ?, ?, ?);");

            # Array to store matching sensors
            my @export_sensors;
            
            # Begin transaction
            $dbh->begin_work;
            
            eval {
                # XXX: We should probably add more data, but this is probably enough to figure out which entities one wants to allow...
                foreach my $entity (@$json) {
                    my $entity_id = $entity->{entity_id};
                    my $last_changed = $entity->{last_changed} || 0;
                    my $friendly_name = $entity->{attributes}{friendly_name} || $entity_id;
                    my $icon = $entity->{attributes}{icon} || 'default-sensor';
                    my $device_class = $entity->{attributes}{device_class} || '';
                    my $state = $entity->{state} || 'unknown';
                    $sth_insert->execute($entity_id, $last_changed, $friendly_name, $icon, $device_class, $state);

                    # Save the entire entity state
                    push @export_sensors, $entity if (check_allowed_sensor($entity_id, %allowed_sensors))
                }

                # Commit transaction
                $dbh->commit;
            };

            if ($@) {
                # Rollback transaction on error
                warn "Transaction aborted: $@";
                $dbh->rollback;
            }

            # Dump matching sensors to a file
            if (@export_sensors) {
               # save to our dump file
               open my $fh, '>', $save_json_file or die "Couldn't open file $save_json_file for writing: $!";
               my %data = (
                  sensors => \@export_sensors,
               );

               # Encode the data as JSON
               my $json_data = encode_json(\%data);

               print $fh "$json_data\n";
               close $fh;

               # Here we loop over our forwarders and send to them
               my $forwarders = $config->{sensors}->{forwarders};
               foreach my $name (keys %$forwarders) {
                  my $fwd = $forwarders->{$name};

                  if ($fwd->{disabled}) {
                    print "* skipping disabled forwarder $name\n";
                    next;
                  }

                  my $url = $fwd->{url};
                  my $type = $fwd->{type};
                  my $ua = LWP::UserAgent->new;

                  if ($type eq 'GET') {
                     # URL encode the JSON string
                     my $encoded_json = uri_escape($json_data);
                     my $get_url = "${url}/?data=$encoded_json";
                     print "Using URL: $get_url\n" if ($debug >= 7);
                     my $req = HTTP::Request->new(GET => $get_url);
                     my $res = $ua->request($req);

                     if ($res->is_success) {
                        print "* Succesfully forwarded to $name via HTTP GET\n";
                     } else {
                        warn "* Failed forwarding to $name via HTTP GET: " . $res->status_line . "\n";
                     }
                  } elsif ($type eq 'POST') {
                     print "Using URL: $url\n" if ($debug >= 4);
                     my $req = HTTP::Request->new(POST => $url);
                     $req->header('Content-Type' => 'application/json');
                     $req->content($json_data);
                     my $res = $ua->request($req);

                     if ($res->is_success) {
                        print "* Succesfully forwarded to $name via HTTP POST, response: " . $res->decoded_content . "\n";
                     } else {
                        warn "* Failed forwarding to $name via HTTP POST: " . $res->status_line . "\n";
                     }
                  } else {
                     die("* Unsupported type $type in forwarder $name - fix your config!\n");
                  }
               }
            }
        } else {
            die "Expected an array reference, but got: ", ref($json);
        }
    } else {
        die $res->status_line;
    }
}

sub list_available_sensors {
    my $sth = $dbh->prepare("SELECT entity_id, last_changed, friendly_name, icon, device_class, state FROM available_sensors");
    $sth->execute();

    while (my $row = $sth->fetchrow_hashref) {
        print "Entity ID: $row->{entity_id}\n";
        print "Last Changed: $row->{last_changed}\n";
        print "Friendly Name: $row->{friendly_name}\n";
        print "Icon: $row->{icon}\n";
        print "Device Class: $row->{device_class}\n";
        print "State: $row->{state}\n";
        print "-----------------------\n";
    }
}

%allowed_sensors = load_allowed_sensors();

if ($list) {
    list_available_sensors();
    $dbh->disconnect();
    exit 0;
}

my $refresh_interval = $config->{sensors}->{refresh} || 60;

while (1) {
    @sensors = get_home_assistant_sensors();

    foreach my $sensor (@export_sensors) {
        print "sensor: " . Dumper($sensor) . "\n";
        if (check_allowed_sensor($sensor->{entity_id}, %allowed_sensors)) {
            print "$sensor->{entity_id} is allowed\n";
        } else {
            print "$sensor->{entity_id} is not allowed\n";
        }
    }

    # Sleep before the next iteration
    print "Waiting for $refresh_interval seconds...\n";
    sleep($refresh_interval);  # Sleep for the specified interval
}
