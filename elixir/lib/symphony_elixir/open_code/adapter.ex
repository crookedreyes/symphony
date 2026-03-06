defmodule SymphonyElixir.OpenCode.Adapter do
  @moduledoc """
  OpenCode runtime adapter for Symphony.

  Implements the same three-function contract as Codex and Claude Code adapters:
  `start_session/1`, `run_turn/4`, `stop_session/1`.

  Manages an `opencode serve` process per workspace, communicates via REST API,
  and streams events via SSE.
  """

  require Logger

  alias SymphonyElixir.ClaudeCode.McpServer
  alias SymphonyElixir.Config
  alias SymphonyElixir.OpenCode.{Client, ConfigWriter, SseListener}

  @type session :: %{
          port: port(),
          http_port: non_neg_integer(),
          base_url: String.t(),
          session_id: String.t(),
          mcp_server_pid: pid(),
          workspace: Path.t(),
          turn_count: non_neg_integer()
        }

  # ---------- start_session ----------

  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    with :ok <- validate_workspace(workspace),
         {:ok, mcp_pid} <- McpServer.start_link(workspace: workspace),
         {:ok, config_path} <- ConfigWriter.write(workspace, mcp_pid),
         {:ok, http_port} <- find_free_port(),
         {:ok, os_port} <- start_server(workspace, http_port),
         :ok <- await_healthy("http://127.0.0.1:#{http_port}"),
         {:ok, session_resp} <- create_session("http://127.0.0.1:#{http_port}", workspace) do
      _ = config_path
      session_id = extract_session_id(session_resp)

      Logger.debug(
        "OpenCode session ready session_id=#{session_id} workspace=#{workspace} http_port=#{http_port}"
      )

      {:ok,
       %{
         port: os_port,
         http_port: http_port,
         base_url: "http://127.0.0.1:#{http_port}",
         session_id: session_id,
         mcp_server_pid: mcp_pid,
         workspace: Path.expand(workspace),
         turn_count: 0
       }}
    end
  end

  # ---------- run_turn ----------

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session = %{session | turn_count: session.turn_count + 1}
    turn_id = "#{session.session_id}-turn-#{session.turn_count}"

    emit(on_message, :session_started, %{
      session_id: session.session_id,
      turn_id: turn_id
    })

    {:ok, sse_pid} = SseListener.start(session.base_url, self())

    model_opts =
      case Config.open_code_model() do
        nil -> %{}
        model -> %{model: model}
      end

    prompt_task =
      Task.async(fn ->
        result = Client.send_message(session.base_url, session.session_id, prompt, model_opts)
        Logger.debug("OpenCode message completed: #{inspect(result, limit: 200)}")
        result
      end)

    timeout_ms = Config.open_code_turn_timeout_ms()
    result = receive_loop(session, prompt_task, sse_pid, on_message, timeout_ms)

    SseListener.stop(sse_pid)

    case result do
      {:ok, response} ->
        usage = extract_usage(response)

        Logger.info(
          "OpenCode turn completed for #{issue_context(issue)} session_id=#{session.session_id}"
        )

        emit(on_message, :turn_completed, %{
          session_id: session.session_id,
          turn_id: turn_id,
          usage: usage
        })

        {:ok, %{session_id: session.session_id, turn_id: turn_id, usage: usage}}

      {:error, reason} ->
        Logger.warning(
          "OpenCode turn failed for #{issue_context(issue)} session_id=#{session.session_id}: #{inspect(reason)}"
        )

        emit(on_message, :turn_ended_with_error, %{
          session_id: session.session_id,
          turn_id: turn_id,
          reason: reason
        })

        {:error, reason}
    end
  end

  # ---------- stop_session ----------

  @spec stop_session(session()) :: :ok
  def stop_session(%{base_url: base_url, session_id: session_id, port: os_port, mcp_server_pid: mcp_pid}) do
    # Best-effort session deletion
    _ = Client.delete_session(base_url, session_id)

    # Kill the opencode serve process
    kill_port(os_port)

    # Stop MCP server
    if is_pid(mcp_pid) and Process.alive?(mcp_pid) do
      GenServer.stop(mcp_pid, :normal, 5_000)
    end

    :ok
  rescue
    _ -> :ok
  end

  def stop_session(_), do: :ok

  # ---------- Private: server lifecycle ----------

  defp validate_workspace(workspace) when is_binary(workspace) do
    workspace_path = Path.expand(workspace)
    workspace_root = Path.expand(Config.workspace_root())
    root_prefix = workspace_root <> "/"

    cond do
      workspace_path == workspace_root ->
        {:error, {:invalid_workspace, :workspace_root, workspace_path}}

      not String.starts_with?(workspace_path <> "/", root_prefix) ->
        {:error, {:invalid_workspace, :outside_workspace_root, workspace_path, workspace_root}}

      true ->
        :ok
    end
  end

  defp find_free_port do
    case :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        {:ok, port}

      {:error, reason} ->
        {:error, {:no_free_port, reason}}
    end
  end

  defp start_server(workspace, http_port) do
    executable = System.find_executable(Config.open_code_command())

    if is_nil(executable) do
      command = Config.open_code_command()
      Logger.error("OpenCode binary not found: #{command}")
      {:error, {:opencode_not_found, command}}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"serve", ~c"--port", String.to_charlist(to_string(http_port))],
            cd: String.to_charlist(workspace),
            line: 1_048_576
          ]
        )

      {:ok, port}
    end
  end

  defp await_healthy(base_url) do
    startup_timeout = Config.open_code_startup_timeout_ms()
    deadline = System.monotonic_time(:millisecond) + startup_timeout
    poll_health(base_url, deadline, 100)
  end

  defp poll_health(base_url, deadline, delay) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      {:error, :startup_timeout}
    else
      case Client.health(base_url) do
        {:ok, _} ->
          :ok

        {:error, _} ->
          Process.sleep(min(delay, deadline - now))
          poll_health(base_url, deadline, min(delay * 2, 2_000))
      end
    end
  end

  defp create_session(base_url, workspace) do
    title = "symphony-#{Path.basename(workspace)}"
    Client.create_session(base_url, title)
  end

  defp extract_session_id(%{"id" => id}), do: id
  defp extract_session_id(%{"sessionID" => id}), do: id
  defp extract_session_id(%{"session_id" => id}), do: id
  defp extract_session_id(resp) when is_map(resp), do: Map.get(resp, "id", "unknown")

  # ---------- Private: turn receive loop ----------

  defp receive_loop(session, prompt_task, sse_pid, on_message, timeout_ms) do
    ref = prompt_task.ref

    receive do
      {:sse_event, type, data} ->
        handle_sse_event(type, data, on_message)
        receive_loop(session, prompt_task, sse_pid, on_message, timeout_ms)

      {^ref, {:ok, result}} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {^ref, {:error, reason}} ->
        Process.demonitor(ref, [:flush])
        {:error, reason}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:prompt_task_crashed, reason}}

      {port, {:exit_status, status}} when port == session.port ->
        # Server crashed mid-turn
        Task.shutdown(prompt_task, :brutal_kill)
        {:error, {:server_crashed, status}}
    after
      timeout_ms ->
        Task.shutdown(prompt_task, :brutal_kill)
        _ = Client.abort(session.base_url, session.session_id)
        {:error, :turn_timeout}
    end
  end

  defp handle_sse_event("message.part.updated", data, on_message) do
    emit(on_message, :notification, %{type: :notification, payload: data})
  end

  defp handle_sse_event("message.updated", data, on_message) do
    tokens = get_in(data, ["info", "tokens"]) || %{}
    role = get_in(data, ["info", "role"])

    if role == "assistant" and map_size(tokens) > 0 do
      usage = SseListener.normalize_usage(tokens)
      Logger.debug("OpenCode SSE token update: #{inspect(usage)}")
      emit(on_message, :notification, %{type: :notification, usage: usage})
    end
  end

  defp handle_sse_event("session.idle", _data, on_message) do
    emit(on_message, :notification, %{type: :turn_completed})
  end

  defp handle_sse_event("session.error", data, on_message) do
    emit(on_message, :notification, %{type: :turn_failed, error: data})
  end

  defp handle_sse_event(_type, _data, _on_message), do: :ok

  # ---------- Private: helpers ----------

  defp extract_usage(%{"info" => %{"tokens" => tokens}}) when is_map(tokens) do
    SseListener.normalize_usage(tokens)
  end

  defp extract_usage(%{"tokens" => tokens}) when is_map(tokens) do
    SseListener.normalize_usage(tokens)
  end

  defp extract_usage(_), do: %{}

  defp kill_port(port) when is_port(port) do
    try do
      Port.command(port, <<3>>)
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp kill_port(_), do: :ok

  defp emit(on_message, event, details) when is_function(on_message, 1) do
    message =
      details
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(issue) when is_map(issue) do
    "issue=#{inspect(Map.take(issue, [:id, :identifier]))}"
  end

  defp default_on_message(_), do: :ok
end
