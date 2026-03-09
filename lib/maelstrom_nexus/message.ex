defmodule MaelstromNexus.Message do
  @moduledoc """
  Pure functions for encoding, decoding, and constructing Maelstrom protocol messages.

  All Maelstrom messages are JSON objects with `src`, `dest`, and `body` fields.
  The `body` always contains a `type` field and usually a `msg_id`.
  """

  # --- Decoding ---

  @doc """
  Decodes a JSON line from stdin into a message map.

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  @spec decode_line(binary()) :: {:ok, map()} | {:error, term()}
  def decode_line(line) when is_binary(line) do
    line
    |> String.trim()
    |> Jason.decode()
  end

  # --- Encoding ---

  @doc """
  Encodes a message map to a JSON line (with trailing newline).
  """
  @spec encode_line(map()) :: binary()
  def encode_line(message) when is_map(message) do
    Jason.encode!(message) <> "\n"
  end

  # --- Message Construction ---

  @doc """
  Builds a reply message for the given incoming message.

  Automatically sets `src`/`dest` (swapped from incoming) and `in_reply_to`.
  The caller provides the reply body (which must include `"type"`).
  """
  @spec reply(map(), map(), non_neg_integer()) :: map()
  def reply(
        %{"src" => src, "dest" => dest, "body" => %{"msg_id" => incoming_msg_id}},
        reply_body,
        msg_id
      )
      when is_map(reply_body) do
    %{
      "src" => dest,
      "dest" => src,
      "body" =>
        reply_body
        |> Map.put("msg_id", msg_id)
        |> Map.put("in_reply_to", incoming_msg_id)
    }
  end

  @doc """
  Builds an error reply for the given incoming message.

  Uses Maelstrom's standard error format with `code` and `text`.
  """
  @spec error_reply(map(), non_neg_integer(), String.t(), non_neg_integer()) :: map()
  def error_reply(incoming_msg, code, text, msg_id)
      when is_integer(code) and is_binary(text) do
    reply(incoming_msg, %{"type" => "error", "code" => code, "text" => text}, msg_id)
  end

  @doc """
  Builds an outgoing message (not a reply — no `in_reply_to`).
  """
  @spec outgoing(String.t(), String.t(), map(), non_neg_integer()) :: map()
  def outgoing(src, dest, body, msg_id)
      when is_binary(src) and is_binary(dest) and is_map(body) do
    %{
      "src" => src,
      "dest" => dest,
      "body" => Map.put(body, "msg_id", msg_id)
    }
  end

  # --- Standard Maelstrom Error Codes ---

  @doc "Maelstrom error codes as a map from atom to integer."
  @spec error_codes() :: %{atom() => non_neg_integer()}
  def error_codes do
    %{
      timeout: 0,
      node_not_found: 1,
      not_supported: 10,
      temporarily_unavailable: 11,
      malformed_request: 12,
      crash: 13,
      abort: 14,
      key_does_not_exist: 20,
      key_already_exists: 21,
      precondition_failed: 22,
      txn_conflict: 30
    }
  end

  @doc """
  Looks up the integer error code for a named error.

      iex> MaelstromNexus.Message.error_code(:key_does_not_exist)
      20
  """
  @spec error_code(atom()) :: non_neg_integer()
  def error_code(name) when is_atom(name) do
    Map.fetch!(error_codes(), name)
  end
end
