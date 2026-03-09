defmodule MaelstromNexus.Reader do
  @moduledoc """
  Reads JSON lines from an input stream (typically stdin) and forwards
  decoded messages to the Node process.

  Spawned as a linked Task so that stdin EOF or crash propagates
  to the Node.
  """

  alias MaelstromNexus.Message

  @doc """
  Starts a linked task that reads lines from `input` and sends
  decoded messages to `receiver`.

  Sends `{:maelstrom_input, message}` for each valid JSON line
  and `:maelstrom_input_closed` when the stream ends.
  """
  @spec start_link(Enumerable.t(), pid()) :: {:ok, pid()}
  def start_link(input, receiver) when is_pid(receiver) do
    {:ok, pid} =
      Task.start_link(fn ->
        input
        |> Stream.each(fn line ->
          case Message.decode_line(line) do
            {:ok, message} -> send(receiver, {:maelstrom_input, message})
            {:error, _reason} -> :skip
          end
        end)
        |> Stream.run()

        send(receiver, :maelstrom_input_closed)
      end)

    {:ok, pid}
  end
end
