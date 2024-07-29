#!/bin/sh
[ ! -f turdbot.db ] && sqlite3 turdbot.db < ircbot.sql
./httpd.pl &
./bot.pl
