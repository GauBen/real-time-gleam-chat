import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/io
import gleam/list
import gleam/otp/actor

type ControllerMessage(a) {
  ClientConnect(client: Subject(a))
  ClientDisconect(client: Subject(a))
  Message(message: a)
}

pub fn main() {
  let assert Ok(controller) =
    actor.start([], fn(msg, clients) {
      case msg {
        ClientConnect(client) -> [client, ..clients] |> actor.continue
        ClientDisconect(client) ->
          clients
          |> list.filter(fn(c) { c != client })
          |> actor.continue
        Message(message) -> {
          clients |> list.each(fn(client) { client |> process.send(message) })
          clients |> actor.continue
        }
      }
    })

  let monitor =
    process.start(
      fn() {
        let client1 = process.new_subject()
        process.send(controller, ClientConnect(client1))
        process.send(controller, Message("From child process"))

        let assert Ok(msg) = process.receive(client1, 100)
        io.println("Client1: " <> msg)

        let assert Ok(msg) = process.receive(client1, 100)
        io.println("Client1: " <> msg)
      },
      False,
    )
    |> process.monitor_process

  let client2 = process.new_subject()
  process.send(controller, ClientConnect(client2))

  let assert Ok(msg) = process.receive(client2, 100)
  io.println("Client2: " <> msg)

  process.send(controller, Message("From main process"))

  let assert Ok(msg) = process.receive(client2, 100)
  io.println("Client2: " <> msg)

  process.new_selector()
  |> process.selecting_process_down(monitor, function.identity)
  |> process.select_forever
}
