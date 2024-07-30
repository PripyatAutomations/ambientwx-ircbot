#!/usr/bin/perl
# Networks, servers, channels, and users exist in sql.
# If you want to modify them, either insert initial values and set over
# IRC or type /help in the script (NYI)
#
#
# XXX: Deal with alternate nicks, nick changes, nick collisions.
# XXX: Deal with channel join issues (+k, +b, etc)
# XXX: Throttle commands
# XXX: minimal POE Readline interface (or just text if missing) to add users/nets/servers/chans
# XXX: Ensure only one connection per network
use strict;
use warnings;
use Data::Dumper;
use DBI;
use HTTP::Request;
use LWP::UserAgent;
use POE qw(Component::IRC);
use Time::Piece;
#use Linux::Inotify2;
use YAML::XS;

my $config_file = $ENV{HOME} . "/ambientwx.yml";

########################################
my $version = "20240728.01";
my $config = YAML::XS::LoadFile($config_file);

# Pull out some oft used configuration values
my $debug = $config->{irc}->{debug};
my $database = $config->{irc}->{database};
my $wx_file = $config->{irc}->{wx}->{path};
my $sensors_data_file = $config->{irc}->{sensors}->{path};

# Open our database
my $dbh = DBI->connect("dbi:SQLite:dbname=$database", "", "", { RaiseError => 1, AutoCommit => 1 }) or die $DBI::errstr;

################
# Global state #
################
my %networks;
my %servers;
my %users;
my %channels;

###############################################################################
# Database #
###############################################################################
sub load_users {
   print "* Loading users from database....\n";
   my $sth_users = $dbh->prepare("SELECT * FROM users");
   $sth_users->execute();
   while (my $row = $sth_users->fetchrow_hashref) {
      my ($uid, $user, $nick, $ident, $host, $pass, $privileges, $disabled) = (
         $row->{uid},
         $row->{user},
         $row->{nick},
         $row->{ident},
         $row->{host},
         $row->{pass},
         $row->{privileges} || '',
         $row->{disabled} || 1
      );

      print " - $user ($uid) is ${nick}!${ident}\@${host} with privileges [$privileges]" . ($disabled ? "" : "disabled") . "\n";
      next if ($disabled);

      $users{$row->{uid}} = {
         nick       => $nick,
         user       => $user,
         ident      => $ident,
         host       => $host,
         pass       => $pass,
         privileges => $privileges,
         disabled   => $disabled
      };
   }
}

sub load_networks {
   my $sth_networks = $dbh->prepare("SELECT * FROM networks");
   $sth_networks->execute();

   while (my $network_row = $sth_networks->fetchrow_hashref) {
      my $nid = $network_row->{nid};
      my $network = $network_row->{network};
      my $nick = $network_row->{nick};
      my $realname = $network_row->{realname};
      my $ident = $network_row->{ident};

      print "* Adding network $network ($nid) as $nick\n";
      $networks{$nid} = {
          network => $network,
          nid => $nid,
          realname => $realname,
          ident => $ident,
          nick => $nick
      };

      # Query if there are are servers for this network and load them...
      load_servers($nid);
      # load channels if present
      load_channels($nid);
   }
}

sub load_servers {
   my ($nid) = @_;

   my $sth_servers = $dbh->prepare("SELECT * FROM servers WHERE nid = $nid");
   $sth_servers->execute();
   my $servers_count = 0;
   my $network = get_network_name($nid);

   while (my $row = $sth_servers->fetchrow_hashref) {
      my ($sid, $nid, $host, $pass, $port, $priority, $tls, $disabled) = (
         $row->{sid},
         $row->{nid},
         $row->{host},
         $row->{pass} || '',
         $row->{port} || 6667,
         $row->{priority} || 10,
         $row->{tls},
         $row->{disabled}
      );

      if ($disabled) {
         print " - skipped server $host:$port (sid: $sid) because it is disabled\n";
         next;
      }

      print " - added server $host:$port ($sid) to network $network ($nid) " . ($pass ? "*password*" : "") . "priority $priority " . ($disabled ? "*disabled*" : "") . "\n";

      $servers{$row->{sid}} = {
         nid       => $nid,
         host      => $host,
         port      => $port,
         pass      => $pass,
         priority  => $priority,
         tls       => $tls,
         disabled  => $disabled
      };
      $servers_count++;
   }

   if (!$servers_count) {
      print "*** No servers configured for network $nid ($network) --- Add some using /server add [network] [host] [port] <tls> ***\n";
   }

   return $servers_count;
}

