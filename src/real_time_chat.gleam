//// A simple example of using Server-Sent Events (SSE) in Gleam.

import gleam/bit_array
import gleam/bytes_builder
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/http
import gleam/http/response
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string_builder
import mist
import simplifile

/// Message types for the pubsub actor.
///
/// The pubsub actor manages the clients listening for messages and
/// forwards messages to all connected clients.
type PubSubMessage {
  /// A new client has connected and wants to receive messages.
  Subscribe(client: Subject(String))
  /// A client has disconnected and should no longer receive messages.
  Unsubscribe(client: Subject(String))
  /// A message to forward to all connected clients.
  Publish(String)
}

/// This is the pubsub loop function, which receives messages and produces
/// a new state. The pubsub runs in a separate process.
///
/// In Gleam, variables are immutable, so we rely on the Actor model to manage
/// state. In this case, the state is a list of connected clients.
fn pubsub_loop(message: PubSubMessage, clients: List(Subject(String))) {
  case message {
    // When the pubsub receives a Subscribe message with a client in it,
    // continue running the actor loop with the client added to the state
    Subscribe(client) -> {
      io.println("➕ Client connected")
      [client, ..clients] |> actor.continue
    }
    // When the pubsub receives a Unsubscribe message with a client in it,
    // produce a new state with the client removed and continue running
    Unsubscribe(client) -> {
      io.println("➖ Client disconnected")
      clients
      |> list.filter(fn(c) { c != client })
      |> actor.continue
    }
    // Finally, when the pubsub receives a message, forward it to clients
    Publish(message) -> {
      io.println("💬 " <> message)
      clients |> list.each(process.send(_, message))
      clients |> actor.continue
    }
  }
}

/// Create a new HTTP response with the given status code and body.
fn new_response(status: Int, body: String) {
  response.new(status)
  |> response.set_body(body |> bytes_builder.from_string |> mist.Bytes)
}

pub fn main() {
  // Start the pubsub with an empty list of clients in its own process
  let assert Ok(pubsub) = actor.start([], pubsub_loop)

  let assert Ok(_) =
    mist.new(
      // HTTP server handler: it takes a request and returns a response
      fn(request) {
        // Basic router matching the request method and path of the request
        let response = case request.method, request.path {
          // On 'GET /', read the index.html file and return it
          http.Get, "/" -> {
            use index <- result.try(
              simplifile.read("src/index.html")
              |> result.replace_error("Could not read index.html."),
            )
            new_response(200, index) |> Ok
          }

          // On 'POST /post', read the body and send it to the pubsub
          http.Post, "/post" -> {
            // Read the first 128 bytes of the request, as it's the limit set
            // in the frontend (<input maxlength="128">)
            use request <- result.try(
              request
              |> mist.read_body(128)
              |> result.replace_error("Could not read request body."),
            )
            // Transform the bytes into a string
            use message <- result.try(
              request.body
              |> bit_array.to_string
              |> result.replace_error(
                "Could not convert request body to string.",
              ),
            )

            // Send the message to the pubsub
            process.send(pubsub, Publish(message))

            // Respond with a success message
            new_response(200, "Submitted: " <> message) |> Ok
          }

          // On 'GET /sse', start a Server-Sent Events (SSE) connection.
          // The SSE loop runs in a separate process, we will use the pubsub
          // to send and receive messages.
          http.Get, "/sse" ->
            mist.server_sent_events(
              request,
              response.new(200),
              // Initialization function of the SSE loop
              init: fn() {
                // Create a new subject for the client to receive messages
                let client = process.new_subject()

                // Send this new client to the pubsub
                process.send(pubsub, Subscribe(client))

                // Define on what messages the SSE loop function should run:
                // on every message send to the `client` subject
                let selector =
                  process.new_selector()
                  |> process.selecting(client, function.identity)

                // Start the loop with the client as state and a selector
                // pointing to the client subject
                actor.Ready(client, selector)
              },
              // This loop function is called every time the `client` subject
              // defined above receives a message.
              // The first parameter is the incoming message, the second is the
              // SSE connection, and the third is the loop state, which, in this
              // case is always the client subject.
              loop: fn(message, connection, client) {
                // Forward the message to the web client
                case
                  mist.send_event(
                    connection,
                    message |> string_builder.from_string |> mist.event,
                  )
                {
                  // If it succeeds, continue the process
                  Ok(_) -> actor.continue(client)
                  // If it fails, disconnect the client and stop the process
                  Error(_) -> {
                    process.send(pubsub, Unsubscribe(client))
                    actor.Stop(process.Normal)
                  }
                }
              },
            )
            |> Ok

          // In case of any other request, return a 404
          _, _ -> new_response(404, "Not found") |> Ok
        }

        // Simple error-handling mechanism
        case response {
          Ok(response) -> response
          Error(error) -> {
            io.print_error(error)
            new_response(500, "Internal Server Error")
          }
        }
      },
    )
    // Create and start an HTTP server using this handler
    |> mist.port(3000)
    |> mist.start_http

  // Everything runs in separate processes, keep the main process alive
  process.sleep_forever()
}
