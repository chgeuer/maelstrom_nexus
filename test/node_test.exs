defmodule MaelstromNexus.NodeTest do
  use ExUnit.Case, async: true

  alias MaelstromNexus.Node

  # --- Test handler modules ---

  defmodule EchoHandler do
    @behaviour MaelstromNexus

    @impl true
    def init(_args), do: {:ok, %{}}

    @impl true
    def handle_init(_node_id, _node_ids, state), do: {:ok, state}

    @impl true
    def handle_message("echo", body, _msg, state) do
      {:reply, %{"type" => "echo_ok", "echo" => body["echo"]}, state}
    end

    @impl true
    def handle_info(_msg, state), do: {:noreply, state}
  end

  defmodule StatefulHandler do
    @behaviour MaelstromNexus

    @impl true
    def init(args) do
      {:ok, %{store: %{}, test_pid: Keyword.get(args, :test_pid)}}
    end

    @impl true
    def handle_init(node_id, node_ids, state) do
      {:ok, Map.merge(state, %{node_id: node_id, node_ids: node_ids})}
    end

    @impl true
    def handle_message("write", body, _msg, state) do
      store = Map.put(state.store, body["key"], body["value"])
      {:reply, %{"type" => "write_ok"}, %{state | store: store}}
    end

    def handle_message("read", body, _msg, state) do
      case Map.fetch(state.store, body["key"]) do
        {:ok, value} ->
          {:reply, %{"type" => "read_ok", "value" => value}, state}

        :error ->
          {:error, 20, "key does not exist", state}
      end
    end

    def handle_message("noreply_test", _body, _msg, state) do
      {:noreply, state}
    end

    @impl true
    def handle_info({:async_result, value}, state) do
      if state.test_pid, do: send(state.test_pid, {:got_async, value})
      {:noreply, %{state | store: Map.put(state.store, "async", value)}}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  # --- Helpers ---

  defp start_node(handler, opts \\ []) do
    output = StringIO.open("") |> elem(1)

    node_opts =
      [handler: handler, output: output]
      |> Keyword.merge(opts)

    {:ok, pid} = Node.start_link(node_opts)
    {pid, output}
  end

  defp send_maelstrom(pid, message) do
    send(pid, {:maelstrom_input, message})
    # Give the GenServer time to process
    Process.sleep(10)
  end

  defp read_output(output) do
    {_input, content} = StringIO.contents(output)
    content
  end

  defp read_output_messages(output) do
    read_output(output)
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp init_message(node_id \\ "n0", node_ids \\ ["n0", "n1", "n2"]) do
    %{
      "src" => "c0",
      "dest" => node_id,
      "body" => %{
        "type" => "init",
        "msg_id" => 0,
        "node_id" => node_id,
        "node_ids" => node_ids
      }
    }
  end

  # --- Tests ---

  describe "init handshake" do
    test "responds with init_ok and stores node_id/node_ids" do
      {pid, output} = start_node(EchoHandler)
      send_maelstrom(pid, init_message())

      assert Node.node_id(pid) == "n0"
      assert Node.node_ids(pid) == ["n0", "n1", "n2"]

      [reply] = read_output_messages(output)
      assert reply["body"]["type"] == "init_ok"
      assert reply["body"]["in_reply_to"] == 0
      assert reply["src"] == "n0"
      assert reply["dest"] == "c0"
    end

    test "calls handler's handle_init callback" do
      {pid, _output} = start_node(StatefulHandler, handler_args: [test_pid: self()])
      send_maelstrom(pid, init_message("n1", ["n0", "n1"]))

      assert Node.node_id(pid) == "n1"
    end
  end

  describe "handle_message dispatch" do
    test "echo workload replies correctly" do
      {pid, output} = start_node(EchoHandler)
      send_maelstrom(pid, init_message())

      echo_msg = %{
        "src" => "c1",
        "dest" => "n0",
        "body" => %{"type" => "echo", "msg_id" => 10, "echo" => "hello world"}
      }

      send_maelstrom(pid, echo_msg)

      messages = read_output_messages(output)
      echo_reply = Enum.find(messages, &(&1["body"]["type"] == "echo_ok"))

      assert echo_reply["body"]["echo"] == "hello world"
      assert echo_reply["body"]["in_reply_to"] == 10
      assert echo_reply["dest"] == "c1"
    end

    test "stateful handler tracks writes and reads" do
      {pid, output} = start_node(StatefulHandler, handler_args: [test_pid: self()])
      send_maelstrom(pid, init_message())

      write_msg = %{
        "src" => "c1",
        "dest" => "n0",
        "body" => %{"type" => "write", "msg_id" => 10, "key" => "x", "value" => 42}
      }

      send_maelstrom(pid, write_msg)

      read_msg = %{
        "src" => "c1",
        "dest" => "n0",
        "body" => %{"type" => "read", "msg_id" => 11, "key" => "x"}
      }

      send_maelstrom(pid, read_msg)

      messages = read_output_messages(output)
      read_reply = Enum.find(messages, &(&1["body"]["type"] == "read_ok"))

      assert read_reply["body"]["value"] == 42
    end

    test "error reply for missing key" do
      {pid, output} = start_node(StatefulHandler, handler_args: [test_pid: self()])
      send_maelstrom(pid, init_message())

      read_msg = %{
        "src" => "c1",
        "dest" => "n0",
        "body" => %{"type" => "read", "msg_id" => 10, "key" => "missing"}
      }

      send_maelstrom(pid, read_msg)

      messages = read_output_messages(output)
      error = Enum.find(messages, &(&1["body"]["type"] == "error"))

      assert error["body"]["code"] == 20
      assert error["body"]["in_reply_to"] == 10
    end

    test "noreply produces no output for the message" do
      {pid, output} = start_node(StatefulHandler, handler_args: [test_pid: self()])
      send_maelstrom(pid, init_message())

      noreply_msg = %{
        "src" => "c1",
        "dest" => "n0",
        "body" => %{"type" => "noreply_test", "msg_id" => 10}
      }

      send_maelstrom(pid, noreply_msg)

      messages = read_output_messages(output)
      # Only the init_ok, no reply for noreply_test
      types = Enum.map(messages, & &1["body"]["type"])
      assert types == ["init_ok"]
    end
  end

  describe "multi-process API" do
    test "send_msg from another process" do
      {pid, output} = start_node(EchoHandler)
      send_maelstrom(pid, init_message())

      Node.send_msg(pid, "n1", %{"type" => "gossip", "values" => [1, 2, 3]})
      Process.sleep(10)

      messages = read_output_messages(output)
      gossip = Enum.find(messages, &(&1["body"]["type"] == "gossip"))

      assert gossip["src"] == "n0"
      assert gossip["dest"] == "n1"
      assert gossip["body"]["values"] == [1, 2, 3]
      assert is_integer(gossip["body"]["msg_id"])
    end

    test "reply from another process using stored message" do
      {pid, output} = start_node(StatefulHandler, handler_args: [test_pid: self()])
      send_maelstrom(pid, init_message())

      original = %{
        "src" => "c5",
        "dest" => "n0",
        "body" => %{"type" => "noreply_test", "msg_id" => 99}
      }

      send_maelstrom(pid, original)

      # Simulate an external process replying later
      Node.reply(pid, original, %{"type" => "write_ok"})
      Process.sleep(10)

      messages = read_output_messages(output)
      deferred_reply = Enum.find(messages, &(&1["body"]["type"] == "write_ok"))

      assert deferred_reply["body"]["in_reply_to"] == 99
      assert deferred_reply["dest"] == "c5"
    end

    test "error_reply from another process" do
      {pid, output} = start_node(EchoHandler)
      send_maelstrom(pid, init_message())

      original = %{
        "src" => "c1",
        "dest" => "n0",
        "body" => %{"type" => "echo", "msg_id" => 7, "echo" => "hi"}
      }

      Node.error_reply(pid, original, 11, "temporarily unavailable")
      Process.sleep(10)

      messages = read_output_messages(output)
      err = Enum.find(messages, &(&1["body"]["type"] == "error"))

      assert err["body"]["code"] == 11
      assert err["body"]["in_reply_to"] == 7
    end
  end

  describe "handle_info passthrough" do
    test "BEAM messages are forwarded to handler" do
      {pid, _output} = start_node(StatefulHandler, handler_args: [test_pid: self()])
      send_maelstrom(pid, init_message())

      send(pid, {:async_result, 999})

      assert_receive {:got_async, 999}, 500
    end
  end

  describe "message ID sequencing" do
    test "msg_id increments across messages" do
      {pid, output} = start_node(EchoHandler)
      send_maelstrom(pid, init_message())

      for i <- 1..3 do
        echo = %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{"type" => "echo", "msg_id" => i * 10, "echo" => "test"}
        }

        send_maelstrom(pid, echo)
      end

      messages = read_output_messages(output)
      msg_ids = Enum.map(messages, & &1["body"]["msg_id"])

      # IDs should be sequential starting from 1
      assert msg_ids == [1, 2, 3, 4]
    end
  end

  describe "stdin close" do
    test "node stops on input closed" do
      {pid, _output} = start_node(EchoHandler)
      ref = Process.monitor(pid)

      send(pid, :maelstrom_input_closed)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end

  describe "child_spec" do
    test "builds valid child spec from {handler, opts} tuple" do
      spec = MaelstromNexus.child_spec({EchoHandler, name: :test_echo})

      assert spec.id == :test_echo
      assert spec.start == {MaelstromNexus, :start_link, [EchoHandler, [name: :test_echo]]}
      assert spec.type == :worker
    end

    test "defaults name to handler module" do
      spec = MaelstromNexus.child_spec({EchoHandler, []})
      assert spec.id == EchoHandler
    end
  end
end
