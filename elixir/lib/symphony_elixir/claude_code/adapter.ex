defmodule SymphonyElixir.ClaudeCode.Adapter do
  @moduledoc """
  Claude Code CLI adapter for Symphony, replacing `SymphonyElixir.Codex.AppServer`.

  Implements the same three-function contract (`start_session/1`, `run_turn/3`,
  `stop_session/1`) so that `AgentRunner` works with Claude Code without changes.

  Key differences from Codex app-server:
  - Session continuity via `--session-id UUID` (UUID persisted to workspace disk)
  - Auto-approval via `--dangerously-skip-permissions`
  - Tool injection via MCP over TCP loopback (`--mcp-config`)
  - Events parsed from `--output-format stream-json` NDJSON stream
  """

  require Logger

  alias SymphonyElixir.ClaudeCode.{McpConfig, McpServer, Session, StreamParser}
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576

  @type session :: %{
          session: Session.t(),
          mcp_server_pid: pid(),
          mcp_config_path: Path.t(),
          workspace: Path.t()
        }

  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with :ok <- validate_workspace_cwd(workspace),
         {:ok, session} <- Session.load_or_create(workspace),
         {:ok, mcp_pid} <- McpServer.start_link(workspace: workspace),
         {:ok, mcp_port} <- McpServer.port(mcp_pid),
         {:ok, mcp_config_path} <- McpConfig.write(workspace, mcp_port) do
      Logger.debug("Claude Code session ready session_id=#{session.session_id} workspace=#{workspace} mcp_port=#{mcp_port}")

      {:ok,
       %{
         session: %{session | mcp_server_pid: mcp_pid},
         mcp_server_pid: mcp_pid,
         mcp_config_path: mcp_config_path,
         workspace: Path.expand(workspace)
       }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{session: session, mcp_config_path: mcp_config_path, workspace: workspace},
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    session = Session.increment_turn(session)
    turn_id = Session.turn_id(session)
    session_id = "#{session.session_id}-#{session.turn_count}"

    args = build_cli_args(session, prompt, mcp_config_path)

    case start_port(workspace, args) do
      {:ok, port} ->
        metadata = port_metadata(port)

        emit_message(
          on_message,
          :session_started,
          %{session_id: session_id, thread_id: session.session_id, turn_id: turn_id},
          metadata
        )

        timeout_ms = Config.claude_code_turn_timeout_ms()

        case await_completion(port, on_message, timeout_ms, metadata) do
          {:ok, result} ->
            Logger.info("Claude Code turn completed for #{issue_context(issue)} session_id=#{session_id}")

            :ok = Session.persist(session)
            {:ok, Map.merge(result, %{session_id: session_id, thread_id: session.session_id, turn_id: turn_id})}

          {:error, reason} ->
            Logger.warning("Claude Code turn ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{session_id: session_id, reason: reason},
              metadata
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Failed to start Claude Code for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{mcp_server_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  rescue
    _ -> :ok
  end

  def stop_session(_session), do: :ok

  defp build_cli_args(%Session{session_id: session_id, turn_count: turn_count}, prompt, mcp_config_path) do
    base_args = [
      "--print",
      "--verbose",
      "--output-format",
      "stream-json",
      "--dangerously-skip-permissions",
      "--mcp-config",
      mcp_config_path
    ]

    session_args =
      if turn_count > 1 do
        ["--resume", session_id]
      else
        ["--session-id", session_id]
      end

    model_args =
      case Config.claude_code_model() do
        nil -> []
        model -> ["--model", model]
      end

    base_args ++ session_args ++ model_args ++ [prompt]
  end

  defp start_port(workspace, args) do
    executable = System.find_executable(Config.claude_code_command())

    if is_nil(executable) do
      command = Config.claude_code_command()
      Logger.error("Claude Code binary not found: #{command}")
      {:error, {:claude_not_found, command}}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: Enum.map(args, &String.to_charlist/1),
            cd: String.to_charlist(workspace),
            env: [{~c"CLAUDECODE", false}, {~c"CLAUDE_CODE_ENTRYPOINT", false}],
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
      _ -> %{}
    end
  end

  defp await_completion(port, on_message, timeout_ms, metadata) do
    receive_loop(port, on_message, timeout_ms, "", metadata, false)
  end

  defp receive_loop(port, on_message, timeout_ms, pending_line, metadata, terminal_received) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_line(port, on_message, complete_line, timeout_ms, metadata, terminal_received)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(
          port,
          on_message,
          timeout_ms,
          pending_line <> to_string(chunk),
          metadata,
          terminal_received
        )

      {^port, {:exit_status, status}} ->
        handle_exit(status, terminal_received, on_message, metadata)
    after
      timeout_ms ->
        Port.close(port)
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, line, timeout_ms, metadata, terminal_received) do
    case StreamParser.parse_line(line) do
      {:terminal, event, details} ->
        emit_message(on_message, event, details, metadata)

        # Drain port until exit
        drain_port(port)

        case event do
          :turn_completed -> {:ok, details}
          _ -> {:error, {event, details}}
        end

      {:continue, event, details} ->
        emit_message(on_message, event, details, metadata)
        receive_loop(port, on_message, timeout_ms, "", metadata, terminal_received)
    end
  end

  defp handle_exit(status, terminal_received, on_message, metadata) do
    case StreamParser.parse_exit(status, terminal_received) do
      {:terminal, :turn_completed, details} ->
        emit_message(on_message, :turn_completed, details, metadata)
        {:ok, details}

      {:terminal, event, details} ->
        emit_message(on_message, event, details, metadata)
        {:error, {event, details}}
    end
  end

  defp drain_port(port) do
    receive do
      {^port, {:data, _}} -> drain_port(port)
      {^port, {:exit_status, _}} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())
    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace_cwd, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace_cwd, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(issue) when is_map(issue) do
    "issue=#{inspect(Map.take(issue, [:id, :identifier]))}"
  end

  defp default_on_message(_message), do: :ok
end
