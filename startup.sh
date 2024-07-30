#!/bin/sh
[ ! -f turdbot.db ] && sqlite3 turdbot.db < ircbot.sql
[ ! -f sensors.db ] && sqlite3 sensors.db < sensors.sql

./httpd.pl &
./sensors.pl &
./bot.pl
