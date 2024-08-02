#!/usr/bin/perl
# Networks, servers, channels, and users exist in sql.
# If you want to modify them, either insert initial values and set over
# IRC or type /help in the script (NYI)
#
# XXX: Deal with alternate nicks, nick changes, nick collisions.
# XXX: Deal with channel join issues (+k, +b, etc)
# XXX: Throttle commands
# XXX: minimal POE Readline interface (or just text if missing) to add users/nets/servers/chans
# XXX: Ensure only one connection per network
# XXX: Handle aliases (multiple nicknames)
my $botbrand = "turdbot";
my $version = "20240802.01";

# This is a possible security issue allowing uid 0 to do anything
#  - set to 0 to disable
my $allow_superuser = 0;

use strict;
use warnings;
use Data::Dumper;
use DBI;
use Digest::SHA qw(sha256_hex);
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use POE;
use POE::Component::Client::DNS;
use POE::Component::IRC;
#use POE::Component::IRC::Plugin::BotTraffic;
use POE::Component::IRC::Plugin::BotAddressed;
#use POE::Component::IRC::Plugin::Console
use Time::Seconds;
use Time::Piece;
use YAML::XS;

################
# Global state #
################
my %networks;
my %servers;
my %users;
my %channels;
my $started = time;

# Try to find our config file...
my $config_file = "config.yml";
   $config_file = $ENV{HOME} . "/ambientwx.yml" if (! -e $config_file);
die("Missing configuration - place it at $config_file or ./config.yml and try again!\n") if (! -e $config_file);
my $config = YAML::XS::LoadFile($config_file);
# Pull out some oft used configuration values
my $debug = $config->{irc}->{debug};
my $database = $config->{irc}->{database};
my $wx_file = $config->{cache}->{wx}->{path};
my $sensors_data_file = $config->{cache}->{sensors}->{path};
my $dns = POE::Component::Client::DNS->spawn();
my $dbh = DBI->connect("dbi:SQLite:dbname=$database", "", "", { RaiseError => 1, AutoCommit => 1 }) or die $DBI::errstr;

###############################################################################
# Database #
###############################################################################
sub load_users {
   undef %users;

   print "* Loading users from database....\n";
   my $sth_users = $dbh->prepare("SELECT * FROM users");
   $sth_users->execute();
   while (my $row = $sth_users->fetchrow_hashref) {
      my ($uid, $user, $ident, $host, $pass, $privileges, $disabled) = (
         $row->{uid},
         $row->{user},
         $row->{ident},
         $row->{host},
         $row->{pass},
         $row->{privileges},
         $row->{disabled}
      );

      print " - $user ($uid) is ${ident}\@${host} with privileges [$privileges]" . ($disabled ? "disabled" : "") . "\n";

      $users{$uid} = {
         user       => $user,
         ident      => $ident,
         host       => $host,
         pass       => $pass,
         privileges => $privileges,
         disabled   => $disabled,
         current_nick => '',		# do_login and on_nick will update this
         logged_in  => 0,		# do_login will set this
         alt_nicks  => []		# this will contain alternate nicks
      };

      # load alternate nicks for the user
      load_alt_nicks($uid);
   }
}

sub load_alt_nicks {
   my $uid = @_;
   my $query = "SELECT alt_nick FROM alt_nicks WHERE uid = $uid";
   my $sth = $dbh->prepare($query);
   $sth->execute();
    
   while (my $row = $sth->fetchrow_hashref) {
      my $alt_nick = $row->{alt_nick};

      if (exists $users{$uid}) {
         print " => alternate nick $alt_nick added to userid $uid \n";
         push @{$users{$uid}{alt_nicks}}, $alt_nick;
      } else {
         print " *** alternate nick $alt_nick for non-existent userid ($uid)\n";
         next;
      }
   }
}

sub load_networks {
   undef %networks;

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

      # Query if there are servers for this network and load them...
      load_servers($nid);
      # load channels if present
      load_channels($nid);
   }
}

sub load_servers {
   my ($nid) = @_;

   my $sth_servers = $dbh->prepare("SELECT * FROM servers WHERE nid = ?");
   $sth_servers->execute($nid);
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

      print " - added server $host:$port ($sid) to network $network ($nid) " . ($pass ? "*password*" : "") . "priority $priority " . ($disabled ? "*disabled*" : "") . "\n";

      $servers{$sid} = {
         nid         => $nid,
         host        => $host,
         port        => $port,
         pass        => $pass,
         priority    => $priority,
         tls         => $tls,
         blocked     => 0,		  # Is the server blocked out for failed connect?
         last_tried  => -1,               # last time the server was tried, in case blocked
         disabled    => $disabled
      };
      $servers_count++;
   }

   if (!$servers_count) {
      print "*** No servers configured for network $nid ($network) --- Add some using /server add [network] [host] [port] <tls> ***\n";
   }

   return $servers_count;
}

