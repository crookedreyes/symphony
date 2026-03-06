defmodule SymphonyElixir.OpenCode.Client do
  @moduledoc """
  Req-based HTTP client for the OpenCode `opencode serve` REST API.

  All functions are stateless — pass `base_url` (e.g. "http://127.0.0.1:PORT")
  as the first argument.
  """

  alias SymphonyElixir.Config

  @doc "Check server health."
  @spec health(String.t()) :: {:ok, map()} | {:error, term()}
  def health(base_url) do
    case Req.get("#{base_url}/global/health", receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:health_check_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Create a new session."
  @spec create_session(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_session(base_url, title) do
    case Req.post("#{base_url}/session", json: %{title: title}) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 201] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:create_session_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Delete a session."
  @spec delete_session(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_session(base_url, session_id) do
    case Req.delete("#{base_url}/session/#{session_id}") do
      {:ok, %Req.Response{status: status}} when status in [200, 204] -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:delete_session_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Send a prompt to a session. Blocks until the turn completes.

  Returns the AssistantMessage with token usage.
  """
  @spec send_message(String.t(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def send_message(base_url, session_id, prompt, model_opts \\ %{}) do
    model = build_model_opts(model_opts)

    body =
      %{parts: [%{type: "text", text: prompt}]}
      |> maybe_put_model(model)

    timeout = Config.open_code_turn_timeout_ms()

    case Req.post("#{base_url}/session/#{session_id}/message",
           json: body,
           receive_timeout: timeout
         ) do
      {:ok, %Req.Response{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:error, {:message_failed, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_model(body, model) when model == %{}, do: body
  defp maybe_put_model(body, model), do: Map.put(body, :model, model)

  @doc "Abort a running prompt."
  @spec abort(String.t(), String.t()) :: :ok | {:error, term()}
  def abort(base_url, session_id) do
    case Req.post("#{base_url}/session/#{session_id}/abort") do
      {:ok, %Req.Response{status: status}} when status in [200, 204] -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:abort_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Split "lmstudio/qwen/qwen3-30b" into providerID + modelID.
  # providerID is the first segment; modelID is the rest (may contain "/").
  # If no "/" prefix, return empty — let opencode.json config handle it.
  defp build_model_opts(%{model: model}) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, model_id] when model_id != "" -> %{providerID: provider, modelID: model_id}
      _ -> %{}
    end
  end

  defp build_model_opts(_), do: %{}
end
