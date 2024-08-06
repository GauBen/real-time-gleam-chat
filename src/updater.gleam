import gleam/erlang/atom.{type Atom}
import gleam/erlang/node
import gleam/result

pub type UpdaterMessage {
  Update
}

pub fn trigger_update(node_name: Atom) {
  use pod <- result.try(
    node.connect(node_name)
    |> result.replace_error("Could not connect to node"),
  )
  let atom = "update_receiver" |> atom.create_from_string

  node.send(pod, atom, Update)
  |> Ok
}
