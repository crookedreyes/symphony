defmodule SymphonyElixir.ClaudeCode.Session do
  @moduledoc """
  Session state and disk persistence for Claude Code agent runs.

  A session maps to a single Linear issue workspace. The session UUID is persisted
  to disk so that Claude Code's `--resume` flag can restore conversation context
  across Symphony restarts.
  """

  @session_file ".symphony_claude_session_id"

  @type t :: %__MODULE__{
          session_id: String.t(),
          workspace: Path.t(),
          mcp_server_pid: pid() | nil,
          turn_count: non_neg_integer()
        }

  defstruct [:session_id, :workspace, :mcp_server_pid, turn_count: 0]

  @doc """
  Load an existing session UUID from disk, or create a new one.
  """
  @spec load_or_create(Path.t()) :: {:ok, t()} | {:error, term()}
  def load_or_create(workspace) when is_binary(workspace) do
    session_file = session_file_path(workspace)

    session_id =
      case File.read(session_file) do
        {:ok, contents} ->
          id = String.trim(contents)
          if valid_uuid?(id), do: id, else: generate_uuid()

        {:error, _} ->
          generate_uuid()
      end

    {:ok,
     %__MODULE__{
       session_id: session_id,
       workspace: Path.expand(workspace)
     }}
  end

  @doc """
  Persist the session UUID to disk so future runs can resume the conversation.
  """
  @spec persist(t()) :: :ok | {:error, term()}
  def persist(%__MODULE__{session_id: session_id, workspace: workspace}) do
    session_file = session_file_path(workspace)
    File.write(session_file, session_id)
  end

  @doc """
  Increment the turn counter and return updated session.
  """
  @spec increment_turn(t()) :: t()
  def increment_turn(%__MODULE__{turn_count: count} = session) do
    %{session | turn_count: count + 1}
  end

  @doc """
  Return the turn ID string for the current turn.
  """
  @spec turn_id(t()) :: String.t()
  def turn_id(%__MODULE__{session_id: session_id, turn_count: count}) do
    "#{session_id}-#{count}"
  end

  defp session_file_path(workspace) do
    Path.join(Path.expand(workspace), @session_file)
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format(
      "~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b",
      [a, b, :erlang.band(c, 0x0FFF), :erlang.bor(:erlang.band(d, 0x3FFF), 0x8000), e]
    )
    |> to_string()
  end

  defp valid_uuid?(id) when is_binary(id) do
    String.match?(id, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i)
  end
end
