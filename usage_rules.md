# Usage Rules

Ground rules for using and contributing to `maelstrom_nexus`.

## What this library is

MaelstromNexus is a **protocol transport layer** for Maelstrom. It handles:

- JSON stdin/stdout I/O
- The Maelstrom init handshake
- Message ID sequencing and `in_reply_to` tracking
- Routing incoming messages to handler callbacks
- Serializing outbound messages from multiple BEAM processes

It does **not** handle:

- Consensus protocols (Raft, Paxos, VSR, etc.)
- State machine replication
- Persistence or durability
- Cluster membership changes
- Workload-specific logic (lin-kv, broadcast, etc.)

Those belong in your application code, inside the handler callbacks.

## Handler design rules

### Keep handlers pure where possible

`handle_message/4` receives the full message context and returns a result tuple.
Prefer computing the reply body and new state without side effects:

```elixir
# Good: pure computation
def handle_message("read", body, _msg, state) do
  {:reply, %{"type" => "read_ok", "value" => Map.get(state, body["key"])}, state}
end

# Avoid: side effects inside handle_message for simple cases
def handle_message("read", body, _msg, state) do
  MaelstromNexus.log("reading key #{body["key"]}")  # unnecessary noise
  {:reply, %{"type" => "read_ok", "value" => Map.get(state, body["key"])}, state}
end
```

### Use the multi-process API for cross-process coordination

When other processes (Bridge, Transport, async tasks) need to send Maelstrom
messages, they should call the API functions directly:

```elixir
# From a transport process:
MaelstromNexus.send_msg(MyNode, target_node, %{
  "type" => "replicate",
  "payload" => Base.encode64(envelope_bytes)
})

# From an async task completing:
MaelstromNexus.reply(MyNode, original_msg, %{"type" => "write_ok"})
```

Do **not** try to funnel everything through `handle_message`. That defeats the
purpose of the multi-process architecture.

### Use `handle_info/2` for async results

When you spawn tasks or receive messages from other BEAM processes, handle them
in `handle_info/2`. Store any context needed for the reply (like the original
Maelstrom message) in your handler state:

```elixir
def handle_message("write", body, msg, state) do
  ref = make_ref()
  Task.start(fn ->
    result = expensive_consensus_operation(body)
    send(MyNode, {:write_result, ref, result})
  end)
  # Store the original message so we can reply later
  pending = Map.put(state.pending, ref, msg)
  {:noreply, %{state | pending: pending}}
end

def handle_info({:write_result, ref, result}, state) do
  {original_msg, pending} = Map.pop(state.pending, ref)
  MaelstromNexus.reply(MyNode, original_msg, %{"type" => "write_ok"})
  {:noreply, %{state | pending: pending}}
end
```

### Transient vs definite errors

This distinction matters for Maelstrom's correctness checker (Knossos/Elle):

- **Definite errors**: The operation definitely did not happen. Safe to return
  `{:error, code, text, state}`.
  Examples: key not found, precondition failed, malformed request.

- **Transient errors**: The operation may or may not have committed. Return
  `{:noreply, state}` so Maelstrom records it as indeterminate.
  Examples: leader election in progress, lease expired, timeout.

```elixir
# Definite: safe to error
{:error, 20, "key does not exist", state}

# Transient: don't reply
{:noreply, state}
```

Getting this wrong causes false positives or false negatives in linearizability
checking.

## Naming conventions

- Register the node GenServer under the handler module name (the default).
  This makes API calls read naturally: `MaelstromNexus.node_id(MyWorkload)`.
- If running multiple nodes in tests, use unique names:
  `MaelstromNexus.run(MyWorkload, name: :"node_#{i}")`.

## Testing your handler

Test handlers by feeding message lists through `MaelstromNexus.run/2` with
a custom input stream and a `StringIO` output device:

```elixir
messages = [
  %{"src" => "c0", "dest" => "n0", "body" => %{"type" => "init", ...}},
  %{"src" => "c1", "dest" => "n0", "body" => %{"type" => "echo", ...}}
]

json_lines = Enum.map(messages, &(Jason.encode!(&1) <> "\n"))
output = StringIO.open("") |> elem(1)

MaelstromNexus.run(MyWorkload,
  input: json_lines,
  output: output,
  name: :"test_#{System.unique_integer([:positive])}"
)

{_in, content} = StringIO.contents(output)
replies = content |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
```

## Maelstrom runner script

Maelstrom expects a single executable. Create a shell wrapper:

```bash
#!/bin/sh
# bin/my_node
cd "$(dirname "$0")/.."
elixir --no-halt -S mix run scripts/my_node.exs
```

And the script:

```elixir
# scripts/my_node.exs
MyWorkload.run()
```

Make the wrapper executable: `chmod +x bin/my_node`.

Then run: `./maelstrom test -w lin-kv --bin bin/my_node --node-count 3 --time-limit 30`
