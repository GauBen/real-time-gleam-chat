import gleam/bit_array
import gleam/bytes_builder
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/io
import gleam/iterator
import gleam/otp/actor
import gleam/result
import mist.{type Connection, type ResponseData}

pub type Message(element) {
  Shutdown
  Submit(element)
  Read(Subject(List(element)))
}

fn handle_message(
  message: Message(e),
  stack: List(e),
) -> actor.Next(Message(e), List(e)) {
  case message {
    Shutdown -> actor.Stop(process.Normal)
    Submit(value) -> actor.continue([value, ..stack])
    Read(client) -> {
      process.send(client, stack)
      actor.continue(stack)
    }
  }
}

pub fn main() {
  let assert Ok(messages) = actor.start([], handle_message)

  let bad_request =
    response.set_body(
      response.new(400),
      mist.Bytes(bytes_builder.from_string("Bad request")),
    )
  let server_error =
    response.set_body(
      response.new(500),
      mist.Bytes(bytes_builder.from_string("Internal server error")),
    )

  let assert Ok(_) =
    fn(req: Request(Connection)) -> Response(ResponseData) {
      case req.method {
        http.Post -> {
          result.unwrap(
            {
              use req <- result.try(
                mist.read_body(req, 1024)
                |> result.replace_error(Nil),
              )
              use message <- result.try(req.body |> bit_array.to_string)

              io.println("Received: " <> message)
              process.send(messages, Submit(message))

              response.new(200)
              |> response.set_body(
                mist.Bytes(bytes_builder.from_string("Subitted: " <> message)),
              )
              |> Ok
            },
            bad_request,
          )
        }
        _ ->
          result.unwrap(
            {
              use lst <- result.try(process.try_call(messages, Read, 10))

              let body =
                iterator.fold(
                  iterator.from_list(lst),
                  bytes_builder.new(),
                  fn(builder, message) {
                    bytes_builder.append_string(builder, message <> "\n")
                  },
                )

              response.new(200)
              |> response.set_body(mist.Bytes(body))
              |> Ok
            },
            server_error,
          )
      }
    }
    |> mist.new
    |> mist.port(3000)
    |> mist.start_http

  process.sleep_forever()
}
