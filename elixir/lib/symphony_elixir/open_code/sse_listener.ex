defmodule SymphonyElixir.OpenCode.SseListener do
  @moduledoc """
  Consumes the OpenCode SSE event stream and forwards parsed events to a parent process.

  Connects to `GET /event/subscribe` via `Req.get(into: :self)` and parses the
  SSE text protocol, emitting `{:sse_event, type, parsed}` messages to the owner.
  """

  require Logger

  @doc "Start a listener process (unlinked) that sends events to the owner."
  @spec start(String.t(), pid()) :: {:ok, pid()}
  def start(base_url, owner_pid) do
    pid =
      spawn(fn ->
        connect(base_url, owner_pid)
      end)

    {:ok, pid}
  end

  @doc "Stop a listener process."
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    :ok
  end

  defp connect(base_url, owner_pid) do
    url = "#{base_url}/event"
    Logger.debug("SSE connecting to #{url}")

    case Req.get(url, into: :self, receive_timeout: :infinity) do
      {:ok, %Req.Response{status: status} = resp} when status in [200, 201] ->
        Logger.debug("SSE connected to #{url}")
        stream_loop(resp, owner_pid, "")

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("SSE connection got non-200 status=#{status} body=#{inspect(body, limit: 200)}")
        send(owner_pid, {:sse_event, "connection_error", %{error: {:http_status, status}}})

      {:error, reason} ->
        Logger.warning("SSE connection failed: #{inspect(reason)}")
        send(owner_pid, {:sse_event, "connection_error", %{error: reason}})
    end
  end

  defp stream_loop(resp, owner_pid, buffer) do
    ref = resp.body.ref

    receive do
      {^ref, {:data, chunk}} ->
        new_buffer = buffer <> chunk
        {events, remaining} = extract_events(new_buffer)

        Enum.each(events, fn event ->
          case parse_sse_event(event) do
            {:ok, type, data} ->
              send(owner_pid, {:sse_event, type, data})

            :skip ->
              :ok
          end
        end)

        stream_loop(resp, owner_pid, remaining)

      {^ref, :done} ->
        Logger.debug("SSE stream closed")
        :ok

      {^ref, {:error, reason}} ->
        Logger.warning("SSE stream error: #{inspect(reason)}")
        send(owner_pid, {:sse_event, "stream_error", %{error: reason}})
    end
  end

  # Split buffer on double-newline boundaries into complete events
  defp extract_events(buffer) do
    case String.split(buffer, "\n\n", parts: :infinity) do
      [] ->
        {[], ""}

      parts ->
        # Last part is incomplete (no trailing \n\n) — keep as buffer
        {complete, [remaining]} = Enum.split(parts, -1)
        events = Enum.reject(complete, &(&1 == ""))
        {events, remaining}
    end
  end

  # Parse SSE text block into {type, data}
  defp parse_sse_event(block) do
    lines = String.split(block, "\n")

    {event_type, data_lines} =
      Enum.reduce(lines, {nil, []}, fn line, {type, data} ->
        cond do
          String.starts_with?(line, "event: ") ->
            {String.trim_leading(line, "event: "), data}

          String.starts_with?(line, "data: ") ->
            {type, [String.trim_leading(line, "data: ") | data]}

          String.starts_with?(line, ":") ->
            # SSE comment, ignore
            {type, data}

          true ->
            {type, data}
        end
      end)

    case {event_type, data_lines} do
      {nil, []} ->
        :skip

      {type, data} ->
        joined = data |> Enum.reverse() |> Enum.join("\n")
        parsed = try_decode_json(joined)
        # OpenCode embeds the event type in the JSON "type" field, not SSE event: lines
        effective_type = type || Map.get(parsed, "type", "message")
        {:ok, effective_type, Map.get(parsed, "properties", parsed)}
    end
  end

  defp try_decode_json(text) do
    case Jason.decode(text) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{"raw" => text}
    end
  end

  @doc """
  Normalize OpenCode token usage to Symphony format.

  OpenCode provides `input`, `output`, `reasoning`, `cache: {read, write}`.
  Symphony expects `input_tokens`, `output_tokens`, `total_tokens`.
  """
  @spec normalize_usage(map()) :: map()
  def normalize_usage(tokens) when is_map(tokens) do
    input = Map.get(tokens, "input", 0)
    output = Map.get(tokens, "output", 0)
    total = Map.get(tokens, "total", input + output)

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => total
    }
  end

  def normalize_usage(_), do: %{}
end
