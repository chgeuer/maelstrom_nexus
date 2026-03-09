defmodule MaelstromNexus.MessageTest do
  use ExUnit.Case, async: true

  alias MaelstromNexus.Message

  describe "decode_line/1" do
    test "decodes valid JSON" do
      json = ~s|{"src":"c0","dest":"n0","body":{"type":"echo","msg_id":1}}|
      assert {:ok, %{"src" => "c0", "dest" => "n0"}} = Message.decode_line(json)
    end

    test "handles trailing newline" do
      json = ~s|{"src":"c0","dest":"n0","body":{"type":"echo"}}\n|
      assert {:ok, %{"src" => "c0"}} = Message.decode_line(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = Message.decode_line("not json")
    end
  end

  describe "encode_line/1" do
    test "encodes map to JSON with trailing newline" do
      msg = %{"src" => "n0", "dest" => "c0", "body" => %{"type" => "echo_ok"}}
      encoded = Message.encode_line(msg)
      assert String.ends_with?(encoded, "\n")
      assert {:ok, ^msg} = Jason.decode(String.trim(encoded))
    end
  end

  describe "reply/3" do
    test "builds reply with swapped src/dest and in_reply_to" do
      incoming = %{
        "src" => "c0",
        "dest" => "n0",
        "body" => %{"type" => "echo", "msg_id" => 42, "echo" => "hello"}
      }

      reply = Message.reply(incoming, %{"type" => "echo_ok", "echo" => "hello"}, 1)

      assert reply["src"] == "n0"
      assert reply["dest"] == "c0"
      assert reply["body"]["type"] == "echo_ok"
      assert reply["body"]["in_reply_to"] == 42
      assert reply["body"]["msg_id"] == 1
      assert reply["body"]["echo"] == "hello"
    end
  end

  describe "error_reply/4" do
    test "builds error with code and text" do
      incoming = %{
        "src" => "c0",
        "dest" => "n0",
        "body" => %{"type" => "read", "msg_id" => 5}
      }

      reply = Message.error_reply(incoming, 20, "key does not exist", 1)

      assert reply["body"]["type"] == "error"
      assert reply["body"]["code"] == 20
      assert reply["body"]["text"] == "key does not exist"
      assert reply["body"]["in_reply_to"] == 5
    end
  end

  describe "outgoing/4" do
    test "builds outgoing message without in_reply_to" do
      msg = Message.outgoing("n0", "n1", %{"type" => "gossip", "data" => [1, 2]}, 7)

      assert msg["src"] == "n0"
      assert msg["dest"] == "n1"
      assert msg["body"]["type"] == "gossip"
      assert msg["body"]["msg_id"] == 7
      refute Map.has_key?(msg["body"], "in_reply_to")
    end
  end

  describe "error_code/1" do
    test "returns known codes" do
      assert Message.error_code(:timeout) == 0
      assert Message.error_code(:not_supported) == 10
      assert Message.error_code(:temporarily_unavailable) == 11
      assert Message.error_code(:key_does_not_exist) == 20
      assert Message.error_code(:precondition_failed) == 22
      assert Message.error_code(:txn_conflict) == 30
    end

    test "raises for unknown code" do
      assert_raise KeyError, fn -> Message.error_code(:nonexistent) end
    end
  end
end
