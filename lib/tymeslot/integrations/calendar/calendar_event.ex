defmodule Tymeslot.Integrations.Calendar.CalendarEvent do
  @moduledoc """
  Canonical representation of a calendar event from any external provider.

  Every event in the cache is an instance of this struct. Providers produce
  these via `new/1` or `new!/1` during normalisation — validation happens at
  construction time so downstream code can trust the shape.
  """

  @type t :: %__MODULE__{
          uid: String.t(),
          calendar_integration_id: integer(),
          provider: :google | :outlook | :caldav | :ics_url | :exchange | :debug,
          provider_calendar_id: String.t(),
          provider_event_id: String.t() | nil,
          recurring_event_id: String.t() | nil,
          summary: String.t() | nil,
          description: String.t() | nil,
          location: String.t() | nil,
          visibility: :public | :private | :confidential | nil,
          colour: String.t() | nil,
          all_day: boolean(),
          start_date: Date.t() | nil,
          end_date: Date.t() | nil,
          start_at: DateTime.t() | nil,
          end_at: DateTime.t() | nil,
          timezone: String.t() | nil,
          transparency: :transparent | :opaque,
          status: :confirmed | :tentative | :cancelled | :declined,
          organiser: map() | nil,
          attendees: [map()],
          recurrence_rule: String.t() | nil,
          recurrence_exceptions: [Date.t()],
          recurrence_id: String.t() | nil,
          recurrence_id_range: :this_and_future | nil,
          attachments: [map()],
          links: [map()],
          reminders: [map()],
          etag: String.t() | nil,
          synced_at: DateTime.t(),
          provider_updated_at: DateTime.t() | nil,
          provider_metadata: map(),
          raw_ical: String.t() | nil,
          created_by_tymeslot: boolean()
        }

  @enforce_keys [
    :uid,
    :calendar_integration_id,
    :provider,
    :provider_calendar_id,
    :all_day,
    :synced_at
  ]

  defstruct [
    :uid,
    :calendar_integration_id,
    :provider,
    :provider_calendar_id,
    :provider_event_id,
    :recurring_event_id,
    :summary,
    :description,
    :location,
    :visibility,
    :colour,
    :all_day,
    :start_date,
    :end_date,
    :start_at,
    :end_at,
    :timezone,
    :organiser,
    :recurrence_rule,
    :recurrence_id,
    :recurrence_id_range,
    :etag,
    :synced_at,
    :provider_updated_at,
    :raw_ical,
    transparency: :opaque,
    status: :confirmed,
    attendees: [],
    recurrence_exceptions: [],
    attachments: [],
    links: [],
    reminders: [],
    provider_metadata: %{},
    created_by_tymeslot: false
  ]

  @spec new(map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) do
    with :ok <- validate_uid(attrs),
         :ok <- validate_required(attrs),
         :ok <- validate_provider_event_id(attrs),
         :ok <- validate_timing(attrs) do
      {:ok, struct!(__MODULE__, apply_defaults(attrs))}
    end
  end

  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, "invalid CalendarEvent: #{reason}"
    end
  end

  @doc """
  Returns `true` if this event blocks availability.

  An event blocks when it is opaque (not free/transparent) and has not been
  cancelled or declined.
  """
  @spec blocking?(t() | map()) :: boolean()
  def blocking?(%__MODULE__{status: status}) when status in [:cancelled, :declined], do: false
  def blocking?(%__MODULE__{transparency: :transparent}), do: false
  def blocking?(%__MODULE__{}), do: true
  # Plain maps from the OAuth fresh-fetch path (convert_events) carry string-valued fields.
  def blocking?(%{status: status}) when status in ["cancelled", "declined"], do: false
  def blocking?(%{transparency: "transparent"}), do: false
  def blocking?(%{}), do: true

  # --- Validation helpers ---

  defp validate_uid(%{uid: uid}) when is_binary(uid) and byte_size(uid) > 0, do: :ok
  defp validate_uid(%{uid: _uid}), do: {:error, "uid must be a non-empty string"}
  defp validate_uid(_attrs), do: {:error, "uid is required"}

  @required_fields [:calendar_integration_id, :provider, :provider_calendar_id, :synced_at]

  defp validate_required(attrs) do
    missing = Enum.filter(@required_fields, &(not Map.has_key?(attrs, &1)))

    case missing do
      [] -> :ok
      keys -> {:error, "missing required fields: #{inspect(keys)}"}
    end
  end

  defp validate_provider_event_id(%{provider: provider} = attrs)
       when provider in [:google, :outlook] do
    id = Map.get(attrs, :provider_event_id)

    if is_binary(id) and byte_size(id) > 0 do
      :ok
    else
      {:error, "provider_event_id is required for #{provider} events"}
    end
  end

  defp validate_provider_event_id(_attrs), do: :ok

  # The timing fields are asserted by struct type, not merely by presence. The
  # storage columns are typed (`:date` for the all-day pair, `:utc_datetime_usec`
  # for the timed pair), so a `%DateTime{}` sitting in `end_date` (which an iCal
  # feed mixing `VALUE=DATE` and `DATE-TIME` in one VEVENT produces) is rejected
  # here rather than failing the whole batch insert further down. Each provider
  # already skips events this refuses, so one malformed event costs that event
  # instead of the entire calendar's sync.
  defp validate_timing(%{all_day: true, start_date: %Date{}, end_date: %Date{}} = attrs) do
    if attrs[:start_at] != nil or attrs[:end_at] != nil do
      {:error, "all-day events must not have start_at or end_at"}
    else
      :ok
    end
  end

  defp validate_timing(%{all_day: true}),
    do: {:error, "all-day events require Date values for start_date and end_date"}

  defp validate_timing(%{all_day: false, start_at: %DateTime{}, end_at: %DateTime{}} = attrs) do
    if attrs[:start_date] != nil or attrs[:end_date] != nil do
      {:error, "timed events must not have start_date or end_date"}
    else
      :ok
    end
  end

  defp validate_timing(%{all_day: false}),
    do: {:error, "timed events require DateTime values for start_at and end_at"}

  defp validate_timing(_attrs), do: {:error, "all_day is required"}

  defp apply_defaults(attrs) do
    attrs
    |> Map.put_new(:transparency, :opaque)
    |> Map.put_new(:status, :confirmed)
    |> Map.put_new(:attendees, [])
    |> Map.put_new(:recurrence_exceptions, [])
    |> Map.put_new(:attachments, [])
    |> Map.put_new(:links, [])
    |> Map.put_new(:reminders, [])
    |> Map.put_new(:provider_metadata, %{})
    |> Map.put_new(:created_by_tymeslot, false)
  end
end