sub connect_all_networks {
   my %best_servers;

   # Find the highest priority server for each network that isn't disabled or blocked
   foreach my $sid (keys %servers) {
      my $server = $servers{$sid};
      my $nid = $server->{nid};
      my $blocked = $server->{blocked};
      my $last_tried = $server->{last_tried};
      my $disabled = $server->{disabled};
      my $network = get_network_name($nid);

      # Skip this server, if it's disabled
      if ($disabled) {
         print "* Skipping disabled server $sid on network $network ($nid)\n";
         next;
      }

      if (!exists $best_servers{$nid} || $best_servers{$nid}->{priority} < $server->{priority}) {
         $best_servers{$nid} = $sid;
      }
   }

   # Connect to the highest priority server for each network
   foreach my $nid (keys %best_servers) {
      if (!defined($best_servers{$nid})) {
         print "huh? connect_all_servers bug in connect loop! bs{$nid} doesnt exist\n";
         next;
      }

      my $sid = $best_servers{$nid};
      if (!exists $servers{$sid}) {
         print "* server $sid doesnt exist when trying to connect to $nid!\n";
         next;
      }

      my $host = $servers{$sid}->{host};
      my $port = $servers{$sid}->{port};
      my $nid  = $servers{$sid}->{nid};
      my $blocked = $servers{$sid}->{blocked};
      my $last_tried = $servers{$sid}->{last_tried};
      my $disabled = $servers{$sid}->{disabled};
      my $network = get_network_name($nid);
      print "network $network nid $nid sid $sid host $host port $port\n";

      if (!defined($sid) || !defined($host) || !defined($port) || !defined($network) || !defined($nid)) {
         print "invalid data!\n";
         die "x";
      }

      print "host: $host port: $port nid: $nid disabled: $disabled network: $network\n";

      if ($disabled) {
         print "- Skipping disabled server $host:port ($sid) on network $network ($nid)\n";
         next;
      } else {
         print "- Connecting to server $host:$port ($sid) for network $network ($nid)\n";
         $servers{$sid}->{last_tried} = time();
         my ($irc, $session) = create_irc_connection($sid);
      }
   }
}

sub reload_db {
   load_users();
   load_networks();
}

sub get_username {
   my ($uid) = @_;
   if (exists $users{$uid}) {
      return $users{$uid}->{user};
   } else {
      return "INVALIDUSER";
   }
}
   
sub get_uid {
   my ($username) = @_;

   for my $uid (keys %users) {
      if ($users{$uid}->{user} eq $username) {
         print "* mapped usernme $username to uid $uid" if ($debug >= 5);
         return $uid;
      }
   }

   return -1;
}

sub get_nid {
   my ($network) = @_;
   my ($package, $filename, $line) = caller;

   if (!defined($network) || $network eq '') {
      print "get_nid($network): Invalid network name in call from $package $filename:$line\n";
      return;
   }

   foreach my $nid (keys %networks) {
      my $net = $networks{$nid};
      my $net_name = $net->{network};
      my $disabled = $net->{disabled};

      if ($network eq $net_name) {
         print "get_nid($network) from $package / $filename:$line returning $nid\n" if ($debug >= 7);
         return $nid;
      }
   }

   print "get_nid($network): Invalid network name in call from $package $filename:$line!\n";
   return -2;
}

sub get_network_name {
   my ($nid) = @_;
   my ($package, $filename, $line) = caller;

   if (!defined($nid) || $nid < 0) {
      $nid = '-2' if (!defined($nid));
      print "get_network_name($nid): Invalid nid in call from $package $filename:$line\n";
      return;
   }

   if (!exists $networks{$nid}) {
      print "get_network_name($nid): Invalid network id in call from $package $filename:$line!\n";
      return 'Unknown Network';
   }

   my $network = $networks{$nid}->{network};
   print "get_network_name($nid) from $package / $filename:$line returning $network\n" if ($debug >= 10);
   return $network;
}

sub get_my_nick {
   my ($nid) = @_;
   my ($package, $filename, $line) = caller;

   if (!defined($nid) || $nid < 0) {
      print "get_my_nick: Invalid nid in call from $package $filename:$line\n";
      return;
   }

   if (exists $networks{$nid}) {
      my $nick = $networks{$nid}->{nick};
      return $nick;
   } else {
      print "get_my_nick: invalid nid: $nid\n";
   }
   return 'INVALIDNICK';
}

