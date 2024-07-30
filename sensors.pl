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
use YAML::XS;

my $config_file = "config.yml";
   $config_file = $ENV{HOME} . "/ambientwx.yml" if (! -e $config_file);
die("Missing configuration - place it at $config_file or ./config.yml and try again!\n") if (! -e $config_file);
my $config = YAML::XS::LoadFile($config_file);
my $debug = $config->{sensors}->{debug};

my $list = 0;

GetOptions(
    'list' => \$list,
) or die("Error in command line arguments\n");

# Database connection parameters
my $db_file = $config->{sensors}->{database};
my $dbh = DBI->connect("dbi:SQLite:dbname=$db_file", "", "", { RaiseError => 1 }) or die $DBI::errstr;

# Main program
my %allowed_sensors = load_allowed_sensors();
my @sensors = get_home_assistant_sensors();
my @export_sensors;

# Function to load allowed sensors into %allowed_sensors
sub load_allowed_sensors {
    my %allowed_sensors;
    my $sth = $dbh->prepare("SELECT sensor_name FROM sensor_acl WHERE allowed = 1 AND disabled != 1");
    $sth->execute();
    while (my @row = $sth->fetchrow_array()) {
        $allowed_sensors{$row[0]} = 1;
    }
    return %allowed_sensors;
}

# Function to check if a sensor is allowed
sub check_allowed_sensor {
#    my ($sensor_name, %allowed_sensors) = @_;
#    return exists $allowed_sensors{$sensor_name};
   return 1;
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
            my $sth_insert = $dbh->prepare("INSERT OR REPLACE INTO available_sensors (entity_id, last_changed, friendly_name, icon, device_class) VALUES (?, ?, ?, ?, ?);");
            
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
                    
                    # Add sensor to available_sensors table
                    $sth_insert->execute($entity_id, $last_changed, $friendly_name, $icon, $device_class);
                    
                    # Check if the sensor is allowed and not disabled
                    if (exists $allowed_sensors{$entity_id}) {
                        push @export_sensors, {
                            entity_id => $entity_id,
                            last_changed => $last_changed,
                            friendly_name => $friendly_name,
                            icon => $icon,
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
                open my $fh, '>', 'matching_sensors.yml' or die "Could not open file for writing: $!";
                print $fh YAML::XS::Dump(\@export_sensors);
                close $fh;
                print "Matching sensors have been dumped to matching_sensors.yml\n";
            }
        } else {
            die "Expected an array reference, but got: ", ref($json);
        }
    } else {
        die $res->status_line;
    }
}

sub list_available_sensors {
    my $sth = $dbh->prepare("SELECT entity_id, last_changed, friendly_name, icon, device_class FROM available_sensors");
    $sth->execute();
    
    while (my $row = $sth->fetchrow_hashref) {
        print "Entity ID: $row->{entity_id}\n";
        print "Last Changed: $row->{last_changed}\n";
        print "Friendly Name: $row->{friendly_name}\n";
        print "Icon: $row->{icon}\n";
        print "Device Class: $row->{device_class}\n";
        print "-----------------------\n";
    }
}

foreach my $sensor (@sensors) {
    if (check_allowed_sensor($sensor, %allowed_sensors)) {
        print "$sensor is allowed\n";
    } else {
        print "$sensor is not allowed\n";
    }
}

if ($list) {
    list_available_sensors();
    $dbh->disconnect();
    exit 0;
}

$dbh->disconnect();
