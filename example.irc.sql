--- sqlite3 turdbot.db < ircbot.sql
--- use sha256 passwords
drop table if exists networks;
drop table if exists servers;
drop table if exists users;
drop table if exists channels;
drop table if exists alerts;

begin;
create table networks (
   nid INTEGER PRIMARY KEY AUTOINCREMENT,
   network TEXT NOT NULL,
   nick TEXT NOT NULL,
   realname TEXT NOT NULL,
   ident TEXT NOT NULL DEFAULT 'tacobot',
   priority INTEGER DEFAULT 0,
   disabled INTEGER DEFAULT 0
);

create table servers (
   sid INTEGER PRIMARY KEY AUTOINCREMENT,
   nid INTEGER NOT NULL,
   host TEXT NOT NULL,
   port INTEGER DEFAULT 6667,
   pass TEXT DEFAULT NULL,
   tls INTEGER DEFAULT 0,
   disabled INTEGER DEFAULT 0
);

create table users (
   uid INTEGER PRIMARY KEY AUTOINCREMENT,
   user TEXT NOT NULL,
   nick TEXT DEFAULT '*',
   ident TEXT DEFAULT '*',
   host TEXT DEFAULT '*',
   pass TEXT NOT NULL,
   privileges TEXT,
   disabled INTEGER DEFAULT 0
);

create table channels (
   cid INTEGER PRIMARY KEY AUTOINCREMENT,
   channel TEXT NOT NULL,
   key TEXT DEFAULT NULL,
   nid INTEGER NOT NULL,
   disabled INTEGER DEFAULT 0
);

create table alerts (
   aid INTEGER PRIMARY KEY AUTOINCREMENT,
   --- A channel to post the events to
   cid INTEGER DEFAULT NULL,
   --- A user account to privmsg events to, if logged in
   uid INTEGER DEFAULT NULL,

   --- Conditions

   --- Action: MSG, ME, NOTICE (XXX: Add CTCP)
   action TEXT NOT NULL,
   disabled INTEGER NOT NULL DEFAULT 0
);
commit;

begin;
insert into networks (nid, network, nick, ident, realname) values (0, 'EFnet', 'rustyclam', 'tacobot', 'Taco Bot');
insert into networks (nid, network, nick, ident, realname) values (1, 'Libera', 'rustyclam', 'tacobot', 'Taco Bot');

insert into servers (nid, host, port) values (0, 'irc.efnet.org', 6667);
#insert into servers (nid, host, port) values (0, '127.0.0.1', 6667);
insert into servers (nid, host, port, disabled) values (0, 'irc.choopa.net', 6667, 1);
insert into servers (nid, host, port) values (1, 'irc.libera.chat', 6667);
insert into channels (channel, nid) values ('#hamradio', 0);
#insert into channels (channel, nid) values ('#istabpeople', 0);
insert into channels (channel, nid) values ('#tk-test', 1);
commit;
