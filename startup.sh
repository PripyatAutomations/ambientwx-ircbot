#!/bin/sh
[ ! -f turdbot.db ] && sqlite3 turdbot.db < example.irc.sql
[ ! -f sensors.db ] && sqlite3 sensors.db < example.sensors.sql

./httpd.pl &
./sensors.pl &
./bot.pl
