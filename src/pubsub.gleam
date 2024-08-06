import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/list
import gleam/otp/actor

/// Message types for the pubsub actor.
///
/// The pubsub actor manages the clients listening for messages and
/// forwards messages to all connected clients.
pub type PubSubMessage {
  /// A new client has connected and wants to receive messages.
  Subscribe(Subject(String))
  /// A client has disconnected and should no longer receive messages.
  Unsubscribe(Subject(String))
  /// A message to forward to all connected clients.
  Message(String)
}

/// This is the pubsub loop function, which receives messages and produces
/// a new state. The pubsub runs in a separate process.
///
/// In Gleam, variables are immutable, so we rely on the Actor model to manage
/// state. In this case, the state is a list of connected clients.
pub fn pubsub_loop(message: PubSubMessage, clients: List(Subject(String))) {
  case message {
    // When the pubsub receives a Subscribe message with a client in it,
    // continue running the actor loop with the client added to the state.
    Subscribe(client) -> {
      io.println("+ New client connected")
      [client, ..clients] |> actor.continue
    }
    // When the pubsub receives a Unsubscribe message with a client in it,
    // produce a new state with the client removed and continue running.
    Unsubscribe(client) -> {
      io.println("- A client disconnected")
      clients
      |> list.filter(fn(c) { c != client })
      |> actor.continue
    }
    // Finally, when the pubsub receives a Message, forward it to clients.
    Message(message) -> {
      io.println("> Forwarding message to clients: " <> message)
      clients |> list.each(process.send(_, message))
      clients |> actor.continue
    }
  }
}
