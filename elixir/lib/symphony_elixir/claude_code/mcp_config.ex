defmodule SymphonyElixir.ClaudeCode.McpConfig do
  @moduledoc """
  Writes the MCP configuration file for Claude Code to connect to Symphony's
  local MCP server.

  Claude Code's `--mcp-config` flag expects a JSON file describing MCP servers
  as stdio subprocesses. We use netcat (`nc`) to bridge Claude Code's stdio to
  Symphony's TCP MCP server. Falls back to a bash `/dev/tcp` approach if `nc`
  is not available.
  """

  @config_file ".symphony_mcp_config.json"

  @spec write(Path.t(), :inet.port_number()) :: {:ok, Path.t()} | {:error, term()}
  def write(workspace, port) when is_binary(workspace) and is_integer(port) do
    config_path = config_file_path(workspace)
    content = build_config(port)

    case File.write(config_path, Jason.encode!(content, pretty: true)) do
      :ok -> {:ok, config_path}
      {:error, reason} -> {:error, {:mcp_config_write_failed, reason}}
    end
  end

  @spec config_file_path(Path.t()) :: Path.t()
  def config_file_path(workspace) do
    Path.join(Path.expand(workspace), @config_file)
  end

  defp build_config(port) do
    server_command = find_bridge_command(port)

    %{
      "mcpServers" => %{
        "symphony" => server_command
      }
    }
  end

  defp find_bridge_command(port) do
    cond do
      nc_available?() ->
        # netcat: connect stdin/stdout to TCP socket
        %{
          "command" => "nc",
          "args" => ["-q", "1", "127.0.0.1", to_string(port)]
        }

      bash_available?() ->
        # bash /dev/tcp trick as fallback
        %{
          "command" => "bash",
          "args" => ["-c", "exec 3<>/dev/tcp/127.0.0.1/#{port}; cat <&3 & cat >&3; wait"]
        }

      true ->
        # Last resort: use sh with a heredoc-style approach
        # This may not work on all systems but avoids hard failure
        %{
          "command" => "sh",
          "args" => ["-c", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/#{port}; cat <&3 & cat >&3; wait'"]
        }
    end
  end

  defp nc_available? do
    not is_nil(System.find_executable("nc"))
  end

  defp bash_available? do
    not is_nil(System.find_executable("bash"))
  end
end
