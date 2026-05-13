defmodule Tymeslot.Slack.InputValidation do
  @moduledoc """
  Input validation for Slack integration form fields. Used by
  `SlackFormComponent` and the LiveView event handlers to validate user input
  before it reaches the database or the Slack API.
  """

  alias Tymeslot.Security.UniversalSanitizer
  alias Tymeslot.Slack.SlackIntegrationSchema

  @webhook_url_regex ~r{\Ahttps://hooks\.slack\.com/services/T[A-Z0-9]+/B[A-Z0-9]+/[A-Za-z0-9]+\z}

  @doc """
  Validates a Slack integration form. The `:mode` option selects which fields
  are required:

    * `:webhook_url` — name, `webhook_url`, events
    * `:oauth_pending` — `channel_id`, events
    * `:oauth_existing` — name, `channel_id`, events
  """
  @spec validate_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_form(params, opts \\ []) do
    mode = Keyword.get(opts, :mode, :webhook_url)
    errors = %{}

    {name, errors} = validate_name(params["name"], errors, name_required?(mode))
    {events, errors} = validate_events(params["events"], errors)

    {extra, errors} =
      case mode do
        :webhook_url ->
          {webhook_url, errors} = validate_webhook_url(params["webhook_url"], errors)
          {channel_hint, errors} = validate_channel_hint(params["webhook_channel_hint"], errors)
          {%{webhook_url: webhook_url, webhook_channel_hint: channel_hint}, errors}

        oauth when oauth in [:oauth_pending, :oauth_existing] ->
          {channel_id, errors} = validate_channel_id(params["channel_id"], errors)
          {channel_name, errors} = validate_channel_name(params["channel_name"], errors)
          {%{channel_id: channel_id, channel_name: channel_name}, errors}
      end

    if map_size(errors) == 0 do
      sanitized =
        %{events: events}
        |> maybe_put(:name, name)
        |> Map.merge(drop_nils(extra))

      {:ok, sanitized}
    else
      {:error, errors}
    end
  end

  defp name_required?(:oauth_pending), do: false
  defp name_required?(_mode), do: true

  @spec validate_name(String.t() | nil, map(), boolean()) :: {String.t() | nil, map()}
  def validate_name(nil, errors, false), do: {nil, errors}
  def validate_name("", errors, false), do: {nil, errors}
  def validate_name(nil, errors, true), do: {nil, Map.put(errors, :name, "is required")}
  def validate_name("", errors, true), do: {nil, Map.put(errors, :name, "is required")}

  def validate_name(name, errors, _required) when is_binary(name) do
    case UniversalSanitizer.sanitize_and_validate(name, max_length: 80) do
      {:ok, sanitized} ->
        if String.length(sanitized) < 1 do
          {nil, Map.put(errors, :name, "is required")}
        else
          {sanitized, errors}
        end

      {:error, _error} ->
        {nil, Map.put(errors, :name, "is invalid")}
    end
  end

  @spec validate_events([String.t()] | nil, map()) :: {[String.t()] | nil, map()}
  def validate_events(nil, errors),
    do: {nil, Map.put(errors, :events, "select at least one event")}

  def validate_events([], errors),
    do: {nil, Map.put(errors, :events, "select at least one event")}

  def validate_events(events, errors) when is_list(events) do
    valid = SlackIntegrationSchema.valid_events()
    invalid = Enum.reject(events, &(&1 in valid))

    if Enum.empty?(invalid) do
      {events, errors}
    else
      {nil, Map.put(errors, :events, "contains invalid events")}
    end
  end

  @spec validate_webhook_url(String.t() | nil, map()) :: {String.t() | nil, map()}
  def validate_webhook_url(nil, errors),
    do: {nil, Map.put(errors, :webhook_url, "is required")}

  def validate_webhook_url("", errors),
    do: {nil, Map.put(errors, :webhook_url, "is required")}

  def validate_webhook_url(url, errors) when is_binary(url) do
    trimmed = String.trim(url)

    if Regex.match?(@webhook_url_regex, trimmed) do
      {trimmed, errors}
    else
      {nil, Map.put(errors, :webhook_url, "must look like https://hooks.slack.com/services/...")}
    end
  end

  @spec validate_channel_hint(String.t() | nil, map()) :: {String.t() | nil, map()}
  def validate_channel_hint(nil, errors), do: {nil, errors}
  def validate_channel_hint("", errors), do: {nil, errors}

  def validate_channel_hint(hint, errors) when is_binary(hint) do
    case UniversalSanitizer.sanitize_and_validate(hint, max_length: 80) do
      {:ok, sanitized} -> {sanitized, errors}
      {:error, _err} -> {nil, Map.put(errors, :webhook_channel_hint, "is invalid")}
    end
  end

  @spec validate_channel_id(String.t() | nil, map()) :: {String.t() | nil, map()}
  def validate_channel_id(nil, errors),
    do: {nil, Map.put(errors, :channel_id, "pick a channel")}

  def validate_channel_id("", errors),
    do: {nil, Map.put(errors, :channel_id, "pick a channel")}

  def validate_channel_id(id, errors) when is_binary(id), do: {String.trim(id), errors}

  @spec validate_channel_name(String.t() | nil, map()) :: {String.t() | nil, map()}
  def validate_channel_name(nil, errors), do: {nil, errors}
  def validate_channel_name("", errors), do: {nil, errors}

  def validate_channel_name(name, errors) when is_binary(name) do
    {String.trim_leading(String.trim(name), "#"), errors}
  end

  defp drop_nils(map), do: Enum.reject(map, fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
