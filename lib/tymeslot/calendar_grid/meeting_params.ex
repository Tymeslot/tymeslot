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
  of them. Without a main participant (`"main_participant"` false) the host
  manages the meeting alone and every guest is invited as an equal guest,
  so it needs a title of its own: there is no guest whose name could stand
  in for it. The meeting's place is none, one of the organiser's saved
  locations, or one they typed in (sanitised as plain text) (`"location_choice"`,
  `"location_custom"`). The draft's notes become the note to the guests, held to the
  meeting's own limit. A meeting has a start and an end time, so an all-day
  draft is refused. Reminders are lead times, `%{value:, unit:}`, held to
  the rules a meeting type's reminders follow
  (`ReminderValidation.check_policy/2`). `rate_limit/1` is the budget each
  meeting spends, since every one emails its guests.
  """

  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.CalendarGrid.CreateParams
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.Reminders
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.UniversalSanitizer
  alias Tymeslot.Venues

  @max_name 255

  @type field ::
          :all_day | :guests | :guest_name | :locale | :location | :note | :reminders | :title

  @doc "How many people a meeting can be with: its guest and the guests it invites."
  @spec max_guests() :: pos_integer()
  # The guests a meeting invites, and the guest it is with. Read at run time
  # so this module does not compile against `Guests`.
  def max_guests, do: Guests.max_guests() + 1

  @doc """
  The meeting `create` describes, with the string-keyed `fields` the panel
  holds (`"main_participant"`, `"guest_name"`, `"locale"`, `"reminders"`,
  the lead times the reminder picker holds, `"location_choice"`,
  `"location_custom"`, and `"title"` as typed), for the organiser `user_id`.
  """
  @spec build(CreateParams.t(), map(), pos_integer()) ::
          {:ok, map()} | {:error, field(), atom()}
  def build(%CreateParams{all_day: true}, _fields, _user_id), do: {:error, :all_day, :timed_only}
  def build(%CreateParams{guests: []}, _fields, _user_id), do: {:error, :guests, :none}

  def build(
        %CreateParams{guests: guests} = create,
        %{"main_participant" => false} = fields,
        user_id
      ) do
    with :ok <- people(guests, Guests.max_guests(), :too_many_guests),
         :ok <- own_title(fields["title"]),
         {:ok, shared} <- shared(create, fields, user_id) do
      {:ok, Map.merge(shared, %{guest_emails: guests, managed_by_host: true})}
    end
  end

  def build(%CreateParams{guests: [guest | others] = guests} = create, fields, user_id)
      when is_map(fields) do
    with :ok <- people(guests, max_guests(), :too_many),
         {:ok, name} <- guest_name(fields["guest_name"]),
         {:ok, shared} <- shared(create, fields, user_id) do
      {:ok,
       Map.merge(shared, %{attendee_name: name, attendee_email: guest, guest_emails: others})}
    end
  end

  # What a meeting carries whoever it is with.
  defp shared(create, fields, user_id) do
    with {:ok, locale} <- locale(fields["locale"]),
         {:ok, note} <- note(create.description),
         {:ok, reminders} <- reminders(fields["reminders"]),
         {:ok, location} <-
           location(fields["location_choice"], fields["location_custom"], user_id) do
      {:ok,
       %{
         title: create.title,
         start_time: create.start_at,
         end_time: create.end_at,
         attendee_timezone: create.timezone,
         organizer_user_id: user_id,
         calendar_integration_id: create.integration_id,
         calendar_id: create.calendar_id,
         video_integration_id: create.video_integration_id,
         organizer_note: note,
         attendee_locale: locale,
         reminders: reminders,
         location: location
       }}
    end
  end

  @doc "Spends one meeting from the organiser's budget (10 in 10 minutes)."
  @spec rate_limit(pos_integer()) :: :ok | {:error, :rate_limited, String.t()}
  def rate_limit(user_id) do
    case RateLimiter.check(:dashboard_quick_add_meeting, user_id) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, :rate_limited, message}
    end
  end

  defp people(guests, max, reason) do
    if length(guests) > max, do: {:error, :guests, reason}, else: :ok
  end

  defp own_title(title) when is_binary(title) do
    if String.trim(title) == "", do: {:error, :title, :blank}, else: :ok
  end

  defp own_title(_title), do: {:error, :title, :blank}

  # As `CreateAdHoc` takes it: `{:venue, id}` for one of the organiser's
  # saved locations, `{:custom, text}` for a place typed in, nil for none.
  # A saved location is looked up among the organiser's own, so one deleted
  # while the panel was open is refused here rather than by the booking.
  defp location("venue:" <> id, _custom, user_id) do
    with {venue_id, ""} <- Integer.parse(id),
         {:ok, venue} <- Venues.get_venue(user_id, venue_id) do
      {:ok, {:venue, venue.id}}
    else
      _invalid -> {:error, :location, :invalid}
    end
  end

  # A place typed in is sanitised as plain text, as the guest's name is.
  defp location("custom", custom, _user_id) when is_binary(custom) do
    case String.trim(custom) do
      "" -> {:ok, nil}
      place -> clean_place(place)
    end
  end

  defp location(choice, _custom, _user_id) when choice in [nil, "", "custom"], do: {:ok, nil}
  defp location(_choice, _custom, _user_id), do: {:error, :location, :invalid}

  defp clean_place(place) do
    max = CreateAdHoc.custom_location_max_length()

    if String.valid?(place) and String.length(place) > max do
      {:error, :location, :too_long}
    else
      case UniversalSanitizer.sanitize_and_validate(place, mode: :plain_text, max_length: max) do
        {:ok, ""} -> {:ok, nil}
        {:ok, clean} -> {:ok, {:custom, clean}}
        {:error, _reason} -> {:error, :location, :unsafe}
      end
    end
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

  defp reminders(nil), do: {:ok, []}

  defp reminders(held) when is_list(held) do
    with {:ok, chosen} <- normalise_reminders(held),
         :ok <- ReminderValidation.check_policy(chosen) do
      {:ok, chosen}
    else
      _invalid -> {:error, :reminders, :invalid}
    end
  end

  defp reminders(_held), do: {:error, :reminders, :invalid}

  # Each lead time as `%{value: pos_integer, unit: "minutes" | "hours" |
  # "days"}`; the first that is not one refuses them all.
  defp normalise_reminders(held) do
    Enum.reduce_while(held, {:ok, []}, fn reminder, {:ok, normalised} ->
      case Reminders.normalize_reminder(reminder) do
        {:ok, clean} -> {:cont, {:ok, normalised ++ [clean]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
