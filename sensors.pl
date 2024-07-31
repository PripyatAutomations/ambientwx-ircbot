#!/usr/bin/perl
my $botbrand = "turdbot";
my $version = "20240730.02";
use strict;
use warnings;
use Data::Dumper;
use DBI;
use Digest::SHA qw(sha256_hex);
use Getopt::Long;
use JSON;
use HTTP::Request;
use LWP::UserAgent;
use POE;
use POE::Component::Client::DNS;
use Time::Piece;
use Time::HiRes qw(sleep);  # For high-resolution sleep
use YAML::XS;

my $config_file = "config.yml";
   $config_file = $ENV{HOME} . "/ambientwx.yml" if (! -e $config_file);
die("Missing configuration - place it at $config_file or ./config.yml and try again!\n") if (! -e $config_file);
my $config = YAML::XS::LoadFile($config_file);
my $debug = $config->{sensors}->{debug};
my $save_yaml = $config->{sensors}->{save_yaml};
my $save_yaml_file = $config->{sensors}->{yaml_file};
my $save_txt_file = $config->{sensors}->{txt_file};
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
        
        print "Decoded JSON: ", Dumper($json) if ($debug >= 6);
        
        if (ref($json) eq 'ARRAY') {
            # Prepare the insert statement
            my $sth_insert = $dbh->prepare("INSERT OR REPLACE INTO available_sensors (entity_id, last_changed, friendly_name, icon, device_class, state) VALUES (?, ?, ?, ?, ?, ?);");

            # Array to store matching sensors
            my @export_sensors;
            
            # Begin transaction
            $dbh->begin_work;
            
            eval {
                foreach my $entity (@$json) {
                    my $entity_id = $entity->{entity_id};
                    my $last_changed = $entity->{last_changed} || 0;
                    my $friendly_name = $entity->{attributes}{friendly_name} || $entity_id;
                    my $icon = $entity->{attributes}{icon} || 'default-sensor';
                    my $device_class = $entity->{attributes}{device_class} || '';
                    my $state = $entity->{state} || 'unknown';

                    # Add sensor to available_sensors table
                    $sth_insert->execute($entity_id, $last_changed, $friendly_name, $icon, $device_class, $state);
                    
                    # Check if the sensor is allowed and not disabled
                    if (check_allowed_sensor($entity_id, %allowed_sensors)) {
                        # If so, add it to the export_sensors list
                        push @export_sensors, {
                            entity_id => $entity_id,
                            last_changed => $last_changed,
                            friendly_name => $friendly_name,
                            icon => $icon,
                            state => $state,
                            device_class => $device_class,
                        };
                    }
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
               if ($save_yaml) {
                  open my $yfh, '>', $save_yaml_file or die "Could not open file for writing: $!";
                  print $yfh YAML::XS::Dump(\@export_sensors);
                  close $yfh;
                  print "Matching sensors have been dumped to $save_yaml_file\n";
               }

               # save to our dump file
               open my $fh, '>', $save_txt_file or die "Couldn't open file for writing: $!";
               foreach my $ts (@export_sensors) {
                  my $entity = $ts->{entity_id};
                  my $last_changed = $ts->{last_changed};
                  my $friendly_name = $ts->{friendly_name};
                  my $icon = $ts->{icon};
                  my $state = $ts->{state};
                  my $device_class = $ts->{device_class};
                  my $idata = "[entry]\n" .
                              "entity-id: $entity\n" .
                              "last-changed: $last_changed\n" .
                              "friendly-name: $friendly_name\n" .
                              "icon: $icon\n" .
                              "state: $state\n" .
                              "device-class: $device_class\n" .
                              "[!entry]\n";
                  print $fh $idata;
               }
               close $fh;
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
@sensors = get_home_assistant_sensors();

if ($list) {
    list_available_sensors();
    $dbh->disconnect();
    exit 0;
}

my $refresh_interval = $config->{sensors}->{refresh} || 60;

while (1) {
    get_home_assistant_sensors();

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