sub get_my_ident {
   my ($nid) = @_;

   if (exists $networks{$nid}) {
      my $nick = $networks{$nid}->{ident};
      return $nick;
   } else {
      print "get_my_ident: invalid nid: $nid\n";
   }
   return 'INVALIDIDENT';
}

sub get_my_realname {
   my ($nid) = @_;

   if (exists $networks{$nid}) {
      my $nick = $networks{$nid}->{realname};
      return $nick;
   } else {
      print "get_my_realname: invalid nid: $nid\n";
   }
   return '$botbrand';
}

sub get_my_irc {
   my ($nid) = @_;

   if (exists $networks{$nid}) {
      my $irc = $networks{$nid}->{irc};
      return $irc;
   } else {
      print "get_my_irc: invalid nid: $nid\n";
   }
   return;
}

sub do_login {
   my ($heap, $nick, $account,$nid, $password) = @_;
   my $network = get_network_name($nid);
   my $irc = $heap->{irc};
   my $uid = get_uid($account);
   my $user = get_username($uid);

   if ($uid == -1) {
      print "*** FAILED LOGIN *** for unknown $account by $nick on $network ($nid).\n";
      return 0;
   }

   if ($users{$uid}->{disbled}) {
      print "*** LOGIN ATTEMPT from DISABLED account $account by $nick on $network ($nid)\n";
      $irc->yield(notice => $nick => "Your account $account is disabled!");
      return 0;
   }

   if ($users{$uid}->{user} eq $account) {
      my $stored_passwd = $users{$uid}->{pass};
      my $hashed_passwd = sha256_hex($password);

      if ($hashed_passwd eq $stored_passwd) {
         $users{$uid}->{logged_in} = 1;
         $users{$uid}->{current_nick} = $nick;
         print "*** LOGIN *** for $account by $nick on $network ($nid)\n";
         $irc->yield(notice => $nick => "You are now logged in as \002$account\002!");
         return 1;
      } else {
         print "*** BAD PASS *** for $account by $nick on $network ($nid)\n";
         print "--- Attempt: $hashed_passwd - Actual: $stored_passwd\n" if ($debug >= 9);
      }
   }
   $irc->yield(notice => $nick => "Incorrect username/password.");
   # XXX: We should keep track of failed logins here and IGNORE the sender after some abuse...
   return 0;
}

sub is_logged_in {
    my ($nick, $network) = @_;
    my $uid = get_uid($nick);

    if (exists $users{$uid} && $users{$uid}->{logged_in}) {
        return 1;
    }
    return 0;
}

# User Access Check
sub check_auth {
    my ($nick, $nid, $level) = @_;
    return 0 unless $level;

    # XXX: this should use get_uid_by_altnick() or such...
    my $uid = get_uid($nick);
    my $network = get_network_name($nid);
    print "check_auth: $nick, $level\n";

    # First user (uid 0) is superuser, if this is enabled
    if ($allow_superuser && $uid == 0) {
       print "*superuser* login (DISABLE THIS BY DISABLING \$allow_superuser in bot.pl for improved security!)\n";
       return 1;
    }

    my $c = 0;
    foreach my $uid (keys %users) {
       $c++;
       my $user = $users{$uid};
       # Try the current nickname for the account, tho this allows only one login per account...
       # XXX: How to fix this without relying on nick registration?
       if ($user->{current_nick} eq $nick) {
          my $privileges = $user->{privileges};

          if ($privileges =~ /\b\Q$level\E\b/ || $privileges =~ /\*/) {
             print " ### $nick has privilege $level, granting access\n";
             return 1;
          } else {
             print " ### $nick does not have privilege $level, denying access\n";
             return 0;
          }
          last;
      }
   }
   print "c: $c\n";

   print " ### $nick does not exist denying access\n";
   return 0;
}

sub do_logout {
   my ($nick) = @_;
   return unless $nick;

   # Find account that is active for this nick
   # XXX: This should call get_uid_by_altnick or such so account doesn't have to match nick
   my $uid = get_uid($nick);
   my $user = get_username($uid);

   print "* Logging out $nick user ($uid)\n";
   # Clear it's logged_in and current_nick properties
   $users{$uid}->{logged_in} = 0;
   $users{$uid}->{current_nick} = '';
}


