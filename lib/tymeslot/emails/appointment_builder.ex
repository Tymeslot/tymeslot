defmodule Tymeslot.Emails.AppointmentBuilder do
  @moduledoc """
  Builds appointment details payloads for email templates and delivery adapters.
  Extracted from EmailWorker to keep the worker focused on orchestration.
  """

  require Logger
  alias Tymeslot.Bookings.BookingTitle
  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Emails.HostClock
  alias Tymeslot.Emails.RecipientLocale
  alias Tymeslot.Emails.Shared.BookingRequestLocation
  alias Tymeslot.Emails.Shared.Formatting
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Recipient
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.Meetings.VideoRooms
  alias Tymeslot.MeetingTypes.Reminders
  alias Tymeslot.Profiles
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.UrlBuilder

  use Gettext, backend: TymeslotWeb.Gettext

  @spec from_meeting(map(), map() | nil) :: Tymeslot.Emails.EmailService.appointment_details()
  def from_meeting(meeting, reminder_interval \\ nil) do
    build(meeting, reminder_interval)
  end

  @doc """
  Appointment details as `recipient` sees them.

  For a `:participant` recipient this overlays their own name, email, phone,
  company, message, timezone, locale, custom-field answers, tokenised seat
  URLs and their seat's own calendar identity (UID and SEQUENCE) onto the
  meeting before the payload is built. `:attendee` recipients see the
  meeting unchanged. See `Recipient.as_seen_by/2`.
  """
  @spec from_meeting(MeetingSchema.t(), Recipient.t(), map() | nil) ::
          Tymeslot.Emails.EmailService.appointment_details()
  def from_meeting(%MeetingSchema{} = meeting, %Recipient{} = recipient, reminder_interval) do
    meeting
    |> Recipient.as_seen_by(recipient)
    |> build(reminder_interval)
  end

  @doc """
  Appointment details for a meeting moved from `original`, which carries the
  previous `start_time`, `end_time` and `attendee_video_url` (the meeting
  row no longer holds them), for the reschedule templates to show where the
  meeting moved from, in each party's timezone.
  """
  @spec for_reschedule(MeetingSchema.t(), map()) ::
          Tymeslot.Emails.EmailService.appointment_details()
  def for_reschedule(%MeetingSchema{} = meeting, original) do
    details = build(meeting, nil)

    Map.merge(details, %{
      original_date: DateTime.to_date(original.start_time),
      original_start_time: original.start_time,
      original_start_time_owner_tz:
        DateTimeUtils.convert_to_timezone(original.start_time, owner_timezone(meeting)),
      original_start_time_attendee_tz:
        DateTimeUtils.convert_to_timezone(original.start_time, details.attendee_timezone),
      original_end_time: original.end_time,
      original_attendee_video_url: Map.get(original, :attendee_video_url),
      is_rescheduled: true,
      rescheduled_at: DateTime.utc_now()
    })
  end

  @doc """
  Appointment details for a booking whose new time was approved after a
  reschedule sent it back into the approval gate. There is no previous time
  to compare with, so the templates leave out their "previously scheduled"
  line.
  """
  @spec for_reapproval(MeetingSchema.t()) :: Tymeslot.Emails.EmailService.appointment_details()
  def for_reapproval(%MeetingSchema{} = meeting) do
    meeting
    |> build(nil)
    |> Map.merge(%{is_rescheduled: true, rescheduled_at: DateTime.utc_now()})
  end

  @doc """
  The organiser's copy of an email about one seat of a group meeting.

  Built from the seat's participant, so the organiser is told who booked,
  left or moved (name, email, phone, company, message, answers), but never
  carries that participant's seat links: the organiser's way to act on the
  meeting is their dashboard, and the seat links are the participant's
  credentials. `:seats_taken` and `:capacity` say how full the slot is now.
  """
  @spec for_organizer_of_seat(MeetingSchema.t(), Recipient.t()) ::
          Tymeslot.Emails.EmailService.appointment_details()
  def for_organizer_of_seat(%MeetingSchema{} = meeting, %Recipient{kind: :participant} = seat) do
    meeting
    |> from_meeting(seat, nil)
    |> Map.merge(organizer_group_links())
    |> Map.merge(%{seats_taken: Seats.seats_taken(meeting.id), capacity: meeting.capacity})
  end

  @doc """
  The organiser's copy of a meeting-level email about a whole group meeting
  (its reminder, its cancellation): the slot itself, named after how many
  people are on it in the organiser's own language, with its links pointing
  at the organiser's dashboard, since the public booking links are refused
  for a group meeting.
  """
  @spec for_organizer_of_group(MeetingSchema.t(), non_neg_integer(), map() | nil) ::
          Tymeslot.Emails.EmailService.appointment_details()
  def for_organizer_of_group(%MeetingSchema{} = meeting, participant_count, reminder \\ nil) do
    details = from_meeting(meeting, reminder)

    label =
      Gettext.with_locale(TymeslotWeb.Gettext, details.organizer_locale, fn ->
        dngettext("emails", "%{count} participant", "%{count} participants", participant_count,
          count: participant_count
        )
      end)

    details
    |> Map.merge(organizer_group_links())
    |> Map.put(:attendee_name, label)
  end

  defp organizer_group_links do
    %{
      cancel_url: nil,
      reschedule_url: nil,
      view_url: nil,
      dashboard_url: UrlBuilder.build_url("/dashboard/meetings")
    }
  end

  defp build(meeting, reminder_interval) do
    attendee_locale = RecipientLocale.attendee_locale(meeting)

    Gettext.with_locale(TymeslotWeb.Gettext, attendee_locale, fn ->
      owner_timezone = owner_timezone(meeting)
      attendee_timezone = attendee_timezone(meeting, owner_timezone)

      organizer_profile = organizer_profile(meeting)
      organizer_locale = RecipientLocale.locale_for_user_id(Map.get(meeting, :organizer_user_id))

      base_details = base_details(meeting)
      timezone_details = timezone_details(meeting, owner_timezone, attendee_timezone)
      participant_details = participant_details(meeting, organizer_profile)
      preparation_details = preparation_details()
      url_details = url_details(meeting, organizer_profile)
      reminder_details = reminder_details(meeting, reminder_interval)

      base_details
      |> Map.merge(timezone_details)
      |> Map.merge(participant_details)
      |> Map.merge(preparation_details)
      |> Map.merge(url_details)
      |> Map.merge(reminder_details)
      |> Map.put(:attendee_locale, attendee_locale)
      |> Map.put(:organizer_locale, organizer_locale)
      |> Map.put(:organizer_time_format, organizer_time_format(meeting, organizer_locale))
      |> Map.put(:booking_payment, booking_payment_for(meeting))
    end)
  end

  # The organiser's chosen clock, resolved once per payload rather than per
  # template. Deliberately namespaced away from the plain `:time_format` key the
  # hero and text bodies read, so an attendee-addressed branch cannot pick it up
  # by accident: only the organiser branches copy it across.
  defp organizer_time_format(meeting, organizer_locale),
    do: HostClock.time_format(meeting, organizer_locale)

  # Look up the booking payment row attached to this meeting, if any.
  # Free bookings have no booking_payment row, so this returns nil and the
  # email template short-circuits the receipt block.
  defp booking_payment_for(%{id: meeting_id}) when is_binary(meeting_id),
    do: MeetingPayments.payment_for_meeting(meeting_id)

  defp booking_payment_for(_meeting), do: nil

  defp owner_timezone(%{organizer_user_id: nil} = meeting) do
    Logger.error("Missing organizer_user_id for meeting, using default timezone",
      meeting_id: meeting.id
    )

    HostClock.timezone(meeting)
  end

  defp owner_timezone(meeting), do: HostClock.timezone(meeting)

  # A group meeting's row never carries an attendee: its people are its
  # participants, whose own timezone comes in through the recipient overlay.
  # A payload built from the bare slot (the organiser's copy) has no attendee
  # timezone by design, so falling back to the organiser's is not a defect.
  defp attendee_timezone(%MeetingSchema{attendee_timezone: nil} = meeting, owner_timezone)
       when meeting.capacity > 1,
       do: owner_timezone

  defp attendee_timezone(meeting, owner_timezone) do
    case meeting.attendee_timezone do
      nil ->
        Logger.warning(
          "Missing attendee_timezone for meeting, using organizer timezone as emergency fallback",
          meeting_id: meeting.id
        )

        owner_timezone

      timezone ->
        timezone
    end
  end

  # `uid` here is the calendar event's UID (the `.ics` UID and the attachment
  # filename), so it is the `calendar_uid` of the meeting as this recipient
  # sees it: a solo attendee's copy matches the organiser's event, while a
  # group participant's overlay (`Tymeslot.Meetings.Recipient`) carries their
  # seat's own UID, since each seat is its own calendar entry. The booking's
  # own `uid` is the capability behind the cancel and reschedule links, which
  # travel as their own fields.
  #
  # The title is the attendee's: this payload is built in their locale, and
  # the attendee and guest copies carry it into the `.ics` they import. The
  # organiser's copies do not render it.
  defp base_details(meeting) do
    title = BookingTitle.localise(meeting)

    %{
      uid: meeting.calendar_uid,
      title: title,
      organizer_user_id: Map.get(meeting, :organizer_user_id),
      summary: if(meeting.summary in [nil, meeting.title], do: title, else: meeting.summary),
      description: meeting.description || "",
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      date: DateTime.to_date(meeting.start_time),
      duration: meeting.duration,
      location: format_location(meeting),
      location_type: determine_location_type(meeting),
      location_details: format_location_details(meeting),
      meeting_type: meeting.meeting_type,
      # Above 1 for a group meeting, whose participants' emails say they hold
      # one of these spots (`Tymeslot.Emails.Shared.GroupSession`).
      capacity: Map.get(meeting, :capacity),
      ical_sequence: Map.get(meeting, :ical_sequence) || 0,
      custom_fields_snapshot: Map.get(meeting, :custom_fields_snapshot) || [],
      custom_field_answers: Map.get(meeting, :custom_field_answers) || %{}
    }
  end

  defp determine_location_type(meeting), do: BookingRequestLocation.type(meeting)

  defp timezone_details(meeting, owner_timezone, attendee_timezone) do
    %{
      attendee_timezone: attendee_timezone,
      start_time_owner_tz: DateTimeUtils.convert_to_timezone(meeting.start_time, owner_timezone),
      end_time_owner_tz: DateTimeUtils.convert_to_timezone(meeting.end_time, owner_timezone),
      start_time_attendee_tz:
        DateTimeUtils.convert_to_timezone(meeting.start_time, attendee_timezone),
      end_time_attendee_tz: DateTimeUtils.convert_to_timezone(meeting.end_time, attendee_timezone)
    }
  end

  defp participant_details(meeting, organizer_profile) do
    %{
      # Organizer details
      organizer_name: meeting.organizer_name,
      organizer_email: meeting.organizer_email,
      organizer_title: meeting.organizer_title,
      organizer_avatar_url: Profiles.uploaded_avatar_url(organizer_profile),
      organizer_contact_info: dgettext("emails", "reply to this email"),

      # Attendee details
      attendee_name: meeting.attendee_name,
      attendee_email: meeting.attendee_email,
      attendee_message: meeting.attendee_message,
      organizer_note: meeting.organizer_note,
      attendee_phone: meeting.attendee_phone,
      attendee_company: meeting.attendee_company
    }
  end

  defp preparation_details do
    %{
      contact_info: dgettext("emails", "reply to this email"),
      allow_contact: true,
      time_until_friendly: dgettext("emails", "in 30 minutes")
    }
  end

  defp url_details(meeting, organizer_profile) do
    links = MeetingLinks.for_meeting(meeting, organizer_profile)

    %{
      # nil when the meeting has no such link: the templates leave an action
      # without a URL out rather than linking it to nowhere.
      view_url: links.view_url,
      reschedule_url: links.reschedule_url,
      cancel_url: links.cancel_url,
      # The host's public booking page, resolved at send time rather than read
      # from the meeting row. Unlike the per-meeting action URLs it is not
      # persisted, so it always reflects the host's current username.
      booking_url: UrlBuilder.booking_url(organizer_profile && organizer_profile.username),
      meeting_url: meeting.meeting_url,
      organizer_video_url: meeting.organizer_video_url,
      attendee_video_url: meeting.attendee_video_url,
      # The guests' link is the one this payload has to build rather than
      # read: it is not a column on the meeting, because a booking has any
      # number of guests. It names nobody, so one link serves them all and
      # the payload carries it once however many guests it is sent to.
      guest_video_url: VideoRooms.guest_join_url(meeting)
    }
  end

  defp organizer_profile(meeting), do: meeting |> Map.get(:organizer_user_id) |> profile_for()

  defp profile_for(nil), do: nil

  defp profile_for(user_id) do
    case Profiles.get_profile_by_user_id(user_id) do
      {:ok, profile} -> profile
      {:error, :not_found} -> nil
    end
  end

  defp reminder_details(meeting, reminder_interval) do
    case Reminders.normalize_reminder(reminder_interval) do
      {:ok, reminder} ->
        build_reminder_details_from_interval(reminder)

      _error ->
        meeting
        |> Map.get(:reminders)
        |> Reminders.normalize_reminders()
        |> handle_normalized_reminders(meeting)
    end
  end

  defp build_reminder_details_from_interval(%{value: value, unit: unit}) do
    reminder_label = localized_reminder_label(value, unit)

    %{
      reminder_time: reminder_label,
      reminder_raw: %{value: value, unit: unit},
      default_reminder_time: reminder_label,
      time_until: reminder_label,
      time_until_friendly: dgettext("emails", "in %{label}", label: reminder_label),
      reminders_enabled: true,
      reminders_summary:
        dgettext("emails", "Reminder %{label} before the appointment.", label: reminder_label)
    }
  end

  # A meeting booked before reminders were stored as value and unit carries
  # a label instead. One that reads as an interval is localised like any
  # other, for both recipients; free text the app no longer writes is kept.
  defp handle_normalized_reminders([], meeting) do
    label = legacy_reminder_label(meeting)

    case Reminders.parse_label(label) do
      {:ok, reminder} -> handle_normalized_reminders([reminder], meeting)
      :error -> legacy_reminder_details(label)
    end
  end

  defp handle_normalized_reminders([reminder], _meeting) do
    reminder_label = localized_reminder_label(reminder.value, reminder.unit)

    %{
      reminder_time: reminder_label,
      reminder_raw: %{value: reminder.value, unit: reminder.unit},
      default_reminder_time: reminder_label,
      time_until: reminder_label,
      time_until_friendly: dgettext("emails", "in %{label}", label: reminder_label),
      reminders_enabled: true,
      reminders_summary:
        dgettext("emails", "I'll send you a reminder %{label} before our appointment.",
          label: reminder_label
        )
    }
  end

  defp handle_normalized_reminders(reminder_list, _meeting) do
    closest =
      Enum.min_by(reminder_list, fn %{value: value, unit: unit} ->
        Reminders.reminder_interval_seconds(value, unit)
      end)

    reminder_label = localized_reminder_label(closest.value, closest.unit)

    %{
      reminder_time: reminder_label,
      reminder_raw: %{value: closest.value, unit: closest.unit},
      default_reminder_time: reminder_label,
      time_until: reminder_label,
      time_until_friendly: dgettext("emails", "in %{label}", label: reminder_label),
      reminders_enabled: true,
      reminders_summary:
        dngettext(
          "emails",
          "You'll receive %{count} reminder before the appointment.",
          "You'll receive %{count} reminders before the appointment.",
          length(reminder_list),
          count: length(reminder_list)
        )
    }
  end

  defp legacy_reminder_details(label) do
    case label do
      nil ->
        %{
          reminder_time: nil,
          default_reminder_time: nil,
          time_until: nil,
          time_until_friendly: nil,
          reminders_enabled: false,
          reminders_summary:
            dgettext("emails", "No reminder emails are scheduled for this appointment.")
        }

      legacy_label ->
        %{
          reminder_time: legacy_label,
          default_reminder_time: legacy_label,
          time_until: legacy_label,
          time_until_friendly: dgettext("emails", "in %{label}", label: legacy_label),
          reminders_enabled: true,
          reminders_summary:
            dgettext("emails", "I'll send you a reminder %{label} before our appointment.",
              label: legacy_label
            )
        }
    end
  end

  # Derive a display location from the meeting's fields. When a video URL is
  # present the location is "Video Call" regardless of any physical location
  # stored on the record. When nothing is set, return nil so the rendering
  # layer (`Formatting.format_location/1`) substitutes the localised "TBD".
  # Legacy meetings persisted the English placeholder before that change —
  # treat it as nil here so they also render translated.
  defp format_location(meeting) do
    cond do
      meeting.meeting_url -> "Video Call"
      meeting.location in [nil, "", "To be determined"] -> nil
      true -> meeting.location
    end
  end

  defp format_location_details(meeting), do: format_location(meeting)

  defp legacy_reminder_label(meeting) do
    meeting.reminder_time || meeting.default_reminder_time
  end

  # The reminder label in the locale this payload is built in (the
  # attendee's); see `Formatting.format_reminder_label/2`.
  defp localized_reminder_label(value, unit) do
    Formatting.format_reminder_label(
      %{value: value, unit: unit},
      Gettext.get_locale(TymeslotWeb.Gettext)
    )
  end
end