sub get_network_name {
    my ($nid) = @_;
    
    if (exists $networks{$nid}) {
        return $networks{$nid}->{network};
    } else {
        return 'Unknown Network';
    }
}

sub get_my_nick {
    my ($nid) = @_;

    if (exists $networks{$nid}) {
       my $nick = $networks{$nid}->{nick};
       return $nick;
    } else {
       print "get_my_nick: invalid nid: $nid\n";
    }
    return 'INVALIDNICK';
}

###############################################################################
# Sensors #
###############################################################################
sub get_sensor_message {
   my @occupancy_types = ( 'car', 'cat', 'dog', 'person', 'bicycle' );
   my $occupancy_valid = 0;
   my $objdet_cars = 0;
   my $objdet_cats = 0;
   my $objdet_dogs = 0;
   my $objdet_people = 0;
   my $objdet_bikes = 0;
   my $occupancy_msg = "";

   if ($occupancy_valid) {
      $occupancy_msg = " There are ${objdet_cars} cars, ${objdet_cats} cats, ${objdet_dogs} dogs, and ${objdet_people} people with ${objdet_bikes} bikes in sight.🌮";
   } else {
      $occupancy_msg = " Occupancy data expired.";
   }
   return $occupancy_msg;
}

#################
# IRC callbacks #
#################
sub handle_default {
  return 0 if ($debug < 8);

  my ($event, $args) = @_[ARG0 .. $#_];
  print "unhandled $event\n";
  my $arg_number = 0;
  foreach (@$args) {
     print "  ARG$arg_number = ";
     if (ref($_) eq 'ARRAY') {
        print "$_ = [", join(", ", @$_), "]\n";
     } else {
        print "'$_'\n";
     }
     $arg_number++;
  }
  return 0;
}

sub bot_start {
    print "* ENTER bot_start\n";
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    my $nid = $heap->{nid};
    my $network = get_network_name($nid);
    my $nick = get_my_nick($nid);
    my $server = $heap->{server};
    my $irc = $heap->{irc};
    $heap->{debug} = 1;

    $heap->{irc}->yield(register => "all");
    print "Connecting as $nick on network: $network ($nid) via server: $server\n";
    $heap->{irc}->yield(connect => { Nick => $nick, Server => $server });
    print "* EXIT bot_start\n";
}

sub on_public_message {
   my ($kernel, $who, $where, $msg, $heap) = @_[KERNEL, ARG0, ARG1, ARG2, HEAP];
   my $nick = (split /!/, $who)[0];
   my $channel = $where->[0];
   my $server = $heap->{server};
   my $sender = "$nick\@$server/$channel";

   print "[$sender] $msg\n";

   if ($msg =~ /^!adsb$/i) {
      send_adsb($channel, $heap);
   } elsif ($msg =~ /^!birds$/i) {
      send_birds($channel, $heap);
   } elsif ($msg =~ /^!tacos$/i) {
      send_wx($channel, $heap);
   } elsif ($msg =~ /^!help$/i) {
      send_help($nick, $heap);
   } elsif ($msg =~ /^!quit$/i) {
      if (is_privileged($nick, $heap->{nid}, 'quit')) {
         print "* Got QUIT command from $nick in $channel, exiting!\n";
         $heap->{irc}->yield(shutdown => "Bot is shutting down");
      }
   }
}

sub on_private_message {
   my ($kernel, $who, $target, $msg, $heap) = @_[KERNEL, ARG0, ARG1, ARG2, HEAP];
   my $irc = $heap->{irc};
   my $nick = (split /!/, $who)[0];
   my $server = $heap->{server};

   print "*$nick\@[$server]* $msg\n";

   if ($msg =~ /^!adsb$/i) {
      send_adsb($nick, $heap);
   } elsif ($msg =~ /^!birds$/i) {
      send_birds($nick, $heap);
   } elsif ($msg =~ /^!tacos$/i) {
      send_wx($nick, $heap);
   } elsif ($msg =~ /^!help$/i) {
      send_help($nick, $heap);
   } elsif ($msg =~ /^!quit$/) {
      if (is_privileged($nick, $heap->{nid}, 'quit')) {
         print "* Got QUIT command from $nick, exiting!\n";
         $heap->{irc}->yield(shutdown => "Bot is shutting down");
      }
   }
}

# Ping ourselves, but only if we haven't seen any traffic since the last ping. 
# This prevents us from pinging ourselves more than necessary (which tends to get noticed by server operators).
#sub bot_do_autoping {
#   my ($kernel, $heap) = @_[KERNEL, HEAP];

#   $kernel->post(poco_irc => userhost => $heap->{nick})
#      unless $heap->{seen_traffic};

#   $heap->{seen_traffic} = 0;
#   $kernel->delay(autoping => 300);
#}

sub bot_reconnect {
   my $kernel = $_[KERNEL];

   # Throttle reconnecting
#   $kernel->delay(autoping => undef);
#   $kernel->delay(connect  => 60);
}

sub on_shutdown {
   my ($kernel, $heap) = @_[KERNEL, HEAP];
   print "Shutting down...\n";
   $dbh->disconnect;
   POE::Kernel->stop();
   exit();
}

sub on_registered {
   my ($kernel, $heap) = @_[KERNEL, HEAP];
   my $nid = $heap->{nid};
   my $server = $heap->{server};
   my $network = get_network_name($nid);
   print "Registered on $network ($nid) via $server\n";
}

# Once connected, start a periodic timer to ping ourselves.  This
# ensures that the IRC connection is still alive.  Otherwise the TCP
# socket may stall, and you won't receive a disconnect notice for
# up to several hours.
sub on_bot_001 {
   my ($kernel, $sender, $heap) = @_[KERNEL, SENDER, HEAP];
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);

   print "* Connected to network $network ($nid)\n";
#   $heap->{seen_traffic} = 1;
#   $kernel->delay(autoping => 300);
   join_channels($nid);
}