###############################################################################
# Sensors #
###############################################################################
sub get_sensor_msg {
   my @occupancy_types = ( 'bark', 'car', 'cat', 'dog', 'person', 'bicycle' );
   my $occupancy_valid = 0;
   my $occupancy_msg = "";
   my %aggregated_counts;

   # Load the sensor data
   my $sensor_file = $config->{cache}->{sensors}->{path};
   if (! -e $sensor_file) {
      print " Couldn't open sensor cache $sensor_file, it doesn't exist!\n";
      return " *Error opening sensor cache*";
   }

   open my $fh, '<', $sensor_file or warn "Can't open sensor file $sensor_file: $!\n";

   local $/; # Enable slurp mode
   my $json_text = <$fh>;
   close $fh;

   my $json = JSON->new;
   my $data;
   eval {
      $data = $json->decode($json_text);
   };

   if ($@) {
      print "JSON decode error: $@\n";
      return " *Error decoding sensor cache*";
   }

   # Extract the sensors array from the data
   my $sensors = $data->{sensors};

   # Process $sensors and aggregate counts
   foreach my $sensor (@$sensors) {
       my $entity_id = $sensor->{entity_id};
       
       # Match pattern sensor.*_$name_count
       if ($entity_id =~ /^sensor\..*_(\w+)_count$/) {
           my $name = $1;
           $aggregated_counts{"${name}_count"} += $sensor->{state};
           $occupancy_valid = 1;
           printf "* agg($name)=" . $aggregated_counts{"${name}_count"} . "\n" if ($debug >= 8);
       }
   }

   if ($occupancy_valid) {
      my $objdet_cars   = $aggregated_counts{'cars'} || 0;
      my $objdet_cats   = $aggregated_counts{'cats'} || 0;
      my $objdet_dogs   = $aggregated_counts{'dogs'} || 0;
      my $objdet_people = $aggregated_counts{'person'} || 0;
      my $objdet_bikes  = $aggregated_counts{'bicycle'} || 0;
      my $objdet_barks  = $aggregated_counts{'barks'} || 0;
      $occupancy_msg    = " There are ${objdet_cars} cars, ${objdet_cats} cats, ${objdet_dogs} dogs, and ${objdet_people} people with ${objdet_bikes} bikes in sight. I've heard ${objdet_barks} barks lately...🌮";
   } else {
      $occupancy_msg = " Sensor data expired.";
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

sub sanitize_channel_name {
    my ($input) = @_;

    # Allow only alphanumeric characters, underscores, hyphens, and hashes
    $input =~ s/[^a-zA-Z0-9_\-#]//g;
    return $input;
}

sub bot_start {
   my ($kernel, $heap) = @_[KERNEL, HEAP];
   my $irc = $heap->{irc};
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   my $nick = get_my_nick($nid);
   my $server = $heap->{server};
   $heap->{debug} = 1;
   print "Connecting as $nick on network: $network ($nid) via server: $server\n";
   $irc->yield(register => "all");
   $irc->yield(connect => { });
   return;
}

sub on_ctcp_action {
   my ($kernel, $who, $where, $msg, $heap) = @_[KERNEL, ARG0, ARG1, ARG2, HEAP];
   my $nick = (split /!/, $who)[0];
   my $channel = $where->[0];
   my $server = $heap->{server};
   my $sender = "$nick\@$server/$channel";
   my $irc = $heap->{irc};
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   print " * *$sender* $msg\n";
}

sub on_ctcp {
   my ($kernel, $what, $who, $where, $heap) = @_[KERNEL, ARG0, ARG1, ARG2, HEAP];
   my $nick = (split /!/, $who)[0];
   my $channel = $where->[0];
   my $server = $heap->{server};
   my $sender = "$nick\@$server/$channel";
   my $irc = $heap->{irc};
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);

   print " *CTCP/$what* from [$sender] on $network ($nid)\n";
}

sub on_ctcp_version {
   my ($kernel, $who, $where, $heap) = @_[KERNEL, ARG0, ARG1, HEAP];
   my $nick = (split /!/, $who)[0];
   my $target = $where->[0];
   my $irc = $heap->{irc};
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   my $sender = "$nick\@$network/$target";

   print "*VERSION* request from $who on $network ($nid) to $target, replying\n";
   $irc->yield(ctcpreply => $nick => 'VERSION $botbrand/$version');
}

sub on_public_message {
   my ($kernel, $who, $where, $msg, $heap) = @_[KERNEL, ARG0, ARG1, ARG2, HEAP];
   my $nick = (split /!/, $who)[0];
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   my $channel = $where->[0];
   my $server = $heap->{server};
   my $sender = "$nick\@$server/$channel";
   my $irc = $heap->{irc};

   print "[$sender] $msg\n";

   if ($msg =~ /^!adsb$/i) {
      send_adsb($channel, $heap);
   } elsif ($msg =~ /^!birds$/i) {
      send_birds($channel, $heap);
   } elsif ($msg =~ /^!dns/i) {
      send_dns_lookup($heap, $nid, $channel, $nick, $msg);
   } elsif ($msg =~ /^!help$/i) {
      send_help($nick, $heap);
   } elsif ($msg =~ /^!quit$/i) {
      if (check_auth($nick, $heap->{nid}, 'admin')) {
         print "* Got QUIT command from $nick in $channel on $network ($nid) - exiting!\n";
         $irc->yield(shutdown => "Bot is shutting down as requested by $nick on $network ($nid)");
      } else {
         print "* Got QUIT command from $nick in $channel on $network ($nid) - ignoring due to no privileges\n";
         $irc->yield(notice => $nick => "You do not have permission to shutdown the bot!");
      }
   } elsif ($msg =~ /^!restart$/i) {
      if (check_auth($nick, $heap->{nid}, 'admin')) {
         print "* Got RESTART command from $nick in $channel, exiting!\n";
         $irc->yield(shutdown => "Bot is restarting as requested by $nick on $network ($nid)");
      } else {
         print "* Got RESTART command from $nick in $channel on $network ($nid) - ignoring due to no privileges\n";
         $irc->yield(notice => $nick => "You do not have permission to restart the bot!");
      }
   } elsif ($msg =~ /^!sensors$/i) {
      send_sensors($channel, $heap);
   } elsif ($msg =~ /^!tacos$/i) {
      send_wx($channel, $heap);
   } elsif ($msg =~ /^!uptime$/i) {
      send_uptime($channel, $nick, $heap);
   }
}

sub on_private_message {
   my ($kernel, $who, $target, $msg, $heap) = @_[KERNEL, ARG0, ARG1, ARG2, HEAP];
   my $irc = $heap->{irc};
   my $nick = (split /!/, $who)[0];
   my $server = $heap->{server};
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);

   print "*$nick\@[$server]* $msg\n";

   if ($msg =~ /^!adsb$/i) {
      send_adsb($nick, $heap);
   } elsif ($msg =~ /^!birds$/i) {
      send_birds($nick, $heap);
   } elsif ($msg =~ /^!dns/i) {
      send_dns_lookup($heap, $nid, $nick, $nick, $msg);
   } elsif ($msg =~ /^!help$/i) {
      send_help($nick, $heap);
   } elsif ($msg =~ /^!join\s+(\S+)\s+(\S+)(?:\s+(\S+))?$/i) {
      my ($chan, $network, $key) = ($1, $2, $3);
      add_channel($nick, $heap, $chan, $network, $key);
   } elsif ($msg =~ /^!login\s+(\S+)\s+(\S+)$/i) {
      my ($username, $password) = ($1, $2);
      do_login($heap, $nick, $username, $nid, $password);
   } elsif ($msg =~ /^!login\s+(\S+)$/i) {		# short form, if nick == username
      my ($password) = ($1);
      do_login($heap, $nick, $nick, $nid, $password);
   } elsif ($msg =~ /^!logout$/i) {
      do_logout($nick);
   } elsif ($msg =~ /^!part\s+(\S+)\s+(\S+)$/i) {
      my ($chan, $network) = ($1, $2);
      remove_channel($nick, $heap, $chan, $network);
   } elsif ($msg =~ /^!quit$/i) {
      if (check_auth($nick, $nid, 'admin')) {
         print "* Got QUIT command from $nick on $network ($nid), exiting!\n";
         $irc->yield(shutdown => "Bot is shutting down as requested by $nick on $network ($nid)");
       } else {
         print "* Got QUIT command from $nick on $network ($nid) - ignoring due to no privileges\n";
         $irc->yield(notice => $nick => "You do not have permission to shutdown the bot!");
      }
   } elsif ($msg =~ /^!reload$/i) {
      if (check_auth($nick, $nid, 'admin')) {
         print "* Got RELOAD command from $nick on $network ($nid), reloading database!\n";
         $irc->yield(notice => $nick => "Reloading!");
         reload_db();
      } else {
         print "* Got RELOAD command from $nick on $network ($nid) - ignoring due to no privileges\n";
         $irc->yield(notice => $nick => "You do not have permission to reload the bot!");
      }
   } elsif ($msg =~ /^!restart$/i) {
      if (check_auth($nick, $nid, 'admin')) {
         print "* Got RESTART command from $nick on $network ($nid)- exiting!\n";
         $irc->yield(shutdown => "Bot is restarting as requested by $nick on $network ($nid)");
      } else {
         print "* Got RESTART command from $nick on $network ($nid) - ignoring due to no privileges\n";
         $irc->yield(notice => $nick => "You do not have permission to restart the bot!");
      }
   } elsif ($msg =~ /^!sensors$/i) {
      send_sensors($nick, $heap);
   } elsif ($msg =~ /^!tacos$/i) {
      send_wx($nick, $heap);
   } elsif ($msg =~ /^!uptime$/i) {
      send_uptime($nick, $nick, $heap);
   } elsif ($msg =~ /^!users$/i) {
      dump_users($nick, $heap);
   }
}

# Ping ourselves, but only if we haven't seen any traffic since the last ping. 
# This prevents us from pinging ourselves more than necessary (which tends to get noticed by server operators).
sub bot_do_autoping {
   my ($kernel, $heap) = @_[KERNEL, HEAP];

   $kernel->post(poco_irc => userhost => $heap->{nick})
      unless $heap->{seen_traffic};

   $heap->{seen_traffic} = 0;
   $kernel->delay(autoping => 300);
}

sub bot_reconnect {
   my $kernel = $_[KERNEL];

   # Throttle reconnecting
   $kernel->delay(autoping => undef);
   $kernel->delay(connect  => 60);
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
   # XXX: We need to start a timer here and clear it in on_bot_001, which times out if we do not connect
   # XXX: try the next server for the network, if available. If not, reconnect in soon
}

# Once connected, start a periodic timer to ping ourselves.  This
# ensures that the IRC connection is still alive.  Otherwise the TCP
# socket may stall, and you won't receive a disconnect notice for
# up to several hours.
sub on_bot_001 {
   my ($kernel, $sender, $heap) = @_[KERNEL, SENDER, HEAP];
   my $irc = $sender->get_heap();
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);

   # XXX: Clear the timer we set in on_registered 
   print "* Connected to network $network ($nid)\n";
   $heap->{seen_traffic} = 1;
   $kernel->delay(autoping => 300);
   join_channels($nid);
}

