PACKAGE:="realtime_chat"
BASE:="build/erlang-shipment"

build:
  gleam export erlang-shipment

start:
  erl \
    -sname worker \
    -pa {{BASE}}/*/ebin \
    -eval "{{PACKAGE}}@@main:run({{PACKAGE}})" \
    -noshell

update: build
  erl \
    -sname shell \
    -pa {{BASE}}/*/ebin \
    -eval "gleam@io:debug(updater:trigger_update(worker@{{`hostname`}})), halt()" \
    -noshell