sub on_connected {
   my ($kernel, $heap) = @_[KERNEL, HEAP];
   my $nid = $heap->{nid};
   print "Connected to $nid\n";
}

sub create_irc_connection {
    my ($server_id) = @_;
    my $server = $servers{$server_id} or die "Server ID $server_id not found!";
    
    my $nid = $server->{nid};
    my $host = $server->{host};
    my $port = $server->{port};
    my $nick = get_my_nick($nid);
    my $network = get_network_name($nid);
    my $pass = $server->{pass} || '';
    my $dest = "$host:$port";

    print "* Creating IRC connection to $network ($nid) as $nick via $dest\n";
    my $irc = POE::Component::IRC->spawn(
        Nick     => $nick,
        Server   => $host,
        Port     => $port,
        Password => $pass,
    );

    # Create a POE session for the IRC connection
    POE::Session->create(
        inline_states => {
            _start            => \&bot_start,
            connected         => \&on_connected,
            irc_001           => \&on_bot_001,
            irc_disconnected  => \&bot_reconnect,
            irc_error         => \&bot_reconnect,
            irc_socketerr     => \&bot_reconnect,
            irc_msg           => \&on_private_message,
            irc_notice        => \&on_private_message,
            irc_private       => \&on_private_message,
            irc_public        => \&on_public_message,
            irc_registered    => \&on_registered,
            irc_shutdown      => \&on_shutdown,
            shutdown          => \&on_shutdown,
            _default          => \&handle_default,
        },
        heap  => {
            nid               => $nid,
            server            => $dest,
            irc               => $irc
        }
    );
    return $irc;
}

