# MaelstromNexus

A multi-process [Maelstrom](https://github.com/jepsen-io/maelstrom) protocol library for Elixir.

MaelstromNexus lets you test complex distributed systems — consensus engines,
replicated state machines, custom transport layers — under
[Jepsen](https://jepsen.io/)'s Maelstrom fault-injection framework.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:maelstrom_nexus, "~> 0.1.0"}
  ]
end
```

Then fetch the Maelstrom test framework itself:

```bash
mix deps.get
mix maelstrom_nexus.setup
```

This downloads the Maelstrom binary and jar into `.maelstrom/` (automatically
gitignored). You can specify a version:

```bash
mix maelstrom_nexus.setup --version v0.2.4
```

Check installation status programmatically:

```elixir
MaelstromNexus.Setup.installed?()        # => true
MaelstromNexus.Setup.bin_path()          # => ".maelstrom/maelstrom/maelstrom"
```

## Quick start

### 1. Define a handler

```elixir
defmodule EchoWorkload do
  use MaelstromNexus

  @impl true
  def handle_message("echo", body, _msg, state) do
    {:reply, %{"type" => "echo_ok", "echo" => body["echo"]}, state}
  end
end
```

### 2. Create a runner script

```elixir
# echo.exs
EchoWorkload.run()
```

### 3. Create a shell wrapper for Maelstrom

```bash
#!/bin/sh
cd "$(dirname "$0")/.."
mix run echo.exs
```

### 4. Run under Maelstrom

```bash
./maelstrom test -w echo \
  --bin echo \
  --node-count 1 \
  --time-limit 10
```

## Handler callbacks

```elixir
defmodule MyWorkload do
  use MaelstromNexus

  # Called once when the node starts
  @impl true
  def init(_args), do: {:ok, %{store: %{}}}

  # Called after Maelstrom assigns node_id and cluster membership
  @impl true
  def handle_init(node_id, node_ids, state) do
    {:ok, %{state | membership: node_ids, self: node_id}}
  end

  # Called for each incoming Maelstrom message (except init)
  @impl true
  def handle_message("read", body, _msg, state) do
    case Map.fetch(state.store, body["key"]) do
      {:ok, value} ->
        {:reply, %{"type" => "read_ok", "value" => value}, state}

      :error ->
        code = MaelstromNexus.Message.error_code(:key_does_not_exist)
        {:error, code, "key does not exist", state}
    end
  end

  def handle_message("write", body, _msg, state) do
    store = Map.put(state.store, body["key"], body["value"])
    {:reply, %{"type" => "write_ok"}, %{state | store: store}}
  end

  # Called for BEAM messages from other processes
  @impl true
  def handle_info({:async_result, ref, result}, state) do
    # Reply to the original client using the stored message
    {original_msg, pending} = Map.pop(state.pending, ref)
    MaelstromNexus.reply(MyWorkload, original_msg, %{"type" => "write_ok"})
    {:noreply, %{state | pending: pending}}
  end
end
```

## Return values

From `handle_message/4`:

| Return | Effect |
|---|---|
| `{:reply, body, state}` | Send reply to sender with automatic `in_reply_to` |
| `{:noreply, state}` | Absorb silently (use for transient errors) |
| `{:error, code, text, state}` | Send Maelstrom error reply |

From `handle_info/2`:

| Return | Effect |
|---|---|
| `{:noreply, state}` | Update state; use API functions for side effects |

## Multi-process API

The key differentiator. Any BEAM process can send messages through the nexus:

```elixir
# Send an arbitrary message to another node
MaelstromNexus.send_msg(MyWorkload, "n1", %{"type" => "replicate", "data" => payload})

# Reply to a previously received message (stored in handler state)
MaelstromNexus.reply(MyWorkload, stored_msg, %{"type" => "write_ok"})

# Send an error reply
MaelstromNexus.error_reply(MyWorkload, stored_msg, 11, "temporarily unavailable")

# Query cluster state
MaelstromNexus.node_id(MyWorkload)   # => "n0"
MaelstromNexus.node_ids(MyWorkload)  # => ["n0", "n1", "n2"]

# Log to stderr (visible in Maelstrom logs, not protocol output)
MaelstromNexus.log("processing request #{inspect(msg)}")
```

## Transient error pattern

For consensus engines, some errors are transient — the operation may or may not
have committed. Replying with an error would tell Maelstrom the operation
definitely failed, which is incorrect. Instead, return `{:noreply, state}` so
Maelstrom's Knossos checker records the operation as indeterminate (`:info`):

```elixir
def handle_message("write", body, msg, state) do
  case MyConsensus.propose(body) do
    {:ok, result} ->
      {:reply, %{"type" => "write_ok"}, state}

    {:error, :view_change_in_progress} ->
      # Don't reply — operation might have committed
      {:noreply, state}

    {:error, :key_does_not_exist} ->
      # Definite failure — safe to report
      {:error, 20, "key does not exist", state}
  end
end
```

## Supervision tree integration

For embedding in a host application's supervision tree:

```elixir
children = [
  {MaelstromNexus, {MyWorkload, name: MyWorkload, input: IO.stream(:line)}}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

## Error codes

```elixir
MaelstromNexus.Message.error_code(:timeout)                 # => 0
MaelstromNexus.Message.error_code(:not_supported)            # => 10
MaelstromNexus.Message.error_code(:temporarily_unavailable)  # => 11
MaelstromNexus.Message.error_code(:malformed_request)        # => 12
MaelstromNexus.Message.error_code(:crash)                    # => 13
MaelstromNexus.Message.error_code(:abort)                    # => 14
MaelstromNexus.Message.error_code(:key_does_not_exist)       # => 20
MaelstromNexus.Message.error_code(:key_already_exists)       # => 21
MaelstromNexus.Message.error_code(:precondition_failed)      # => 22
MaelstromNexus.Message.error_code(:txn_conflict)             # => 30
```

## Existing work: Why didn't we re-use `maelstrom` (hex)?

The existing [`maelstrom`](https://hex.pm/packages/maelstrom) package ([source](https://github.com/prehnRA/maelstrom_ex)) is a clean, minimal implementation of the Maelstrom protocol. It works well for the [Fly.io distributed systems challenges](https://fly.io/dist-sys/) and educational exercises where all logic lives inside a single `handle_message` callback.

However, it was not designed for the needs of production-grade distributed systems libraries:

| Concern | `maelstrom` (hex) | `maelstrom_nexus` |
|---|---|---|
| **Process model** | Single GenServer; all logic must live in `handle_message` | GenServer with `handle_info` — other BEAM processes can deliver results |
| **Sending from other processes** | Not supported; output only happens inside `handle_cast` | Any process can call `send_msg/3`, `reply/3`, `error_reply/4` |
| **Transient errors** | Must always reply or send an error | `{:noreply, state}` lets you intentionally drop replies (Knossos records as `:info`) |
| **Async operations** | N/A — single-threaded by design | `handle_info/2` receives results from spawned tasks, Bridges, transport layers |
| **Init lifecycle** | No callback; init is handled silently | `handle_init/3` callback for cluster-aware setup |
| **Error codes** | Raw integers, no helpers | `MaelstromNexus.Message.error_code/1` with named atoms |
| **Supervision** | `run_forever` — no supervision tree integration | `start_link/2` for embedding in supervision trees |

### When to use which

- **Use `maelstrom`** for learning exercises, single-node-logic workloads, and
  quick prototyping where everything fits in one `handle_message`.
- **Use `maelstrom_nexus`** when your system has multiple cooperating processes,
  async operations, or custom transport layers that need to emit Maelstrom
  messages.

## License

MIT

