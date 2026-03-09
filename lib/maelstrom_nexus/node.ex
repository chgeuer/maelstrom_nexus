defmodule MaelstromNexus.Node do
  @moduledoc """
  GenServer that implements the Maelstrom protocol core.

  Handles the init handshake, routes incoming messages to handler callbacks,
  manages message ID sequencing, and provides a multi-process API for
  sending messages to stdout.

  Any BEAM process can call `send_msg/3`, `reply/3`, etc. — messages are
  serialized through this GenServer to ensure atomic JSON line output.
  """

  use GenServer

  alias MaelstromNexus.{Message, Reader}

  defstruct [
    :handler,
    :handler_state,
    :node_id,
    :node_ids,
    :output,
    :input,
    msg_id: 1
  ]

  @type t :: %__MODULE__{
          handler: module(),
          handler_state: term(),
          node_id: String.t() | nil,
          node_ids: [String.t()] | nil,
          output: IO.device(),
          input: Enumerable.t() | nil,
          msg_id: non_neg_integer()
        }

  # --- Client API ---

  @doc false
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sends an arbitrary message to `dest`. Callable from any process."
  @spec send_msg(GenServer.server(), String.t(), map()) :: :ok
  def send_msg(server, dest, body) when is_binary(dest) and is_map(body) do
    GenServer.call(server, {:send_msg, dest, body})
  end

  @doc "Sends a reply to an incoming message. Callable from any process."
  @spec reply(GenServer.server(), map(), map()) :: :ok
  def reply(server, original_msg, reply_body) when is_map(original_msg) and is_map(reply_body) do
    GenServer.call(server, {:reply, original_msg, reply_body})
  end

  @doc "Sends an error reply to an incoming message. Callable from any process."
  @spec error_reply(GenServer.server(), map(), non_neg_integer(), String.t()) :: :ok
  def error_reply(server, original_msg, code, text)
      when is_map(original_msg) and is_integer(code) and is_binary(text) do
    GenServer.call(server, {:error_reply, original_msg, code, text})
  end

  @doc "Returns the node ID assigned by Maelstrom during init."
  @spec node_id(GenServer.server()) :: String.t() | nil
  def node_id(server), do: GenServer.call(server, :node_id)

  @doc "Returns all node IDs in the cluster."
  @spec node_ids(GenServer.server()) :: [String.t()] | nil
  def node_ids(server), do: GenServer.call(server, :node_ids)

  # --- GenServer Callbacks ---

  @impl GenServer
  def init(opts) do
    handler = Keyword.fetch!(opts, :handler)
    handler_args = Keyword.get(opts, :handler_args, [])
    output = Keyword.get(opts, :output, :stdio)
    input = Keyword.get(opts, :input)

    case handler.init(handler_args) do
      {:ok, handler_state} ->
        state = %__MODULE__{
          handler: handler,
          handler_state: handler_state,
          output: output,
          input: input
        }

        if input do
          {:ok, _pid} = Reader.start_link(input, self())
        end

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # --- Incoming Maelstrom messages (from Reader) ---

  @impl GenServer
  def handle_info({:maelstrom_input, message}, state) do
    state = dispatch_message(state, message)
    {:noreply, state}
  end

  def handle_info(:maelstrom_input_closed, state) do
    {:stop, :normal, state}
  end

  # All other BEAM messages are forwarded to the handler's handle_info
  def handle_info(msg, state) do
    case state.handler.handle_info(msg, state.handler_state) do
      {:noreply, new_handler_state} ->
        {:noreply, %{state | handler_state: new_handler_state}}

      {:send, dest, body, new_handler_state} ->
        state = %{state | handler_state: new_handler_state}
        {state, _msg} = emit_outgoing(state, dest, body)
        {:noreply, state}

      {:reply_to, original_msg, reply_body, new_handler_state} ->
        state = %{state | handler_state: new_handler_state}
        {state, _msg} = emit_reply(state, original_msg, reply_body)
        {:noreply, state}

      {:error_to, original_msg, code, text, new_handler_state} ->
        state = %{state | handler_state: new_handler_state}
        {state, _msg} = emit_error_reply(state, original_msg, code, text)
        {:noreply, state}
    end
  end

  # --- Synchronous API calls ---

  @impl GenServer
  def handle_call({:send_msg, dest, body}, _from, state) do
    {state, _msg} = emit_outgoing(state, dest, body)
    {:reply, :ok, state}
  end

  def handle_call({:reply, original_msg, reply_body}, _from, state) do
    {state, _msg} = emit_reply(state, original_msg, reply_body)
    {:reply, :ok, state}
  end

  def handle_call({:error_reply, original_msg, code, text}, _from, state) do
    {state, _msg} = emit_error_reply(state, original_msg, code, text)
    {:reply, :ok, state}
  end

  def handle_call(:node_id, _from, state), do: {:reply, state.node_id, state}
  def handle_call(:node_ids, _from, state), do: {:reply, state.node_ids, state}

  # --- Message Dispatch ---

  defp dispatch_message(state, %{"body" => %{"type" => "init"}} = msg) do
    handle_init(state, msg)
  end

  defp dispatch_message(state, %{"body" => %{"type" => type}} = msg) do
    handle_workload_message(state, type, msg)
  end

  defp dispatch_message(state, _msg), do: state

  # --- Init Handshake ---

  defp handle_init(
         state,
         %{
           "body" => %{
             "type" => "init",
             "node_id" => node_id,
             "node_ids" => node_ids
           }
         } = msg
       ) do
    state = %{state | node_id: node_id, node_ids: node_ids}

    case state.handler.handle_init(node_id, node_ids, state.handler_state) do
      {:ok, new_handler_state} ->
        state = %{state | handler_state: new_handler_state}
        {state, _msg} = emit_reply(state, msg, %{"type" => "init_ok"})
        state

      {:error, code, text, new_handler_state} ->
        state = %{state | handler_state: new_handler_state}
        {state, _msg} = emit_error_reply(state, msg, code, text)
        state
    end
  end

  # --- Workload Message Dispatch ---

  defp handle_workload_message(state, type, %{"body" => body} = msg) do
    case state.handler.handle_message(type, body, msg, state.handler_state) do
      {:reply, reply_body, new_handler_state} ->
        state = %{state | handler_state: new_handler_state}
        {state, _msg} = emit_reply(state, msg, reply_body)
        state

      {:noreply, new_handler_state} ->
        %{state | handler_state: new_handler_state}

      {:error, code, text, new_handler_state} ->
        state = %{state | handler_state: new_handler_state}
        {state, _msg} = emit_error_reply(state, msg, code, text)
        state
    end
  end

  # --- Output Helpers ---

  defp emit_reply(state, incoming_msg, reply_body) do
    msg = Message.reply(incoming_msg, reply_body, state.msg_id)
    write_output(state.output, msg)
    {%{state | msg_id: state.msg_id + 1}, msg}
  end

  defp emit_error_reply(state, incoming_msg, code, text) do
    msg = Message.error_reply(incoming_msg, code, text, state.msg_id)
    write_output(state.output, msg)
    {%{state | msg_id: state.msg_id + 1}, msg}
  end

  defp emit_outgoing(state, dest, body) do
    msg = Message.outgoing(state.node_id, dest, body, state.msg_id)
    write_output(state.output, msg)
    {%{state | msg_id: state.msg_id + 1}, msg}
  end

  defp write_output(output, message) do
    IO.binwrite(output, Message.encode_line(message))
  end
end
