defmodule Tymeslot.Bookings.CreateAdHoc do
  @moduledoc """
  Creates ad-hoc meetings directly from the dashboard calendar.

  Unlike `Bookings.Create`, this does not require a meeting type or booking form.
  The organiser provides attendee details and timing directly, and the system
  creates a full Meeting record with calendar sync, email notifications, and
  optional video room provisioning.
  """

  alias Ecto.UUID
  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Bookings.MeetingLinks
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  @type params :: %{
          required(:title) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          required(:attendee_name) => String.t(),
          required(:attendee_email) => String.t(),
          required(:organizer_user_id) => pos_integer(),
          optional(:attendee_timezone) => String.t(),
          optional(:calendar_integration_id) => pos_integer() | nil,
          optional(:calendar_path) => String.t() | nil,
          optional(:video_integration_id) => pos_integer() | nil,
          optional(:guest_emails) => [String.t()],
          optional(:organizer_note) => String.t() | nil,
          optional(:attendee_locale) => String.t() | nil,
          optional(:reminders) => [%{value: pos_integer(), unit: String.t()}]
        }

  @type error ::
          :title_required
          | :attendee_name_required
          | :attendee_email_required
          | :attendee_is_organizer
          | :end_before_start
          | :time_conflict
          | :meeting_creation_failed

  @spec execute(params()) :: {:ok, Tymeslot.Meetings.MeetingSchema.t()} | {:error, error()}
  def execute(params) do
    with {:ok, meeting, pending} <- execute_deferred(params) do
      :ok = Activation.after_commit(pending)
      Availability.changed(meeting.organizer_user_id)
      {:ok, meeting}
    end
  end

  @doc """
  `execute/1` for a caller that runs it inside a transaction of its own
  (`Tymeslot.Polls.Confirm`). The meeting, its guests and its jobs are
  written as `execute/1` writes them, but nothing that belongs after the
  commit runs: the integration fan-out is returned as `pending`, for the
  caller to hand to `Tymeslot.Bookings.Activation.after_commit/1` once its
  transaction has committed, and the host's cached availability is left for
  the caller to invalidate then.
  """
  @spec execute_deferred(params()) ::
          {:ok, Tymeslot.Meetings.MeetingSchema.t(), Tymeslot.Notifications.Events.pending()}
          | {:error, error()}
  def execute_deferred(params) do
    # The organiser's details are resolved once and threaded through: validation
    # needs the organiser email to reject self-booking, and the meeting attrs
    # need all three fields. Looking them up twice would risk the check and the
    # stored `organizer_email` disagreeing.
    organizer = get_organizer_details(params.organizer_user_id)

    with :ok <- validate(params, organizer) do
      guest_emails = params[:guest_emails] || []

      params
      |> build_meeting_attrs(organizer)
      |> run_transaction(guest_emails)
    end
  end

  defp validate(params, {_org_name, org_email, _org_username}) do
    cond do
      blank?(params[:title]) ->
        {:error, :title_required}

      blank?(params[:attendee_name]) ->
        {:error, :attendee_name_required}

      blank?(params[:attendee_email]) ->
        {:error, :attendee_email_required}

      same_address?(params[:attendee_email], org_email) ->
        {:error, :attendee_is_organizer}

      DateTime.compare(params.end_time, params.start_time) != :gt ->
        {:error, :end_before_start}

      true ->
        :ok
    end
  end

  # Booking yourself as your own guest produces a meeting whose organiser and
  # attendee are one person: both confirmation emails land in the same inbox,
  # and the cancel/reschedule links are addressed to the organiser as if they
  # were the guest. Compared case-insensitively, since addresses are not
  # case-sensitive in the part that matters here.
  defp same_address?(attendee_email, org_email)
       when is_binary(attendee_email) and is_binary(org_email) do
    normalise_address(attendee_email) == normalise_address(org_email)
  end

  defp same_address?(_attendee_email, _org_email), do: false

  defp normalise_address(email), do: email |> String.trim() |> String.downcase()

  defp blank_to_nil(note) when is_binary(note) do
    case String.trim(note) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_note), do: nil

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_other), do: false

  defp build_meeting_attrs(params, {org_name, org_email, org_username}) do
    uid = UUID.generate()
    duration = DateTime.diff(params.end_time, params.start_time, :minute)

    # A booking-time copy of the links for readers of the stored columns;
    # links shown to anyone are built afresh by `MeetingLinks.for_meeting/1`.
    links = MeetingLinks.build(org_username, uid)

    Map.merge(links, %{
      uid: uid,
      title: params.title,
      summary: params.title,
      description: "",
      start_time: params.start_time,
      end_time: params.end_time,
      duration: duration,
      location: nil,
      meeting_type: params.title,
      meeting_type_id: nil,
      organizer_name: org_name,
      organizer_email: org_email,
      organizer_user_id: params.organizer_user_id,
      calendar_integration_id: params[:calendar_integration_id],
      calendar_path: params[:calendar_path],
      video_integration_id: params[:video_integration_id],
      attendee_name: params.attendee_name,
      attendee_email: params.attendee_email,
      # The organiser is the author of everything on this meeting, so any note
      # is theirs; `attendee_message` stays for words the attendee wrote.
      attendee_message: nil,
      organizer_note: blank_to_nil(params[:organizer_note]),
      # What the organiser picked, and explicitly none when they picked none,
      # not "unset". A nil here is read by `Notifications.Orchestrator` as a
      # meeting from before the reminders column existed, and answered with the
      # legacy default of 30 minutes, so a booking whose own confirmation says
      # no reminders are scheduled would send one anyway.
      reminders: params[:reminders] || [],
      attendee_timezone: params[:attendee_timezone] || "Etc/UTC",
      # The organiser chooses which language the guests are written to; a
      # missing or unsupported choice falls back to the booking default.
      attendee_locale:
        Locales.acceptable(params[:attendee_locale]) || Locales.booking_default_locale(),
      status: "confirmed",
      meeting_url: nil
    })
  end

  defp run_transaction(meeting_attrs, guest_emails) do
    result =
      Repo.transaction(fn ->
        # Guests are inserted after the meeting exists and before notifications
        # fire, so a guest changeset failure rolls the whole booking back. The
        # caller pre-validates the list, so emails are passed through as-is.
        # The host is the one inviting them, whatever brought them here (Quick
        # Add, or a poll the host confirmed), and their invitation says so.
        with {:ok, meeting} <- create_meeting(meeting_attrs),
             {:ok, _guests} <- Guests.create_for_meeting(meeting.id, guest_emails, :organizer),
             {:ok, _job} <- schedule_calendar_job(meeting),
             {:ok, pending} <- Activation.activate_in_transaction(meeting, with_video_room: true) do
          # The video-room-then-emails-then-webhooks sequence itself lives in
          # `Bookings.Activation`, shared with every other confirmed-booking path so
          # the ordering (room before emails, so the join link is in the
          # confirmation) cannot drift between call sites. `with_video_room: true`
          # matches this flow's own semantics: the organiser picked the video
          # integration explicitly, so its presence alone decides whether a room is
          # created, the same as a paid checkout confirming a booking.
          # `Activation` is the whole of it. A second, generic calendar invitation used
          # to go out beside the confirmation, leaving the guest with two emails for
          # one booking: the confirmation in their language, carrying the ICS file, the
          # accept/decline links and the video link, and a bare "You're Invited" with
          # none of those. It was not initialising anything either, whatever the
          # comment here claimed — `AttendeeNotifications.event_created/2` only sends,
          # and `last_notified_state` is written after a dispatch by the debounce
          # worker, never on create. The baseline stays empty here exactly as it does
          # for every other booking path, which `LastNotifiedState.to_event/2` is built
          # to handle: the people on the event are the people this path already
          # invited. A booking whose emails cannot be queued rolls back with them.
          {meeting, pending}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    map_result(result)
  end

  defp create_meeting(attrs) do
    # Booking limits guard the host's public capacity; a host deliberately
    # creating a meeting from their own dashboard may exceed their caps.
    case Scheduling.create_meeting_with_conflict_check(attrs, enforce_booking_limits: false) do
      {:ok, meeting} -> {:ok, meeting}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_calendar_job(meeting) do
    if meeting.calendar_integration_id do
      CalendarJobs.schedule_job(meeting, "create")
    else
      {:ok, :skipped}
    end
  end

  defp map_result({:ok, {meeting, pending_integrations}}),
    do: {:ok, meeting, pending_integrations}

  # Preserve the time-conflict reason distinctly so callers can tell an occupied
  # slot apart from a generic booking failure.
  defp map_result({:error, :time_conflict}), do: {:error, :time_conflict}
  defp map_result({:error, _reason}), do: {:error, :meeting_creation_failed}

  defp get_organizer_details(user_id) do
    case ProfileQueries.get_by_user_id(user_id) do
      {:error, :not_found} ->
        {fallback_name(), fallback_email(), nil}

      {:ok, profile} ->
        profile = ProfileQueries.preload_user(profile)
        name = profile.full_name || profile.user.name || fallback_name()
        email = profile.user.email || fallback_email()
        username = profile.username
        {name, email, username}
    end
  end

  defp fallback_name do
    Application.get_env(:tymeslot, :email)[:from_name] || "Organiser"
  end

  defp fallback_email do
    Application.get_env(:tymeslot, :email)[:from_email] || "noreply@tymeslot.app"
  end
end