sub on_join {
   my ($kernel, $heap, $who, $where) = @_[KERNEL, HEAP, ARG0, ARG1];
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   my $nick = (split /!/, $who)[0];

   # XXX: Update %channels entry
   print " $where\@$network ($nid) JOIN $nick\n";
}

sub on_part {
   my ($kernel, $heap, $who, $where) = @_[KERNEL, HEAP, ARG0, ARG1];
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   my $nick = (split /!/, $who)[0];
   print " $where\@$network ($nid) PART $nick\n";
}

sub on_quit {
   my ($kernel, $heap, $who, $where) = @_[KERNEL, HEAP, ARG0, ARG1];
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   my $nick = (split /!/, $who)[0];

   print " $where\@$network ($nid) QUIT $nick\n";
   my $uid = get_uid($nick);

   if (exists $users{$uid}) {
      $users{uid}->current_nick = undef;
      $users{uid}->logged_in = 0;
   }
}

sub on_connected {
   my ($kernel, $heap, $server) = @_[KERNEL, HEAP, ARG0];
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   print "Connected to $network ($nid) via $server\n";
}

sub on_snotice {
   my ($kernel, $heap, $msg, $who) = @_[KERNEL, HEAP, ARG0, ARG1];
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);

   print "* $network ($nid): $who $msg\n"
}