sub connect_all_servers {
   foreach my $server_id (keys %servers) {
      my $irc = create_irc_connection($server_id);
   }
}

######################################################
# Channel Utilities #
######################################################
sub load_channels {
   my ($nid) = @_;
   my $network_name = get_network_name($nid);

   # Reload the channel list and apply it
   print "* Loading channels for network $network_name ($nid):\n";
   my $sth_channels = $dbh->prepare("SELECT * FROM channels WHERE nid = ?");
   $sth_channels->execute($nid);

   while (my $channel_row = $sth_channels->fetchrow_hashref) {
      my ($cid, $channel, $key, $disabled) = (
         $channel_row->{cid},
         $channel_row->{channel},
         $channel_row->{key} || '',
         $channel_row->{disabled}
      );

      if ($disabled) {
         print " - skipping $channel ($cid) because it is disabled.\n";
         next;
      }

      print " - adding channel: $channel ($cid) " . ($key ? " [key]" : "") . "on $network_name ($nid) " . ($disabled ? "*disabled*" : "") . " \n";

      # Store the channel information in the %channels hash
      $channels{$cid} = {
         channel  => $channel,
         key      => $key,
         nid      => $nid,
         disabled => $disabled
      };

      # Also store channels in the %networks hash for easy access later
      $networks{$nid}{channels}{$cid} = {
         channel  => $channel,
         key      => $key,
         disabled => $disabled
      };
   }
}

sub join_channels {
   my ($nid) = @_;
   my $successes = 0;

   # Fetch the list of channels for the given network ID
   if (exists $networks{$nid} && exists $networks{$nid}{channels}) {
       foreach my $cid (keys %{ $networks{$nid}{channels} }) {
           my $channel_info = $networks{$nid}{channels}{$cid};
           my $channel = $channel_info->{channel};
           my $key = $channel_info->{key} || '';

           # Join the channel (implementation depends on your IRC library)
           # Example placeholder:
           # $heap->{irc}->yield(join => $channel, $key);
           print "Joining channel $channel with key $key...\n";
           $successes++;  # Increment successes for each channel joined
       }
   } else {
       print "No channels found for network ID $nid.\n";
   }

   return $successes;
}

sub join_all_channels {
   my $successes = 0;

   foreach my $nid (keys %networks) {
       my $network_name = $networks{$nid}{network};
       print "Joining all channels for network $network_name ($nid)...\n";
       $successes += join_channels($nid);
   }

   return $successes;
}

###############################################################################
# Weather Utilities #
###############################################################################
sub read_wx_data {
    my %wx_data;

    # Here we read it from the local file
    if ($config->{irc}->{wx}->{type} eq 'cache') {
       open(my $fh, '<', $wx_file) or die "Unable to open $wx_file: $!";

       while (my $line = <$fh>) {
           chomp $line;
           my ($key, $value) = split /:\s*/, $line, 2;
           $wx_data{$key} = $value;
           print "read [$key]: $value\n" if ($debug >= 9);
       }

       close $fh;
    # Or via HTTP
    } elsif ($config->{irc}->{wx}->{type} eq 'http') {
       print "* Fetching WX from remote host\n";
       my $ua = LWP::UserAgent->new;
       $ua->agent("rustybot/$version");
       my $wx_url = $config->{irc}->{wx}->{url};
       my $req = HTTP::Request->new(GET => $wx_url);
       my $res = $ua->request($req);

       if ($res->is_success) {
          print "  -> Success: ", $res->content, "\n" if ($debug >= 3);
          foreach my $line (split /\R/, $res->content) {
              chomp $line;
              my ($key, $value) = split /:\s*/, $line, 2;
              $wx_data{$key} = $value;
              print "http_read [$key]: $value\n" if ($debug >= 9);
          }
       } else {
          print "  -> ERROR: ", $res->status_line, "\n";
       }
    } else {
       die('Invalid wx type: ' . $config->{irc}->{wx}->{type} . ", please fix config!\n");
    }

    return %wx_data;
}

