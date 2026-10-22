defmodule Tymeslot.CalendarGrid.CreateParams do
  @moduledoc """
  The server's own check of an event the calendar asks to create, from
  the quick-create popover or the side panel's "New event" state.

  The hook parses what the organiser typed, but nothing it sends is trusted:
  `cast/4` checks every field again and answers `{:error, field, reason}`
  for the first that fails, so the web layer can name the reason beside that
  field. Times are the organiser's wall clock (`"2026-10-15T13:00"`, or
  dates with an exclusive end for an all-day event) and go through `Moves`,
  so a create obeys the span and year rules a drag does. Text is sanitised
  as plain text (null bytes go). An empty title is refused: the web layer
  gives an untitled draft its default name before casting.

  `to_payload/1` turns the result into what `Changes.create_event/2` writes.
  """

  alias Tymeslot.Auth
  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.Moves
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Recurrence.RRule
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Security.UniversalSanitizer

  @max_text %{title: 500, location: 1_000, description: 5_000}
  @max_guests 50
  @max_reminders 5
  # Four weeks.
  @max_reminder_minutes 40_320
  @max_rule 500
  @reminder_methods %{"popup" => :popup, "email" => :email}

  @enforce_keys [:integration_id, :calendar_id, :title, :start_at, :end_at, :timezone]
  defstruct [
    :integration_id,
    :calendar_id,
    :title,
    :start_at,
    :end_at,
    :timezone,
    all_day: false,
    location: nil,
    description: nil,
    guests: [],
    free: false,
    reminders: [],
    recurrence_rule: nil,
    video_integration_id: nil
  ]

  @type field ::
          :params
          | :title
          | :all_day
          | :start
          | :end
          | :calendar
          | :location
          | :description
          | :guests
          | :free
          | :reminders
          | :recurrence_rule
          | :video_integration_id

  @type t :: %__MODULE__{
          integration_id: pos_integer(),
          calendar_id: String.t(),
          title: String.t(),
          start_at: DateTime.t() | Date.t(),
          end_at: DateTime.t() | Date.t(),
          timezone: String.t(),
          all_day: boolean(),
          location: String.t() | nil,
          description: String.t() | nil,
          guests: [String.t()],
          free: boolean(),
          reminders: [%{method: :popup | :email, minutes_before: non_neg_integer()}],
          recurrence_rule: String.t() | nil,
          video_integration_id: pos_integer() | nil
        }

  @doc """
  Checks the string-keyed `params` a create was asked with, for `user_id`
  whose active calendar accounts are `integrations`, in the organiser's
  `timezone`.
  """
  @spec cast(pos_integer(), [map()], map(), String.t()) ::
          {:ok, t()} | {:error, field(), atom()}
  def cast(user_id, integrations, params, timezone) when is_map(params) do
    with {:ok, title} <- clean_text(:title, params["title"]),
         {:ok, all_day} <- flag(params["all_day"], :all_day),
         {:ok, start_at, end_at} <- timing(all_day, params["start"], params["end"], timezone),
         {:ok, integration, calendar_id} <- calendar(user_id, integrations, params["calendar"]),
         {:ok, details} <- details(user_id, integration, params) do
      {:ok,
       struct!(
         __MODULE__,
         Map.merge(details, %{
           integration_id: integration.id,
           calendar_id: calendar_id,
           title: title,
           start_at: start_at,
           end_at: end_at,
           timezone: timezone,
           all_day: all_day
         })
       )}
    end
  end

  def cast(_user_id, _integrations, _params, _timezone), do: {:error, :params, :invalid}

  @doc "The payload `Changes.create_event/2` writes for `params`."
  @spec to_payload(t()) :: map()
  def to_payload(%__MODULE__{} = params) do
    %{
      creating: %{
        title: params.title,
        integration_id: params.integration_id,
        calendar_id: params.calendar_id,
        all_day: params.all_day,
        location: params.location,
        description: params.description,
        attendees: params.guests,
        reminders: params.reminders,
        recurrence_rule: params.recurrence_rule,
        video_integration_id: params.video_integration_id,
        transparency: if(params.free, do: "transparent", else: "opaque")
      },
      start_at: params.start_at,
      end_at: params.end_at,
      timezone: params.timezone
    }
  end

  # The optional fields, as the struct's keys.
  defp details(user_id, integration, params) do
    with {:ok, location} <- clean_text(:location, params["location"]),
         {:ok, description} <- clean_text(:description, params["description"]),
         {:ok, guests} <- guests(user_id, params["guests"]),
         {:ok, free} <- flag(params["free"], :free),
         {:ok, reminders} <- reminders(params["reminders"]),
         {:ok, rule} <- recurrence(params["recurrence_rule"], integration),
         {:ok, video_id} <- video(user_id, params["video_integration_id"]) do
      {:ok,
       %{
         location: blank_to_nil(location),
         description: blank_to_nil(description),
         guests: guests,
         free: free,
         reminders: reminders,
         recurrence_rule: rule,
         video_integration_id: video_id
       }}
    end
  end

  # --- text ---

  @doc """
  The text rule every create and panel edit shares: `value` for `field`
  (`:title`, `:location` or `:description`) is trimmed, sanitised and held to
  the field's limit, and a title must not be blank. `nil` is no text (a
  blank title for `:title`). The panel's text fields use it, so a field
  refuses what a create would.
  """
  @spec clean_text(:title | :location | :description, term()) ::
          {:ok, String.t() | nil} | {:error, field(), :blank | :too_long | :invalid}
  def clean_text(:title, value) do
    with {:ok, title} <- text(value, :title, @max_text.title),
         :ok <- present(title),
         do: {:ok, title}
  end

  def clean_text(field, value) when field in [:location, :description],
    do: text(value, field, Map.fetch!(@max_text, field))

  defp text(nil, _field, _max), do: {:ok, nil}

  defp text(value, field, max) when is_binary(value) do
    trimmed = String.trim(value)

    case UniversalSanitizer.sanitize_and_validate(trimmed, mode: :plain_text, max_length: max) do
      {:ok, sanitised} ->
        {:ok, sanitised}

      # The sanitiser's reason is translated text, so the cases are told apart
      # by the input itself.
      {:error, _reason} ->
        if String.valid?(trimmed) and String.length(trimmed) > max,
          do: {:error, field, :too_long},
          else: {:error, field, :invalid}
    end
  end

  defp text(_value, field, _max), do: {:error, field, :invalid}

  defp present(title) when is_binary(title) and title != "", do: :ok
  defp present(_blank), do: {:error, :title, :blank}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp flag(nil, _field), do: {:ok, false}
  defp flag(value, _field) when is_boolean(value), do: {:ok, value}
  defp flag(_value, field), do: {:error, field, :invalid}

  # --- timing ---

  defp timing(false, start, finish, timezone) do
    with {:ok, start_at} <- wall(start, timezone, :start),
         {:ok, end_at} <- wall(finish, timezone, :end),
         :ok <- within_years(start_at.year),
         span = DateTime.diff(end_at, start_at),
         :ok <- ordered(span),
         :ok <- at_most(span, Moves.max_span_seconds(), :longer_than_a_week) do
      {:ok, start_at, end_at}
    end
  end

  defp timing(true, start, finish, _timezone) do
    with {:ok, first} <- date(start, :start),
         {:ok, after_last} <- date(finish, :end),
         :ok <- within_years(first.year),
         :ok <- ordered(Date.diff(after_last, first)),
         :ok <- all_day_span(first, after_last) do
      {:ok, first, after_last}
    end
  end

  # `Moves` answers at microsecond precision; a create's instants are whole
  # minutes, so they are kept to the second.
  defp wall(text, timezone, field) when is_binary(text) do
    case Moves.wall_to_utc(text, timezone) do
      {:ok, at} -> {:ok, DateTime.truncate(at, :second)}
      :error -> {:error, field, :invalid}
    end
  end

  defp wall(_text, _timezone, field), do: {:error, field, :invalid}

  defp date(text, field) when is_binary(text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, field, :invalid}
    end
  end

  defp date(_text, field), do: {:error, field, :invalid}

  defp within_years(year) do
    if year in Moves.years(), do: :ok, else: {:error, :start, :out_of_range}
  end

  defp ordered(span) when span > 0, do: :ok
  defp ordered(_span), do: {:error, :end, :before_start}

  # A timed event is held to `Moves.max_span_seconds/0` (one drawable block);
  # an all-day one may run for a year (a holiday, a term).
  defp all_day_span(first, after_last) do
    if Moves.sensible_days?(first, after_last), do: :ok, else: {:error, :end, :longer_than_a_year}
  end

  defp at_most(span, max, _reason) when span <= max, do: :ok
  defp at_most(_span, _max, reason), do: {:error, :end, reason}

  # --- calendar ---

  # `integrations` are the organiser's active accounts as the surface loaded
  # them; the owner is checked again so a list from anywhere else cannot
  # widen what a create may target.
  defp calendar(user_id, integrations, key) do
    with {:ok, integration_id, calendar_id} <- parse_key(key),
         {:ok, integration} <- own(integrations, user_id, integration_id),
         :ok <- writable(integration, calendar_id) do
      {:ok, integration, calendar_id}
    end
  end

  defp parse_key(key) do
    case CalendarDirectory.parse_key(key) do
      {:ok, integration_id, calendar_id} -> {:ok, integration_id, calendar_id}
      :error -> {:error, :calendar, :invalid}
    end
  end

  defp own(integrations, user_id, integration_id) do
    case Enum.find(integrations, &(&1.id == integration_id and &1.user_id == user_id)) do
      nil -> {:error, :calendar, :not_found}
      integration -> {:ok, integration}
    end
  end

  defp writable(integration, calendar_id) do
    cond do
      Enum.any?(CalendarDirectory.writable_calendars(integration), &(&1.id == calendar_id)) ->
        :ok

      Enum.any?(CalendarDirectory.synced_entries(integration), &(&1.id == calendar_id)) ->
        {:error, :calendar, :read_only}

      true ->
        {:error, :calendar, :not_found}
    end
  end

  # --- guests ---

  @doc "The most guests an event can have."
  @spec max_guests() :: pos_integer()
  def max_guests, do: @max_guests

  @doc """
  Checks a list of guest addresses for `user_id`, as a create checks its
  own: each is trimmed and lower-cased, every one must be a valid email,
  duplicates collapse, the organiser's own address is dropped, and at most
  `max_guests/0` remain. The side panel uses it for the guests it invites.
  """
  @spec guests(pos_integer(), [term()] | nil) :: {:ok, [String.t()]} | {:error, :guests, atom()}
  def guests(_user_id, nil), do: {:ok, []}

  # A list far past the limit is refused before any address is looked at.
  def guests(_user_id, emails) when is_list(emails) and length(emails) > 4 * @max_guests,
    do: {:error, :guests, :too_many}

  def guests(user_id, emails) when is_list(emails) do
    addresses = Enum.map(emails, &normalise_email/1)

    if Enum.all?(addresses, &Guests.valid_email?/1) do
      addresses = addresses |> Enum.uniq() |> without_own(user_id)

      if length(addresses) > @max_guests,
        do: {:error, :guests, :too_many},
        else: {:ok, addresses}
    else
      {:error, :guests, :invalid_email}
    end
  end

  def guests(_user_id, _emails), do: {:error, :guests, :invalid}

  defp normalise_email(email) when is_binary(email),
    do: email |> String.trim() |> String.downcase()

  defp normalise_email(_email), do: nil

  # Inviting oneself would only email the organiser an invitation to their
  # own event, so their address is dropped rather than refused.
  defp without_own([], _user_id), do: []

  defp without_own(addresses, user_id) do
    case Auth.get_user(user_id) do
      {:ok, %{email: email}} when is_binary(email) ->
        List.delete(addresses, normalise_email(email))

      _unknown ->
        addresses
    end
  end

  # --- the panel's fields ---

  defp reminders(nil), do: {:ok, []}

  defp reminders(list) when is_list(list) and length(list) > @max_reminders,
    do: {:error, :reminders, :too_many}

  defp reminders(list) when is_list(list) do
    parsed = Enum.map(list, &reminder/1)

    if Enum.all?(parsed, &is_map/1),
      do: {:ok, Enum.uniq(parsed)},
      else: {:error, :reminders, :invalid}
  end

  defp reminders(_list), do: {:error, :reminders, :invalid}

  defp reminder(%{"method" => method, "minutes" => minutes})
       when is_map_key(@reminder_methods, method) and is_integer(minutes) and minutes >= 0 and
              minutes <= @max_reminder_minutes,
       do: %{method: Map.fetch!(@reminder_methods, method), minutes_before: minutes}

  defp reminder(_invalid), do: :error

  defp recurrence(rule, _integration) when rule in [nil, ""], do: {:ok, nil}

  defp recurrence(rule, integration) when is_binary(rule) and byte_size(rule) <= @max_rule do
    with {:ok, parsed} <- RRule.parse(rule),
         true <- ProviderConfig.writes_repeat_rules?(integration.provider) do
      {:ok, RRule.format(parsed)}
    else
      false -> {:error, :recurrence_rule, :not_repeatable}
      :error -> {:error, :recurrence_rule, :invalid}
    end
  end

  defp recurrence(_rule, _integration), do: {:error, :recurrence_rule, :invalid}

  # The id must name one of the organiser's own live video integrations: an
  # unknown one would fail the cache's foreign key after the provider event
  # was written, and another organiser's must not be stored on this one's row.
  defp video(_user_id, nil), do: {:ok, nil}

  defp video(user_id, id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> video(user_id, parsed)
      _invalid -> {:error, :video_integration_id, :invalid}
    end
  end

  defp video(user_id, id) when is_integer(id) and id > 0 do
    case Video.fetch_live_integration_for_user(id, user_id) do
      {:ok, _integration} -> {:ok, id}
      {:error, :not_found} -> {:error, :video_integration_id, :not_found}
    end
  end

  defp video(_user_id, _id), do: {:error, :video_integration_id, :invalid}
end
