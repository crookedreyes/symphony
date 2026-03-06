defmodule SymphonyElixir.ClaudeCode.McpServer do
  @moduledoc """
  MCP (Model Context Protocol) JSON-RPC 2.0 server over TCP loopback.

  Exposes Symphony's dynamic tools (linear_graphql) to Claude Code via MCP.
  Claude Code connects to this server through a netcat bridge specified in the
  MCP config file written by `SymphonyElixir.ClaudeCode.McpConfig`.

  The server binds to an OS-assigned port on 127.0.0.1 and handles one
  connection at a time per active Claude Code turn.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Codex.DynamicTool

  @mcp_protocol_version "2024-11-05"
  @server_name "symphony"
  @server_version "0.1.0"

  @type t :: %{
          listen_socket: :gen_tcp.socket(),
          port: :inet.port_number(),
          workspace: Path.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec port(pid()) :: {:ok, :inet.port_number()} | {:error, term()}
  def port(pid) do
    GenServer.call(pid, :get_port)
  end

  @impl GenServer
  def init(opts) do
    workspace = Keyword.fetch!(opts, :workspace)

    case :gen_tcp.listen(0, [
           :binary,
           packet: :line,
           active: false,
           reuseaddr: true,
           ip: {127, 0, 0, 1}
         ]) do
      {:ok, listen_socket} ->
        {:ok, port} = :inet.port(listen_socket)
        Logger.debug("MCP server started on 127.0.0.1:#{port} for workspace=#{workspace}")

        # Run the accept loop in a separate process so the GenServer
        # remains responsive to handle_call(:get_port) immediately.
        server_pid = self()
        acceptor = spawn_link(fn -> accept_loop(listen_socket) end)
        _ = server_pid

        state = %{listen_socket: listen_socket, port: port, workspace: workspace, acceptor: acceptor}
        {:ok, state}

      {:error, reason} ->
        {:stop, {:failed_to_bind, reason}}
    end
  end

  @impl GenServer
  def handle_call(:get_port, _from, %{port: port} = state) do
    {:reply, {:ok, port}, state}
  end

  @impl GenServer
  def terminate(_reason, %{listen_socket: socket}) do
    :gen_tcp.close(socket)
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, client_socket} ->
        Logger.debug("MCP client connected")
        handle_client(client_socket)
        :gen_tcp.close(client_socket)
        accept_loop(listen_socket)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("MCP accept error: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end

  defp handle_client(socket) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, line} ->
        case Jason.decode(String.trim(line)) do
          {:ok, message} ->
            handle_message(socket, message)
            handle_client(socket)

          {:error, _} ->
            Logger.debug("MCP received non-JSON: #{String.trim(line)}")
            handle_client(socket)
        end

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        :ok

      {:error, reason} ->
        Logger.warning("MCP recv error: #{inspect(reason)}")
    end
  end

  defp handle_message(socket, %{"method" => "initialize", "id" => id}) do
    respond(socket, id, %{
      "protocolVersion" => @mcp_protocol_version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => @server_name, "version" => @server_version}
    })
  end

  defp handle_message(_socket, %{"method" => "notifications/initialized"}) do
    :ok
  end

  defp handle_message(socket, %{"method" => "tools/list", "id" => id}) do
    tools =
      DynamicTool.tool_specs()
      |> Enum.map(fn spec ->
        %{
          "name" => spec["name"],
          "description" => spec["description"],
          "inputSchema" => spec["inputSchema"]
        }
      end)

    respond(socket, id, %{"tools" => tools})
  end

  defp handle_message(socket, %{
         "method" => "tools/call",
         "id" => id,
         "params" => %{"name" => tool_name, "arguments" => arguments}
       }) do
    result = DynamicTool.execute(tool_name, arguments)
    mcp_content = to_mcp_content(result)
    is_error = not Map.get(result, "success", false)

    respond(socket, id, %{"content" => mcp_content, "isError" => is_error})
  end

  defp handle_message(socket, %{"method" => "tools/call", "id" => id, "params" => params}) do
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments", %{})
    result = DynamicTool.execute(tool_name, arguments)
    mcp_content = to_mcp_content(result)
    is_error = not Map.get(result, "success", false)

    respond(socket, id, %{"content" => mcp_content, "isError" => is_error})
  end

  defp handle_message(_socket, %{"method" => method}) do
    Logger.debug("MCP ignoring notification: #{method}")
    :ok
  end

  defp handle_message(_socket, message) do
    Logger.debug("MCP unhandled message: #{inspect(message)}")
    :ok
  end

  defp respond(socket, id, result) do
    response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    :gen_tcp.send(socket, response <> "\n")
  end

  # Convert DynamicTool's contentItems format to MCP content format:
  # DynamicTool: %{"contentItems" => [%{"type" => "inputText", "text" => "..."}]}
  # MCP:         [%{"type" => "text", "text" => "..."}]
  defp to_mcp_content(%{"contentItems" => items}) when is_list(items) do
    Enum.map(items, fn
      %{"type" => "inputText", "text" => text} -> %{"type" => "text", "text" => text}
      %{"type" => type, "text" => text} -> %{"type" => type, "text" => text}
      item -> item
    end)
  end

  defp to_mcp_content(_result) do
    [%{"type" => "text", "text" => "Tool executed with no content"}]
  end
end