sub angle_to_direction {
    my ($angle) = @_;

    # Define the directions and their corresponding angle ranges
    my @directions = qw(N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW);

    # Make sure angle is within 0 to 360 degrees range
    $angle = ($angle < 0) ? ($angle % 360) + 360 : $angle % 360;

    # Calculate the index in the directions array
    my $index = int(($angle + 11.25) / 22.5);

    return $directions[$index % 16];
}

sub wind_speed_description {
    my ($speed) = @_;

    # Define the thresholds and corresponding descriptions in mph
    my %speed_ranges = (
       calm => [0, 1],
       light => [1, 10],
       moderate => [10, 20],
       fresh => [20, 30],
       strong => [30, 40],
       gale => [40, 55],
       storm => [55, 73],
       hurricane => [73, 999]  # 999 (or any high value) represents "hurricane" category
    );

    # Determine the appropriate description
    foreach my $desc (sort { $speed_ranges{$a}[0] <=> $speed_ranges{$b}[0] } keys %speed_ranges) {
       my ($lower, $upper) = @{$speed_ranges{$desc}};
       if ($speed >= $lower && $speed < $upper) {
          return $desc;
       }
   }

   return "unknown";  # Default case (if speed doesn't match any range)
}

sub mph_to_knots {
   my ($mph) = @_;
   my $knots = $mph * 0.868976;  # Conversion factor from mph to knots
   return sprintf("%.2f", $knots);  # Round to 2 decimal places
}

sub feels_like {
   my ($temperature_fahrenheit, $humidity_percent, $wind_speed_mph, $wind_direction_degrees) = @_;

   # Calculate Heat Index (for warm conditions)
   my $heat_index = calculate_heat_index($temperature_fahrenheit, $humidity_percent);

   # Calculate Wind Chill (for cold conditions)
   my $wind_chill = calculate_wind_chill($temperature_fahrenheit, $wind_speed_mph);

   # Determine the final "Feels Like" temperature based on conditions
   my $feels_like_temperature = $temperature_fahrenheit;  # Default to actual temperature

   if ($temperature_fahrenheit >= 80) {
      $feels_like_temperature = $heat_index;
   } elsif ($temperature_fahrenheit <= 50) {
      $feels_like_temperature = $wind_chill;
   } else {
      # For temperatures between 50°F and 80°F, a basic adjustment can be considered
      # Here we could use a simple average of heat index and wind chill, or a more complex formula
      # depending on the specific needs and standards you want to apply.
      # For simplicity, we'll just use the temperature itself as the feels like temperature.
   }

   return sprintf("%.1f", $feels_like_temperature);
}

sub calculate_heat_index {
   my ($temperature_fahrenheit, $humidity_percent) = @_;
   # Formula to calculate heat index
   my $heat_index = -42.379 + 2.04901523 * $temperature_fahrenheit + 10.14333127 * $humidity_percent
                    - 0.22475541 * $temperature_fahrenheit * $humidity_percent
                    - 0.00683783 * $temperature_fahrenheit * $temperature_fahrenheit
                    - 0.05481717 * $humidity_percent * $humidity_percent
                    + 0.00122874 * $temperature_fahrenheit * $temperature_fahrenheit * $humidity_percent
                    + 0.00085282 * $temperature_fahrenheit * $humidity_percent * $humidity_percent
                    - 0.00000199 * $temperature_fahrenheit * $temperature_fahrenheit * $humidity_percent * $humidity_percent;
   return $heat_index;
}

sub calculate_wind_chill {
   my ($temperature_fahrenheit, $wind_speed_mph) = @_;
   # Formula to calculate wind chill
   my $wind_chill = 35.74 + 0.6215 * $temperature_fahrenheit - 35.75 * ($wind_speed_mph ** 0.16)
                   + 0.4275 * $temperature_fahrenheit * ($wind_speed_mph ** 0.16);
   return $wind_chill;
}