sub on_ping {
   my ($kernel, $heap, $msg) = @_[KERNEL, HEAP, ARG0];
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   print "*PING* from $network, replying\n" if ($debug >= 9);
}

sub noop {
}

sub create_irc_connection {
   my ($sid) = @_;
   my $server = $servers{$sid} or die "Server ID $sid not found!";
   
   my $nid = $server->{nid};
   my $host = $server->{host};
   my $port = $server->{port};
   my $tls = $server->{tls};
   my $realname = get_my_realname($nid);
   my $ident = get_my_ident($nid);
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
       ircname  => $realname,
       Username => $ident,
       UseSSL   => $tls
   );
#   $irc->plugin_add( 'BotTraffic', POE::Component::IRC::Plugin::BotTraffic->new() );
   $irc->plugin_add( 'BotAddressed', POE::Component::IRC::Plugin::BotAddressed->new() );

   my $session = POE::Session->create(
       inline_states => {
           _start            => \&bot_start,
           autoping          => \&bot_do_autoping,
           dns_response      => \&dns_response,
           irc_001           => \&on_bot_001,
#           irc_bot_action    => \&irc_bot_action,
#           irc_bot_public    => \&irc_bot_public,
#           irc_bot_msg       => \&irc_bot_msg,
#           irc_bot_notice    => \&irc_bot_notice,
#           irc_bot_addressed => \&irc_bot_addressed,
#           irc_bot_mentioned => \&irc_bot_mentioned,
           irc_ctcp          => \&on_ctcp,
           irc_ctcp_action   => \&on_ctcp_action,
           irc_ctcp_version  => \&on_ctcp_version,
           irc_connected     => \&on_connected,
           irc_disconnected  => \&bot_reconnect,
           irc_error         => \&bot_reconnect,
           irc_join          => \&on_join,
           irc_part          => \&on_part,
           irc_quit          => \&on_quit,
           irc_socketerr     => \&bot_reconnect,
           irc_snotice       => \&on_snotice,
           irc_msg           => \&on_private_message,
           irc_notice        => \&on_private_message,
           irc_ping          => \&on_ping,
           irc_plugin_del    => \&noop,
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
   $networks{$nid}->{irc} = $irc;
   return { $irc, $session };
}

######################################################
# DNS Utilities #
# non-blocking dns lookup
sub send_dns_lookup {
   my ($heap, $nid, $where, $nick, $msg) = @_;
   my ($cmd, $type, $record) = split(' ', $msg, 3);
   my $network = get_network_name($nid);

   # Check user request first...
   if (!defined($type) || $type eq '' ||
       !defined($record) || $record eq '') {
      my $irc = $heap->{irc};
      $irc->yield(notice => $where => "Incorrect usage. Try !dns [type] [host], such as !dns a google.com");
      print "* Incorrect usage for !dns from $nick on $network ($nid)\n";
      return;
   }

   my $res = $dns->resolve(
      event => 'dns_response',
      host => $record,
      type => $type,
      context => {
          where => $where,
          nick  => $nick,
          nid   => $nid,
          query => "$type $record",
          heap  => $heap
      },
   );
   $poe_kernel->yield(dns_response => $res) if $res;
   return;
}

sub dns_response {
   my $res = $_[ARG0];
   my @answers = map { $_->rdatastr } $res->{response}->answer() if $res->{response};

   my $heap = $res->{context}->{heap};
   my $query = $res->{context}->{query};
   my $where = $res->{context}->{where};
   my $nick = $res->{context}->{nick};
   my $irc = $heap->{irc};

   if ($where ne $nick) {
      $irc->yield(privmsg => $where =>
         "$nick: DNS query: $query => " . (@answers ? "@answers" : 'no answers'));
   } else {
      $irc->yield(privmsg => $nick =>
         "DNS query: $query => " . (@answers ? "@answers" : 'no answers'));
   }
   return;
}

######################################################
# Channel Utilities #
######################################################
sub load_channels {
   my ($nid) = @_;
   my $network_name = get_network_name($nid);

   undef %channels;

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
          my $sender = $_[SENDER];
          my $heap = $_[HEAP];
          my $disabled = $channel_info->{disabled};

          if ($disabled) {
             print "* join_channels skipping $channel ($cid) because it is disabled!\n";
             next;
          }

          my $irc = $networks{$nid}{irc};
          $irc->yield(join => $channel, $key);
          print "Joining channel $channel with key $key...\n";
          $successes++;
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
   # XXX: We should cache this for a minute or two to reduce network and disk IO at the cost of less than a few kb of ram ;)
   my %wx_data;

   # Here we read it from the local file
   if ($config->{irc}->{wx}->{type} eq 'cache') {
      open(my $fh, '<', $wx_file) or warn "Unable to open $wx_file: $!";

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

sub get_wx_msg {
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
   my $wx_rain_month = $wx_data{'monthlyrainin'} . " in";
   my $wx_feels_like = feels_like($wx_data{'tempf'}, $wx_data{'humidity'}, $wx_data{'windspeedmph'}, $wx_data{'winddir'}) . "°F";
   my $wx_uv_index = $wx_data{'uv'};
   $wx_uv_index = 0 if ($wx_data{'uv'} eq 'Not provided');
   my $wx_solar_rad = $wx_data{'solarradiation'} . " W/m^2";

   my $message = "🌮 At ${wx_updated}, it is ${wx_temp} with ${wx_humid} humidity."
               . " The wind is ${wx_wind_word}, ${wx_wind_direction} ${wx_wind_cardinal} at ${wx_wind_mph} (${wx_wind_knots}) with"
               . " gusts to ${wx_wind_gust_mph} (${wx_wind_gust_daily_mph} / ${wx_wind_gust_daily_knots} max today)."
               . " There has been ${wx_rain_today} rain today, for a total of ${wx_rain_past_week} past week / ${wx_rain_month} past month."
               . " It feels like ${wx_feels_like} with a UV Index of ${wx_uv_index}."
               . " Solar radiation is ${wx_solar_rad}.";
   return $message;
}

sub send_wx {
   my ( $target, $heap ) = @_;
   my $message = get_wx_msg($heap);
   my $irc = $heap->{irc};

   $irc->yield(privmsg => $target => $message);
}

sub send_sensors {
   my ( $target, $heap ) = @_;
   my $message = get_sensor_msg();
   my $irc = $heap->{irc};

   $irc->yield(privmsg => $target => $message);
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
   $irc->yield(privmsg => $target => "*** HELP \$=admin, #=chan only, \@=privmsg only ***");
   $irc->yield(privmsg => $target => "!adsb       Spotted air traffic nearby");
   $irc->yield(privmsg => $target => "!birds      Get a summary of birds heard today by BirdNET");
   $irc->yield(privmsg => $target => "!dns        Perform a DNS query - arguments required: [type] [address]");
   $irc->yield(privmsg => $target => "!join       Add a channel to the bot and join it (\@\$)");
   $irc->yield(privmsg => $target => "!login      Login to the bot (\@)");
   $irc->yield(privmsg => $target => "!logout     Logout from the bot (\@)");
   $irc->yield(privmsg => $target => "!part       Remove a channel from the bot and part it (\@\$)");
   $irc->yield(privmsg => $target => "!quit       Terminate the bot (\$)");
   $irc->yield(privmsg => $target => "!reload     Reload the database (\@\$)");
   $irc->yield(privmsg => $target => "!restart    Restart the bot (\$)");
   $irc->yield(privmsg => $target => "!sensors    Get some sensor data from my QTH");
   $irc->yield(privmsg => $target => "!tacos      Get weather at my QTH");
   $irc->yield(privmsg => $target => "!uptime     Display bot uptime");
   $irc->yield(privmsg => $target => "!users      List user accounts (\@)");
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

sub dump_users {
   my ($nick, $heap) = @_;
   my $irc = $heap->{irc};
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);

   $irc->yield(notice => $nick => "* !users *");
   foreach my $uid (keys %users) {
      my $account = $users{$uid}->{user};
      my $ident = $users{$uid}->{ident};
      my $host = $users{$uid}->{host};
      my $privs = $users{$uid}->{privileges};
      my $disabled = "";
      $disabled = "*DISABLED*" if ($users{$uid}->{disabled});
      $irc->yield(notice => $nick => "* $account ($ident\@$host) - $privs $disabled");
   }
   $irc->yield(notice => $nick => "* End of !users *");
   return;
}

sub send_uptime {
   my ($target, $nick, $heap) = @_;
   my $irc = $heap->{irc};
   my $nid = $heap->{nid};
   my $network = get_network_name($nid);
   my $now = time;
   my $delta = $now - $started;
   my $seconds = $delta;

   my $days = int($seconds / ONE_DAY);
   $seconds %= ONE_DAY;
   my $hours = int($seconds / ONE_HOUR);
   $seconds %= ONE_HOUR;
   my $minutes = int($seconds / ONE_MINUTE);
   $seconds %= ONE_MINUTE;
   my $str = printf("%d days, %02d:%02d:%02d", $days, $hours, $minutes, $seconds);

   $irc->yield(privmsg => $target => "uptime: $str");
   return;
}

sub add_channel {
   my ($target, $heap, $channel, $network, $key) = @_;

   if (!defined($network) || !defined($channel) || $network eq '' || $channel eq '') {
      print " invalid data in add_channel\n";
      return;
   }

   my $nid = get_nid($network);
   my $irc = $heap->{irc};
   my $safe_chan = sanitize_channel_name($channel);

   # Add into the database
   my $query = "INSERT INTO channels (channel, nid, key) VALUES (?, ?, ?);";
   my $sth = $dbh->prepare($query);
   $sth->execute($safe_chan, $nid, $key);

   $irc->yield(notice => $target => "* Added bot to $channel on $network ($nid) as requested.");
   print "* User $target added channel $channel on $network ($nid)!\n";

   # join channel on the server
   $irc->yield(join => $channel, $key || '');

   # Update %channels
   load_channels($nid);

}

sub remove_channel {
   my ($target, $heap, $channel, $network) = @_;

   if (!defined($network) || !defined($channel) || $network eq '' || $channel eq '') {
      print " invalid data in add_channel\n";
      return;
   }

   my $irc = $heap->{irc};
   my $nid = get_nid($network);

   # Remove from the database
   my $query = "DELETE FROM channels WHERE channel = ? and nid = ?;";
   my $sth = $dbh->prepare($query);
   my $safe_chan = sanitize_channel_name($channel);
   $sth->execute($safe_chan, $nid);

   $irc->yield(notice => $target => "* Leaving $channel on $network ($nid) as requested.");
   $irc->yield(part => $channel => "Leaving as requested by $target on $network ($nid)");

   # Update %channels
   load_channels($nid);
}

sub restart {
   my ($heap) = @_;
   print "Restarting the bot...\n";
   exec($^X, $0, @ARGV) or die "Couldn't exec: $!";
}

###############################################################################
# Start up #
###############################################################################
reload_db();
connect_all_networks();
$poe_kernel->run();
