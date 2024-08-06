import gleam/bit_array
import gleam/bytes_builder
import gleam/erlang/process
import gleam/function
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response
import gleam/io
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_builder
import mist.{type Connection}
import pubsub.{Message, Subscribe, Unsubscribe}
import simplifile

/// Create a new HTTP response with the given status code and body.
fn new_response(status: Int, body: String) {
  response.new(status)
  |> response.set_body(body |> bytes_builder.from_string |> mist.Bytes)
}

// Define some common responses.
fn bad_request(error: String) {
  new_response(400, "Bad request: " <> error)
}

fn not_found() {
  new_response(404, "Not found")
}

fn internal_error() {
  new_response(500, "Internal server error")
}

pub fn handle(pubsub, request: Request(Connection)) {
  // Basic router matching the request method and path of the request.
  let result = case request.method, request.path {
    // On 'GET /', read the index.html file and return it.
    http.Get, "/" -> {
      use index <- result.try(
        simplifile.read("src/index.html")
        |> result.replace_error("Could not read index.html"),
      )
      new_response(200, index) |> Ok
    }

    // On 'POST /post', read the body and send it to the pubsub.
    http.Post, "/post" -> {
      let result = {
        // Read the first 128 bytes of the request.
        use request <- result.try(
          request
          |> mist.read_body(128)
          // Ignore potential `ReadError` and replace it with `Nil`, so
          // that the `Result` type does not clash with the one from
          // `bit_array.to_string`.
          |> result.replace_error("Could not read request body"),
        )
        // Transform the bytes into a string.
        use message <- result.try(
          request.body
          |> bit_array.to_string
          |> result.replace_error("Could not convert request body to string"),
        )

        // Send the message to the pubsub.
        process.send(pubsub, Message(message |> string.reverse))

        // Respond with a success message.
        new_response(200, "Submitted: " <> message) |> Ok
      }

      case result {
        Ok(response) -> response |> Ok
        Error(error) -> error |> bad_request |> Ok
      }
    }

    // On 'GET /sse', start a Server-Sent Events (SSE) connection.
    // The SSE loop runs in a separate process, we will use the pubsub
    // to send and receive messages.
    http.Get, "/sse" ->
      mist.server_sent_events(
        request,
        response.new(200),
        // Initialization function of the SSE loop.
        init: fn() {
          // Create a new subject for the client to receive messages.
          let client = process.new_subject()

          // Send this new client to the pubsub.
          process.send(pubsub, Subscribe(client))

          // Define on what messages the SSE loop function should run:
          // on every message send to the `client` subject.
          let selector =
            process.new_selector()
            |> process.selecting(client, function.identity)

          // Start the loop with the client as state and a selector
          // pointing to the client subject.
          actor.Ready(client, selector)
        },
        // This loop function is called every time the `client` subject
        // defined above receives a message.
        // The first parameter is the incoming message, the second is the
        // SSE connection, and the third is the loop state, which, in this
        // case is always the client subject.
        loop: fn(message, connection, client) {
          // Forward the message to the web client.
          case
            mist.send_event(
              connection,
              message |> string_builder.from_string |> mist.event,
            )
          {
            // If it succeeds, continue the process.
            Ok(_) -> actor.continue(client)
            // If it fails, disconnect the client and stop the process.
            Error(_) -> {
              process.send(pubsub, Unsubscribe(client))
              actor.Stop(process.Normal)
            }
          }
        },
      )
      |> Ok

    // In case of any other request, return a 404.
    _, _ -> not_found() |> Ok
  }

  case result {
    Ok(response) -> response
    Error(error) -> {
      io.println_error(error)
      internal_error()
    }
  }
}