sub get_wx_message {
   my ($heap) = @_;
   my %wx_data = read_wx_data();
   my $wx_updated = localtime->strftime('%Y-%m-%d %H:%M:%S');
   my $wx_temp = $wx_data{'tempf'} . "°F";
   my $wx_humid = $wx_data{'humidity'} . "%";

   my $wx_wind_direction = $wx_data{'winddir'} . "°";
   my $wx_wind_cardinal = angle_to_direction($wx_data{'winddir'});
   my $wx_wind_mph = $wx_data{'windspeedmph'} . " MPH";
   my $wx_wind_knots = mph_to_knots($wx_data{'windspeedmph'}) . " Kts";
   my $wx_wind_gust_mph = $wx_data{'windgustmph'} . " MPH";
   my $wx_wind_gust_daily_mph = $wx_data{'maxdailygust'} . " MPH";
   my $wx_wind_gust_daily_knots = mph_to_knots($wx_data{'maxdailygust'}) . " Kts";
   my $wx_wind_word = wind_speed_description($wx_data{'windspeedmph'});

   my $wx_rain_today = $wx_data{'dailyrainin'} . " in";
   my $wx_rain_past_week = $wx_data{'weeklyrainin'} . " in";
   my $wx_feels_like = feels_like($wx_data{'tempf'}, $wx_data{'humidity'}, $wx_data{'windspeedmph'}, $wx_data{'winddir'}) . "°F";
   my $wx_uv_index = $wx_data{'uv'};
   $wx_uv_index = 0 if ($wx_data{'uv'} eq 'Not provided');
   my $wx_solar_rad = $wx_data{'solarradiation'} . " W/m^2";

   my $occupancy_msg = get_sensor_message();

   my $message = "🌮 At ${wx_updated}, it is ${wx_temp} with ${wx_humid} humidity."
               . " The wind is ${wx_wind_word}, ${wx_wind_direction} ${wx_wind_cardinal} at ${wx_wind_mph} (${wx_wind_knots}) with"
               . " gusts to ${wx_wind_gust_mph} (${wx_wind_gust_daily_mph} / ${wx_wind_gust_daily_knots} max today)."
               . " There has been ${wx_rain_today} rain today, for a total of ${wx_rain_past_week} the past week."
               . " It feels like ${wx_feels_like} with a UV Index of ${wx_uv_index}."
               . " Solar radiation is ${wx_solar_rad}.${occupancy_msg}";
   return $message;
}

sub send_wx {
   my ( $target, $heap ) = @_;
   my $message = get_wx_messsage($heap);
   $heap->{irc}->yield(privmsg => $target => $message);
}

###############################################################################
# Responses to IRC commands (!triggers) #
###############################################################################
sub send_adsb {
   return 0;
}

sub send_help {
   my ( $target, $heap ) = @_;
   my $irc = $heap->{irc};
   $irc->yield(privmsg => $target => "*** HELP ***");
#    $irc->yield(privmsg => $target => "!adsb       Spotted air traffic nearby");
   $irc->yield(privmsg => $target => "!birds      Get a summary of birds heard today by BirdNET");
   $irc->yield(privmsg => $target => "!tacos      Get weather at my QTH");
   $irc->yield(privmsg => $target => "*");
   $irc->yield(privmsg => $target => "**** Admin Only ****");
   $irc->yield(privmsg => $target => "!quit       Terminate the bot");
}

sub send_birds {
   my ( $target, $heap ) = @_;
   my $irc = $heap->{irc};
#    update_birds();
   my $birds = 0;
   my $bird_species_list = "(none)";
   my $birds_msg = "🐦 There are approx. ${birds} of ${bird_species_list} birds detected 🐦";
   $irc->yield(privmsg => $target => $birds_msg);
}

# User Access
sub is_privileged {
    my ($nick, $network, $cmd) = @_;
    # XXX: query database for privileges
    return 0;
}

###############################################################################
# Start up #
###############################################################################

# Load bot user accounts
load_users();

# Load networks and servers from database
load_networks();

# Connect to all saved servers
connect_all_servers();

$poe_kernel->run();
