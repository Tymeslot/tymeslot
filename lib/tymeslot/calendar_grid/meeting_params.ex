defmodule Tymeslot.CalendarGrid.MeetingParams do
  @moduledoc """
  A Tymeslot meeting booked from the calendar's side panel ("Send as a
  Tymeslot meeting"): the event the organiser drafted, already checked by
  `CreateParams.cast/4`, plus the name of the guest the meeting is with,
  the language every email about it is written in, and the reminder emails
  it sends.

  `build/3` answers the params `EventCreation.run_create_ad_hoc_meeting/1`
  takes, or `{:error, field, reason}` for the first field that fails, as
  `CreateParams` does. The draft's first guest is the one the meeting is
  with; the others are invited as its guests, at most `Guests.max_guests/0`
  of them. The draft's notes become the note to the guests, held to the
  meeting's own limit. A meeting has a start and an end time, so an all-day
  draft is refused. Reminders are chosen from `reminder_choices/0`, never
  typed. `rate_limit/1` is the budget each meeting spends, since every one
  emails its guests.
  """

  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.UniversalSanitizer

  @max_name 255

  @reminders [
    {"30_minutes", %{value: 30, unit: "minutes"}},
    {"1_hours", %{value: 1, unit: "hours"}},
    {"1_days", %{value: 1, unit: "days"}}
  ]

  @type field :: :all_day | :guests | :guest_name | :locale | :note | :reminders

  @doc "The reminder emails a meeting can send, by the key the form sends."
  @spec reminder_choices() :: [String.t()]
  def reminder_choices, do: Enum.map(@reminders, &elem(&1, 0))

  @doc "How many people a meeting can be with: its guest and the guests it invites."
  @spec max_guests() :: pos_integer()
  # The guests a meeting invites, and the guest it is with. Read at run time
  # so this module does not compile against `Guests`.
  def max_guests, do: Guests.max_guests() + 1

  @doc """
  The meeting `create` describes, with the string-keyed `fields` the panel
  holds (`"guest_name"`, `"locale"`, `"reminders"`), for the organiser
  `user_id`.
  """
  @spec build(CreateParams.t(), map(), pos_integer()) ::
          {:ok, map()} | {:error, field(), atom()}
  def build(%CreateParams{all_day: true}, _fields, _user_id), do: {:error, :all_day, :timed_only}
  def build(%CreateParams{guests: []}, _fields, _user_id), do: {:error, :guests, :none}

  def build(%CreateParams{guests: [guest | others] = guests} = create, fields, user_id)
      when is_map(fields) do
    with :ok <- people(guests),
         {:ok, name} <- guest_name(fields["guest_name"]),
         {:ok, locale} <- locale(fields["locale"]),
         {:ok, note} <- note(create.description),
         {:ok, reminders} <- reminders(fields["reminders"]) do
      {:ok,
       %{
         title: create.title,
         start_time: create.start_at,
         end_time: create.end_at,
         attendee_name: name,
         attendee_email: guest,
         attendee_timezone: create.timezone,
         organizer_user_id: user_id,
         calendar_integration_id: create.integration_id,
         calendar_id: create.calendar_id,
         video_integration_id: create.video_integration_id,
         organizer_note: note,
         attendee_locale: locale,
         guest_emails: others,
         reminders: reminders
       }}
    end
  end

  @doc "Spends one meeting from the organiser's budget (20 in 10 minutes)."
  @spec rate_limit(pos_integer()) :: :ok | {:error, :rate_limited, String.t()}
  def rate_limit(user_id) do
    case RateLimiter.check(:dashboard_quick_add_meeting, user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  defp people(guests) do
    if length(guests) > max_guests(), do: {:error, :guests, :too_many}, else: :ok
  end

  defp guest_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :guest_name, :blank}
      trimmed -> clean_name(trimmed)
    end
  end

  defp guest_name(_value), do: {:error, :guest_name, :blank}

  defp clean_name(name) do
    case UniversalSanitizer.sanitize_and_validate(name, mode: :plain_text, max_length: @max_name) do
      {:ok, ""} -> {:error, :guest_name, :blank}
      {:ok, clean} -> {:ok, clean}
      {:error, _reason} -> {:error, :guest_name, :invalid}
    end
  end

  # No language leaves it to `CreateAdHoc`, which writes to the guests in the
  # booking default.
  defp locale(value) when value in [nil, ""], do: {:ok, nil}

  defp locale(value) do
    case Locales.acceptable(value) do
      nil -> {:error, :locale, :invalid}
      code -> {:ok, code}
    end
  end

  defp note(nil), do: {:ok, nil}

  defp note(text) when is_binary(text) do
    if String.length(text) <= MeetingSchema.organizer_note_max_length(),
      do: {:ok, text},
      else: {:error, :note, :too_long}
  end

  # The form sends an empty key with its boxes, so that ticking none still
  # sends the field; it stands for nothing.
  defp reminders(nil), do: {:ok, []}

  defp reminders(keys) when is_list(keys) do
    chosen = for {key, reminder} <- @reminders, key in keys, do: reminder

    if Enum.all?(keys, &(&1 in ["" | reminder_choices()])) and
         ReminderValidation.check_policy(chosen) == :ok,
       do: {:ok, chosen},
       else: {:error, :reminders, :invalid}
  end

  defp reminders(_keys), do: {:error, :reminders, :invalid}
end
