//// A simple example of using Server-Sent Events (SSE) with Gleam

import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process
import gleam/function
import gleam/io
import gleam/otp/actor
import gleam/result
import handler
import mist
import pubsub
import updater

@external(erlang, "code", "soft_purge")
fn soft_purge(module: atom.Atom) -> Bool

@external(erlang, "code", "load_file")
fn load_file(module: atom.Atom) -> dynamic.Dynamic

fn await_message() {
  let message =
    process.new_selector()
    |> process.selecting_anything(function.identity)
    |> process.select_forever()

  let _ = case message == updater.Update |> dynamic.from {
    True -> {
      io.println("Received an update message")
      use module <- result.try("handler" |> atom.from_string)
      case soft_purge(module) {
        True -> {
          io.println("Module purged, hot swapping")
          load_file(module)
          Nil
        }
        False ->
          io.println(
            "Module not purged, some client still connected to old code",
          )
      }
      Ok(Nil)
    }
    False -> {
      io.println("Received a different message")
      Ok(Nil)
    }
  }

  await_message()
}

fn node_receiver() {
  let pid = process.self()
  let atom = "update_receiver" |> atom.create_from_string

  use Nil <- result.try(
    process.register(pid, atom)
    |> result.replace_error("Could not register process"),
  )

  await_message()
}

pub fn main() {
  // Start the pubsub with an empty list of clients in its own process.
  let assert Ok(pubsub) = actor.start([], pubsub.pubsub_loop)

  let assert Ok(_) =
    // HTTP server handler: it takes a request and returns a response.
    handler.handle(pubsub, _)
    // Create and start an HTTP server using this handler.
    |> mist.new
    |> mist.port(3000)
    |> mist.start_http

  process.start(node_receiver, linked: True)

  // Everything runs in separate processes, keep the main process alive.
  process.sleep_forever()
}
