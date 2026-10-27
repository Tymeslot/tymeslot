defmodule Tymeslot.Telegram.InputValidation do
  @moduledoc """
  Input validation for Telegram integration fields.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Security.UniversalSanitizer
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Validation.Constraints

  @bot_token_regex ~r/^\d{8,10}:[A-Za-z0-9_-]{35,50}$/
  @chat_id_numeric_regex ~r/^-?\d+$/
  @chat_id_username_regex ~r/^@[a-zA-Z][a-zA-Z0-9_]{4,31}$/

  @doc """
  Validates the integration form. `:bot_mode` selects the fields: on the own
  bot the organiser supplies the bot token and chat id; on the shared bot the
  chat is linked only through the bot's deep link, so any `chat_id` param is
  dropped. The bot mode itself is never part of the result: the context sets
  it on create and an edit never changes it.
  """
  @spec validate_form(map(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_form(params, opts) do
    bot_mode = Keyword.get(opts, :bot_mode, "own")
    mode = Keyword.get(opts, :mode, :create)
    errors = %{}

    {name, errors} = validate_name(params["name"], errors, Keyword.get(opts, :stored_name))
    {events, errors} = validate_events(params["events"], errors)

    {bot_token, chat_id, errors} =
      if bot_mode == "own" do
        validate_fn =
          if mode == :edit, do: &validate_bot_token_optional/2, else: &validate_bot_token/2

        {token, errors} = validate_fn.(params["bot_token"], errors)
        {cid, errors} = validate_chat_id(params["chat_id"], errors)
        {token, cid, errors}
      else
        {nil, nil, errors}
      end

    if map_size(errors) == 0 do
      sanitized =
        %{name: name, events: events}
        |> maybe_put(:bot_token, bot_token)
        |> maybe_put(:chat_id, chat_id)

      {:ok, sanitized}
    else
      {:error, errors}
    end
  end

  @spec validate_bot_token_optional(String.t() | nil, map()) :: {String.t() | nil, map()}
  defp validate_bot_token_optional(nil, errors), do: {nil, errors}
  defp validate_bot_token_optional("", errors), do: {nil, errors}
  defp validate_bot_token_optional(token, errors), do: validate_bot_token(token, errors)

  @spec validate_bot_token(String.t() | nil, map()) :: {String.t() | nil, map()}
  def validate_bot_token(nil, errors),
    do: {nil, Map.put(errors, :bot_token, dgettext("errors", "is required"))}

  def validate_bot_token("", errors),
    do: {nil, Map.put(errors, :bot_token, dgettext("errors", "is required"))}

  def validate_bot_token(token, errors) when is_binary(token) do
    cleaned = strip_bot_api_url(String.trim(token))

    if Regex.match?(@bot_token_regex, cleaned) do
      {cleaned, errors}
    else
      {nil,
       Map.put(
         errors,
         :bot_token,
         dgettext("errors", "invalid format (expected: 123456789:ABCdef...)")
       )}
    end
  end

  @spec validate_chat_id(String.t() | nil, map()) :: {String.t() | nil, map()}
  def validate_chat_id(nil, errors),
    do: {nil, Map.put(errors, :chat_id, dgettext("errors", "is required"))}

  def validate_chat_id("", errors),
    do: {nil, Map.put(errors, :chat_id, dgettext("errors", "is required"))}

  def validate_chat_id(chat_id, errors) when is_binary(chat_id) do
    trimmed = String.trim(chat_id)

    if Regex.match?(@chat_id_numeric_regex, trimmed) or
         Regex.match?(@chat_id_username_regex, trimmed) do
      {trimmed, errors}
    else
      {nil, Map.put(errors, :chat_id, dgettext("errors", "must be a numeric ID or @username"))}
    end
  end

  @doc """
  Validates the name. `stored_name` is the integration's current name on
  edit (see `Constraints.integration_name_max_length/2`).
  """
  @spec validate_name(String.t() | nil, map(), String.t() | nil) :: {String.t() | nil, map()}
  def validate_name(name, errors, stored_name \\ nil)

  def validate_name(nil, errors, _stored_name),
    do: {nil, Map.put(errors, :name, dgettext("errors", "is required"))}

  def validate_name("", errors, _stored_name),
    do: {nil, Map.put(errors, :name, dgettext("errors", "is required"))}

  def validate_name(name, errors, stored_name) when is_binary(name) do
    case UniversalSanitizer.sanitize_and_validate(name,
           mode: :plain_text,
           max_length: Constraints.integration_name_max_length(name, stored_name)
         ) do
      {:ok, sanitized} ->
        if String.length(sanitized) < 1 do
          {nil, Map.put(errors, :name, dgettext("errors", "is required"))}
        else
          {sanitized, errors}
        end

      {:error, _error} ->
        {nil, Map.put(errors, :name, dgettext("errors", "is invalid"))}
    end
  end

  @spec validate_events([String.t()] | nil, map()) :: {[String.t()] | nil, map()}
  def validate_events(nil, errors),
    do: {nil, Map.put(errors, :events, dgettext("errors", "select at least one event"))}

  def validate_events([], errors),
    do: {nil, Map.put(errors, :events, dgettext("errors", "select at least one event"))}

  def validate_events(events, errors) when is_list(events) do
    valid = TelegramIntegrationSchema.valid_events()
    invalid = Enum.reject(events, &(&1 in valid))

    if Enum.empty?(invalid) do
      {events, errors}
    else
      {nil, Map.put(errors, :events, dgettext("errors", "contains invalid events"))}
    end
  end

  defp strip_bot_api_url(token) do
    token
    |> String.replace(~r{^https?://api\.telegram\.org/bot}, "")
    |> String.trim_trailing("/")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
