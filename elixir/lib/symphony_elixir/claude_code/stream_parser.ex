defmodule SymphonyElixir.ClaudeCode.StreamParser do
  @moduledoc """
  Parses Claude Code's `--output-format stream-json` NDJSON event stream.

  Maps Claude Code stream events to the event vocabulary used by `AppServer`'s
  `on_message` callbacks, allowing `AgentRunner` to work unchanged.
  """

  @type parse_result ::
          {:terminal, :turn_completed | :turn_failed | :turn_ended_with_error, map()}
          | {:continue, atom(), map()}

  @doc """
  Parse a single NDJSON line from Claude Code's stream output.

  Returns `{:terminal, event, details}` when the turn is complete,
  or `{:continue, event, details}` for non-terminal stream events.
  """
  @spec parse_line(String.t()) :: parse_result()
  def parse_line(line) when is_binary(line) do
    payload = String.trim(line)

    case Jason.decode(payload) do
      {:ok, event} -> parse_event(event, payload)
      {:error, _} -> {:continue, :malformed, %{payload: payload, raw: payload}}
    end
  end

  defp parse_event(%{"type" => "message_stop"} = event, payload) do
    {:terminal, :turn_completed, %{payload: event, raw: payload, details: %{reason: :message_stop}}}
  end

  defp parse_event(%{"type" => "result", "subtype" => "success"} = event, payload) do
    usage = normalize_usage(Map.get(event, "usage"))
    {:terminal, :turn_completed, %{payload: event, raw: payload, usage: usage, details: Map.get(event, "result")}}
  end

  defp parse_event(%{"type" => "result", "subtype" => subtype} = event, payload)
       when subtype in ["error_max_turns", "error"] do
    {:terminal, :turn_failed, %{payload: event, raw: payload, details: %{subtype: subtype}}}
  end

  defp parse_event(%{"type" => "error", "error" => error} = event, payload) do
    {:terminal, :turn_failed, %{payload: event, raw: payload, details: %{reason: error}}}
  end

  defp parse_event(%{"type" => "message_start", "message" => %{"usage" => usage}} = event, payload) do
    {:continue, :notification, %{payload: event, raw: payload, usage: normalize_usage(usage)}}
  end

  defp parse_event(%{"type" => "message_delta", "usage" => usage} = event, payload) do
    {:continue, :notification, %{payload: event, raw: payload, usage: normalize_usage(usage)}}
  end

  defp parse_event(%{"type" => "assistant", "message" => %{"usage" => usage}} = event, payload) do
    {:continue, :notification, %{payload: event, raw: payload, usage: normalize_usage(usage)}}
  end

  defp parse_event(%{"type" => "rate_limit_event"} = event, payload) do
    {:continue, :notification, %{payload: event, raw: payload}}
  end

  @notification_types ~w(message_start content_block_start content_block_delta content_block_stop tool_use assistant system user)

  defp parse_event(%{"type" => type} = event, payload) when type in @notification_types do
    {:continue, :notification, %{payload: event, raw: payload}}
  end

  defp parse_event(event, payload) do
    {:continue, :other_message, %{payload: event, raw: payload}}
  end

  @doc """
  Determine the event for a port exit based on exit status and whether a
  terminal event was already received.
  """
  @spec parse_exit(non_neg_integer(), boolean()) :: parse_result()
  def parse_exit(0, false) do
    {:terminal, :turn_completed, %{details: %{reason: :process_exit_success}}}
  end

  def parse_exit(0, true) do
    {:terminal, :turn_completed, %{details: %{reason: :already_completed}}}
  end

  def parse_exit(status, _already_completed) do
    {:terminal, :turn_ended_with_error, %{details: %{exit_status: status}}}
  end

  # Normalize usage map to ensure both input/output token keys exist for
  # compatibility with orchestrator's extract_token_usage/1 which checks both
  # string and atom key variants.
  defp normalize_usage(%{"input_tokens" => _} = usage), do: usage
  defp normalize_usage(%{"output_tokens" => _} = usage), do: usage
  defp normalize_usage(usage) when is_map(usage), do: usage
  defp normalize_usage(_), do: %{}
end
