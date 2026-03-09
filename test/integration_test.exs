defmodule MaelstromNexus.IntegrationTest do
  use ExUnit.Case, async: true

  @moduledoc """
  End-to-end test: simulates a complete Maelstrom session by feeding
  JSON lines through a stream and reading output.
  """

  defmodule EchoWorkload do
    use MaelstromNexus

    @impl true
    def handle_message("echo", body, _msg, state) do
      {:reply, %{"type" => "echo_ok", "echo" => body["echo"]}, state}
    end
  end

  defmodule LinKVWorkload do
    use MaelstromNexus

    @impl true
    def init(_args), do: {:ok, %{store: %{}}}

    @impl true
    def handle_init(node_id, node_ids, state) do
      {:ok, Map.merge(state, %{node_id: node_id, node_ids: node_ids})}
    end

    @impl true
    def handle_message("read", body, _msg, state) do
      case Map.fetch(state.store, body["key"]) do
        {:ok, value} ->
          {:reply, %{"type" => "read_ok", "value" => value}, state}

        :error ->
          {:error, 20, "key does not exist", state}
      end
    end

    def handle_message("write", body, _msg, state) do
      store = Map.put(state.store, body["key"], body["value"])
      {:reply, %{"type" => "write_ok"}, %{state | store: store}}
    end

    def handle_message("cas", body, _msg, state) do
      key = body["key"]

      from = body["from"]

      case Map.fetch(state.store, key) do
        {:ok, ^from} ->
          store = Map.put(state.store, key, body["to"])
          {:reply, %{"type" => "cas_ok"}, %{state | store: store}}

        {:ok, _other} ->
          {:error, 22, "precondition failed", state}

        :error ->
          {:error, 20, "key does not exist", state}
      end
    end
  end

  defp run_session(handler, messages, opts \\ []) do
    json_lines = Enum.map(messages, &(Jason.encode!(&1) <> "\n"))
    input = json_lines
    output = StringIO.open("") |> elem(1)

    handler_args = Keyword.get(opts, :handler_args, [])

    MaelstromNexus.run(handler,
      input: input,
      output: output,
      handler_args: handler_args,
      name: :"test_#{:erlang.unique_integer([:positive])}"
    )

    {_in, content} = StringIO.contents(output)

    content
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  describe "echo workload end-to-end" do
    test "init + echo produces correct responses" do
      messages = [
        %{
          "src" => "c0",
          "dest" => "n0",
          "body" => %{"type" => "init", "msg_id" => 0, "node_id" => "n0", "node_ids" => ["n0"]}
        },
        %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{"type" => "echo", "msg_id" => 1, "echo" => "hello"}
        }
      ]

      replies = run_session(EchoWorkload, messages)

      assert length(replies) == 2

      [init_reply, echo_reply] = replies

      assert init_reply["body"]["type"] == "init_ok"
      assert init_reply["body"]["in_reply_to"] == 0

      assert echo_reply["body"]["type"] == "echo_ok"
      assert echo_reply["body"]["echo"] == "hello"
      assert echo_reply["body"]["in_reply_to"] == 1
    end
  end

  describe "lin-kv workload end-to-end" do
    test "write then read returns written value" do
      messages = [
        %{
          "src" => "c0",
          "dest" => "n0",
          "body" => %{
            "type" => "init",
            "msg_id" => 0,
            "node_id" => "n0",
            "node_ids" => ["n0"]
          }
        },
        %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{"type" => "write", "msg_id" => 1, "key" => "x", "value" => 42}
        },
        %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{"type" => "read", "msg_id" => 2, "key" => "x"}
        }
      ]

      replies = run_session(LinKVWorkload, messages)
      read_reply = Enum.find(replies, &(&1["body"]["type"] == "read_ok"))

      assert read_reply["body"]["value"] == 42
    end

    test "read of missing key returns error 20" do
      messages = [
        %{
          "src" => "c0",
          "dest" => "n0",
          "body" => %{
            "type" => "init",
            "msg_id" => 0,
            "node_id" => "n0",
            "node_ids" => ["n0"]
          }
        },
        %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{"type" => "read", "msg_id" => 1, "key" => "missing"}
        }
      ]

      replies = run_session(LinKVWorkload, messages)
      error = Enum.find(replies, &(&1["body"]["type"] == "error"))

      assert error["body"]["code"] == 20
    end

    test "cas with correct precondition succeeds" do
      messages = [
        %{
          "src" => "c0",
          "dest" => "n0",
          "body" => %{
            "type" => "init",
            "msg_id" => 0,
            "node_id" => "n0",
            "node_ids" => ["n0"]
          }
        },
        %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{"type" => "write", "msg_id" => 1, "key" => "x", "value" => 1}
        },
        %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{
            "type" => "cas",
            "msg_id" => 2,
            "key" => "x",
            "from" => 1,
            "to" => 2
          }
        },
        %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{"type" => "read", "msg_id" => 3, "key" => "x"}
        }
      ]

      replies = run_session(LinKVWorkload, messages)
      cas_reply = Enum.find(replies, &(&1["body"]["type"] == "cas_ok"))
      read_reply = Enum.find(replies, &(&1["body"]["type"] == "read_ok"))

      assert cas_reply != nil
      assert read_reply["body"]["value"] == 2
    end

    test "cas with wrong precondition returns error 22" do
      messages = [
        %{
          "src" => "c0",
          "dest" => "n0",
          "body" => %{
            "type" => "init",
            "msg_id" => 0,
            "node_id" => "n0",
            "node_ids" => ["n0"]
          }
        },
        %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{"type" => "write", "msg_id" => 1, "key" => "x", "value" => 1}
        },
        %{
          "src" => "c1",
          "dest" => "n0",
          "body" => %{
            "type" => "cas",
            "msg_id" => 2,
            "key" => "x",
            "from" => 99,
            "to" => 2
          }
        }
      ]

      replies = run_session(LinKVWorkload, messages)
      error = Enum.find(replies, &(&1["body"]["type"] == "error"))

      assert error["body"]["code"] == 22
    end
  end
end
