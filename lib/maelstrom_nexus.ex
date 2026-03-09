defmodule MaelstromNexus do
  @moduledoc """
  A multi-process Maelstrom protocol library for Elixir.

  Unlike single-GenServer Maelstrom libraries, MaelstromNexus is designed for
  complex distributed systems (consensus engines, replicated state machines)
  where multiple BEAM processes need to coordinate message flow through
  Maelstrom's stdin/stdout JSON protocol.

  ## Usage

  Define a handler module:

      defmodule MyWorkload do
        use MaelstromNexus

        @impl true
        def init(_args), do: {:ok, %{}}

        @impl true
        def handle_message("echo", body, _msg, state) do
          {:reply, %{"type" => "echo_ok", "echo" => body["echo"]}, state}
        end
      end

  Run it:

      MaelstromNexus.run(MyWorkload)

  Or with options:

      MaelstromNexus.run(MyWorkload, name: {:global, :my_node})

  ## Multi-process sending

  Any BEAM process can send messages through the nexus:

      MaelstromNexus.send_msg(node, "n1", %{"type" => "my_custom_msg", "data" => 42})
      MaelstromNexus.reply(node, stored_original_msg, %{"type" => "write_ok"})

  ## Callbacks

  - `c:init/1` — initialize handler state
  - `c:handle_init/3` — called after Maelstrom init handshake (node_id assigned)
  - `c:handle_message/4` — handle an incoming Maelstrom message
  - `c:handle_info/2` — handle BEAM messages from other processes
  """

  alias MaelstromNexus.Node

  @type state :: term()
  @type body :: map()

  @type message_result ::
          {:reply, body(), state()}
          | {:noreply, state()}
          | {:error, non_neg_integer(), String.t(), state()}

  @type info_result :: {:noreply, state()}

  @doc """
  Called when the handler starts. Return `{:ok, initial_state}`.
  """
  @callback init(args :: term()) :: {:ok, state()}

  @doc """
  Called after the Maelstrom init handshake completes.

  Receives the assigned `node_id` and the list of all `node_ids` in the cluster.
  Use this to set up cluster-aware state (membership, topology, etc.).
  """
  @callback handle_init(node_id :: String.t(), node_ids :: [String.t()], state()) ::
              {:ok, state()}

  @doc """
  Called for each incoming Maelstrom message (except `init`, which is handled
  automatically).

  `type` is the `"type"` field from the message body, extracted for convenience.
  `body` is the full body map. `msg` is the complete message including `src`/`dest`.

  Return values:
  - `{:reply, reply_body, new_state}` — send a reply to the sender
  - `{:noreply, new_state}` — absorb the message silently (e.g. transient errors)
  - `{:error, code, text, new_state}` — send a Maelstrom error reply
  """
  @callback handle_message(
              type :: String.t(),
              body :: body(),
              msg :: map(),
              state()
            ) :: message_result()

  @doc """
  Called for BEAM messages sent to the Node process from other processes.

  Use this to handle async operation results, transport envelope deliveries,
  timer messages, etc.

  Within this callback, use `MaelstromNexus.send_msg/3` or
  `MaelstromNexus.reply/3` to emit Maelstrom messages as side effects.
  """
  @callback handle_info(msg :: term(), state()) :: info_result()

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour MaelstromNexus

      @impl MaelstromNexus
      def init(_args), do: {:ok, %{}}

      @impl MaelstromNexus
      def handle_init(_node_id, _node_ids, state), do: {:ok, state}

      @impl MaelstromNexus
      def handle_info(_msg, state), do: {:noreply, state}

      defoverridable init: 1, handle_init: 3, handle_info: 2

      @doc "Convenience to start this handler with `MaelstromNexus.run/2`."
      def run(opts \\ []), do: MaelstromNexus.run(__MODULE__, opts)
    end
  end

  # --- Public API ---

  @doc """
  Starts a MaelstromNexus node with the given handler module.

  Reads from stdin and writes to stdout by default. Blocks until stdin closes.

  ## Options

  - `:name` — registered name for the GenServer (default: handler module name)
  - `:handler_args` — arguments passed to `c:init/1` (default: `[]`)
  - `:input` — input stream (default: `IO.stream(:line)`)
  - `:output` — output IO device (default: `:stdio`)
  """
  @spec run(module(), keyword()) :: :ok | {:error, term()}
  def run(handler, opts \\ []) do
    name = Keyword.get(opts, :name, handler)
    input = Keyword.get(opts, :input, IO.stream(:line))
    output = Keyword.get(opts, :output, :stdio)
    handler_args = Keyword.get(opts, :handler_args, [])

    node_opts = [
      handler: handler,
      handler_args: handler_args,
      name: name,
      input: input,
      output: output
    ]

    case Node.start_link(node_opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, :normal} -> :ok
          {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts a MaelstromNexus node as a child in a supervision tree.

  Unlike `run/2`, this does not block — it returns `{:ok, pid}`.
  You must provide your own input stream via the `:input` option,
  or start the Reader separately.

  ## Options

  Same as `run/2`.
  """
  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(handler, opts \\ []) do
    name = Keyword.get(opts, :name, handler)
    handler_args = Keyword.get(opts, :handler_args, [])
    output = Keyword.get(opts, :output, :stdio)
    input = Keyword.get(opts, :input)

    Node.start_link(
      handler: handler,
      handler_args: handler_args,
      name: name,
      input: input,
      output: output
    )
  end

  @doc """
  Sends a message to `dest` through the nexus. Callable from any process.

  The message gets a unique `msg_id` assigned automatically.
  """
  @spec send_msg(GenServer.server(), String.t(), body()) :: :ok
  def send_msg(server, dest, body), do: Node.send_msg(server, dest, body)

  @doc """
  Sends a reply to a previously received message. Callable from any process.

  Automatically sets `in_reply_to` from the original message's `msg_id`.
  Store the original message in your handler state if you need to reply later
  (e.g. after an async operation completes).
  """
  @spec reply(GenServer.server(), map(), body()) :: :ok
  def reply(server, original_msg, reply_body), do: Node.reply(server, original_msg, reply_body)

  @doc """
  Sends a Maelstrom error reply. Callable from any process.

  See `MaelstromNexus.Message.error_codes/0` for standard error codes.
  """
  @spec error_reply(GenServer.server(), map(), non_neg_integer(), String.t()) :: :ok
  def error_reply(server, original_msg, code, text),
    do: Node.error_reply(server, original_msg, code, text)

  @doc "Returns the node ID assigned during the Maelstrom init handshake."
  @spec node_id(GenServer.server()) :: String.t() | nil
  def node_id(server), do: Node.node_id(server)

  @doc "Returns all node IDs in the Maelstrom cluster."
  @spec node_ids(GenServer.server()) :: [String.t()] | nil
  def node_ids(server), do: Node.node_ids(server)

  @doc """
  Logs a message to stderr (visible in Maelstrom's log output).

  Maelstrom captures stderr for debugging; stdout is reserved for protocol messages.
  """
  @spec log(String.t()) :: :ok
  def log(message) when is_binary(message) do
    IO.write(:standard_error, message <> "\n")
    :ok
  end
end
