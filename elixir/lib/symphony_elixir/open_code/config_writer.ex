defmodule SymphonyElixir.OpenCode.ConfigWriter do
  @moduledoc """
  Writes `opencode.json` to the workspace root before `opencode serve` starts.

  Configures the model, MCP bridge to Symphony's TCP server, and permissions.
  Reuses the nc/bash bridge detection from `ClaudeCode.McpConfig`.
  """

  alias SymphonyElixir.ClaudeCode.McpServer
  alias SymphonyElixir.Config

  @config_file "opencode.json"

  @spec write(Path.t(), pid()) :: {:ok, Path.t()} | {:error, term()}
  def write(workspace, mcp_server_pid) when is_binary(workspace) and is_pid(mcp_server_pid) do
    with {:ok, mcp_port} <- McpServer.port(mcp_server_pid) do
      config_path = Path.join(Path.expand(workspace), @config_file)
      content = build_config(mcp_port)

      case File.write(config_path, Jason.encode!(content, pretty: true)) do
        :ok -> {:ok, config_path}
        {:error, reason} -> {:error, {:config_write_failed, reason}}
      end
    end
  end

  defp build_config(mcp_port) do
    bridge = bridge_command(mcp_port)

    config = %{
      "$schema" => "https://opencode.ai/config.json",
      "mcp" => %{
        "symphony" => Map.merge(bridge, %{"enabled" => true})
      },
      "permission" => %{
        "edit" => "allow",
        "bash" => %{"*" => "allow"}
      }
    }

    # Only set model if configured — opencode.json expects "provider/model" format
    case Config.open_code_model() do
      nil -> config
      model -> Map.put(config, "model", model)
    end
  end

  defp bridge_command(port) do
    cond do
      nc_available?() ->
        %{
          "type" => "local",
          "command" => ["nc", "-q", "1", "127.0.0.1", to_string(port)]
        }

      bash_available?() ->
        %{
          "type" => "local",
          "command" => [
            "bash",
            "-c",
            "exec 3<>/dev/tcp/127.0.0.1/#{port}; cat <&3 & cat >&3; wait"
          ]
        }

      true ->
        %{
          "type" => "local",
          "command" => [
            "sh",
            "-c",
            "bash -c 'exec 3<>/dev/tcp/127.0.0.1/#{port}; cat <&3 & cat >&3; wait'"
          ]
        }
    end
  end

  defp nc_available?, do: not is_nil(System.find_executable("nc"))
  defp bash_available?, do: not is_nil(System.find_executable("bash"))
end
