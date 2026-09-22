defmodule Tymeslot.Scheduling.SharedAvailability do
  @moduledoc """
  Booking a host together with other Tymeslot users.

  A booking link can name further users of the same instance, as in
  `/marco?with=michael,sandy`. The booking still belongs to the host alone:
  their meeting type, calendar, video integration and booking limits apply,
  and the other users are added to it as ordinary guests, with the invitation
  every guest receives. What they add is their availability. A time is only
  offered, and only accepted on submit, when every one of them is free too.

  For each such guest this checks the working hours of their default
  availability schedule (breaks and date overrides included), the busy times
  of their connected calendars and the bookings they host in Tymeslot
  themselves. The scheduling policy is the strictest of everyone involved:
  the largest buffer and minimum notice, and the shortest advance booking
  window.

  Only users with a bookable public page can be named, and only on a meeting
  type that allows guests: a link then reveals nothing about a user that their
  own booking page does not already show, and the host decides per meeting
  type whether guests may join at all.

  Nothing about the link is stored on the booking. When it is rescheduled, the
  users to check are recovered from its guests instead
  (`resolve_from_guest_emails/2`): every guest whose address belongs to a
  Tymeslot user who could have been named in a link counts, whichever way they
  were added.
  """

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Availability.{Calculate, Schedules, TimeSlots}
  alias Tymeslot.Bookings.Validation
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Scheduling.LinkAccessPolicy

  @query_param "with"

  defmodule Guest do
    @moduledoc "A Tymeslot user whose availability a booking is checked against."

    @enforce_keys [:user_id, :username, :name, :email, :timezone, :profile, :schedule]
    defstruct @enforce_keys ++ [schedule_data: %{}]

    @type t :: %__MODULE__{
            user_id: pos_integer(),
            username: String.t(),
            name: String.t(),
            email: String.t(),
            timezone: String.t(),
            profile: map(),
            schedule: map() | nil,
            schedule_data: map()
          }
  end

  @typedoc "Fetches a user's calendar events for a date, as `{:ok, events}` or `{:error, reason}`."
  @type events_fetcher :: (Guest.t(), Date.t() -> {:ok, list()} | {:error, term()})

  @doc "The query parameter a booking link names the additional users in."
  @spec query_param() :: String.t()
  def query_param, do: @query_param

  @doc """
  Parses the value of the `with` query parameter into a list of usernames.

  Usernames are separated by commas; surrounding whitespace, empty entries and
  duplicates are dropped and case is ignored. An absent or empty parameter is
  `{:ok, []}`. Anything that is not a string (a crafted `with[]=` list, say)
  or names more users than a booking may have guests is an error.
  """
  @spec parse_usernames(term()) :: {:ok, [String.t()]} | {:error, :invalid_usernames}
  def parse_usernames(nil), do: {:ok, []}

  def parse_usernames(value) when is_binary(value) do
    usernames =
      value
      |> String.split(",")
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if length(usernames) <= Guests.max_guests(),
      do: {:ok, usernames},
      else: {:error, :invalid_usernames}
  end

  def parse_usernames(_value), do: {:error, :invalid_usernames}

  @doc """
  Resolves usernames to the users a booking with `host_user_id` is checked
  against.

  Fails as a whole when any of them cannot take part: an unknown username, the
  host naming themselves, or a user without a bookable public page (a
  connected calendar and at least one public meeting type). A link that
  silently dropped someone would let a booking go ahead without them.
  """
  @spec resolve([String.t()], pos_integer()) ::
          {:ok, [Guest.t()]} | {:error, :unavailable_guests}
  def resolve([], _host_user_id), do: {:ok, []}

  def resolve(usernames, host_user_id) when is_list(usernames) do
    result =
      Enum.reduce_while(usernames, {:ok, []}, fn username, {:ok, acc} ->
        case resolve_guest(username, host_user_id) do
          {:ok, guest} -> {:cont, {:ok, [guest | acc]}}
          :error -> {:halt, {:error, :unavailable_guests}}
        end
      end)

    with {:ok, guests} <- result, do: {:ok, Enum.reverse(guests)}
  end

  @doc """
  Recovers the users a booking's availability is checked against from its
  guest emails, for rescheduling a booking made with a `with` link.

  Unlike `resolve/2` this never fails: a guest who is not a Tymeslot user, or
  one who can no longer be booked, is simply not checked, because the booking
  already exists and a guest list is not a promise that everyone on it is
  bookable.
  """
  @spec resolve_from_guest_emails([String.t()], pos_integer()) :: [Guest.t()]
  def resolve_from_guest_emails(emails, host_user_id) when is_list(emails) do
    emails
    |> Enum.flat_map(fn email ->
      with {:ok, user} <- UserQueries.get_user_by_email(email),
           {:ok, profile} <- ProfileQueries.get_by_user_id(user.id),
           username when is_binary(username) <- profile.username,
           {:ok, guest} <- resolve_guest(username, host_user_id) do
        [guest]
      else
        _not_a_bookable_user -> []
      end
    end)
    |> Enum.uniq_by(& &1.user_id)
  end

  @doc """
  The users to check when the host's booking `meeting_uid` is rescheduled,
  recovered from its guests (`resolve_from_guest_emails/2`). A booking that is
  not the host's has none.
  """
  @spec resolve_for_booking(String.t(), pos_integer()) :: [Guest.t()]
  def resolve_for_booking(meeting_uid, host_user_id)
      when is_binary(meeting_uid) and is_integer(host_user_id) do
    case MeetingQueries.get_meeting_by_uid_for_organizer(meeting_uid, host_user_id) do
      {:ok, meeting} ->
        meeting.id
        |> Guests.list_for_meeting()
        |> Enum.map(& &1.email)
        |> resolve_from_guest_emails(host_user_id)

      {:error, _not_found} ->
        []
    end
  end

  def resolve_for_booking(_meeting_uid, _host_user_id), do: []

  @doc """
  An `t:events_fetcher/0` that reads each guest's calendar live, with a five
  second limit, as the host's calendar is read on submit.

  Events with the UID `exclude_uid` are left out. When a booking is
  rescheduled, the invitation a guest accepted into their own calendar carries
  the booking's UID, and must not block the booking from moving.
  """
  @spec fresh_events_fetcher(String.t() | nil) :: events_fetcher()
  def fresh_events_fetcher(exclude_uid \\ nil) do
    fn guest, date ->
      task =
        Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
          CalendarEvents.get_events_for_range_fresh(guest.user_id, date, date)
        end)

      case Task.yield(task, 5_000) || Task.shutdown(task) do
        {:ok, {:ok, events}} -> {:ok, exclude_event(events, exclude_uid)}
        {:ok, {:error, _reason} = error} -> error
        nil -> {:error, :timeout}
      end
    end
  end

  @doc "Drops the events carrying `uid` (the booking itself) from `events`."
  @spec exclude_event(list(), String.t() | nil) :: list()
  def exclude_event(events, nil), do: events
  def exclude_event(events, uid), do: Enum.reject(events, &(Map.get(&1, :uid) == uid))

  defp resolve_guest(username, host_user_id) do
    with {:ok, profile} <- ProfileQueries.get_by_username_with_user(username),
         true <- profile.user_id != host_user_id,
         {:ok, :ready} <- LinkAccessPolicy.check_public_readiness(profile),
         [_public | _rest] <- MeetingTypes.get_public_meeting_types(profile.user_id),
         %{email: email} when is_binary(email) and email != "" <- profile.user do
      {:ok,
       %Guest{
         user_id: profile.user_id,
         username: profile.username,
         name: Profiles.display_name(profile) || profile.username,
         email: email,
         timezone: profile.timezone || Profiles.get_default_timezone(),
         profile: profile,
         schedule: Schedules.get_default(profile.id)
       }}
    else
      _unavailable -> :error
    end
  end

  @doc """
  Tightens the scheduling policy in `config` to the strictest of the host's
  and every guest's: the largest buffer and minimum notice, the shortest
  advance booking window. Returns `config` unchanged without guests.
  """
  @spec strictest_policy(map(), [Guest.t()]) :: map()
  def strictest_policy(config, []), do: config

  def strictest_policy(config, guests) do
    host = Calculate.config_policy(config)
    guest_policies = Enum.map(guests, &guest_policy/1)

    Map.merge(config, %{
      buffer_minutes:
        Enum.max([host.buffer_minutes | Enum.map(guest_policies, & &1.buffer_minutes)]),
      min_advance_hours:
        Enum.max([host.min_advance_hours | Enum.map(guest_policies, & &1.min_advance_hours)]),
      max_advance_booking_days:
        Enum.min([
          host.max_advance_booking_days | Enum.map(guest_policies, & &1.max_advance_booking_days)
        ])
    })
  end

  defp guest_policy(%Guest{schedule: schedule}) do
    %{
      buffer_minutes: Schedules.policy(schedule, :buffer_minutes),
      min_advance_hours: Schedules.policy(schedule, :min_advance_hours),
      max_advance_booking_days: Schedules.policy(schedule, :advance_booking_days)
    }
  end

  @doc """
  Keeps only the slots of `host_slots` (the host's offer for `date`, as slot
  strings in `user_timezone`) that every guest can attend.

  `policy_config` must already carry the strictest policy
  (`strictest_policy/2`). Each guest's own offer is computed by the same engine
  as the host's, on a one-minute grid so that it does not depend on how the
  guest's working hours happen to align with the host's slot interval.
  """
  @spec filter_slots(
          [String.t()],
          Date.t(),
          pos_integer(),
          String.t(),
          [Guest.t()],
          map(),
          events_fetcher()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def filter_slots(host_slots, _date, _duration, _user_timezone, guests, _policy_config, _fetcher)
      when host_slots == [] or guests == [],
      do: {:ok, host_slots}

  def filter_slots(host_slots, date, duration, user_timezone, guests, policy_config, fetcher) do
    Enum.reduce_while(guests, {:ok, host_slots}, fn guest, {:ok, remaining} ->
      case guest_start_times(guest, date, duration, user_timezone, policy_config, fetcher) do
        {:ok, start_times} ->
          {:cont, {:ok, Enum.filter(remaining, &MapSet.member?(start_times, slot_time(&1)))}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp guest_start_times(guest, date, duration, user_timezone, policy_config, fetcher) do
    with {:ok, events} <- busy_times(guest, date, fetcher),
         {:ok, slots} <-
           Calculate.available_slots(
             date,
             duration,
             user_timezone,
             guest.timezone,
             events,
             guest_config(guest, policy_config)
           ) do
      {:ok, MapSet.new(slots, &slot_time/1)}
    end
  end

  @doc """
  Loads each guest's weekly schedule and date overrides for the range once, so
  that checking many dates (the calendar grid) reads them from memory instead
  of querying per date.
  """
  @spec prefetch_schedule_data([Guest.t()], Date.t(), Date.t()) :: [Guest.t()]
  def prefetch_schedule_data(guests, start_date, end_date) do
    Enum.map(guests, fn guest ->
      data =
        Calculate.prefetch_schedule_data(
          %{},
          guest.schedule && guest.schedule.id,
          Date.add(start_date, -1),
          Date.add(end_date, 1)
        )

      %{guest | schedule_data: data}
    end)
  end

  @doc """
  Checks on submit that every guest can attend the booking from
  `start_datetime` to `end_datetime`.

  Re-derives each guest's offer for the slot and checks it against their
  calendar and the bookings they host. Returns `{:error, :slot_unavailable}`
  for the first guest who cannot attend, and passes a calendar read failure
  through as `{:error, reason}`, for the caller to treat the same way it treats
  the host's.
  """
  @spec validate_guests_available(
          [Guest.t()],
          Date.t(),
          DateTime.t(),
          DateTime.t(),
          String.t(),
          map(),
          events_fetcher()
        ) :: :ok | {:error, term()}
  def validate_guests_available(
        guests,
        date,
        start_datetime,
        end_datetime,
        user_timezone,
        policy_config,
        fetcher
      ) do
    duration = DateTime.diff(end_datetime, start_datetime, :minute)

    Enum.reduce_while(guests, :ok, fn guest, :ok ->
      config = guest_config(guest, policy_config)

      with {:ok, true} <-
             Calculate.offers_slot(
               date,
               start_datetime,
               duration,
               user_timezone,
               guest.timezone,
               config
             ),
           {:ok, events} <- busy_times(guest, date, fetcher),
           :ok <- Validation.validate_no_conflicts(start_datetime, end_datetime, events, config) do
        {:cont, :ok}
      else
        {:ok, false} -> {:halt, {:error, :slot_unavailable}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  The guest emails a booking with these guests is created with: the users
  named in the link first, so the guest cap can never drop one of them, then
  the addresses the booker entered.
  """
  @spec merge_guest_emails([Guest.t()], [String.t()]) :: [String.t()]
  def merge_guest_emails(guests, booker_emails) do
    Enum.map(guests, & &1.email) ++ (booker_emails || [])
  end

  # A guest's own schedule, with the strictest policy of the whole booking and a
  # one-minute grid.
  defp guest_config(guest, policy_config) do
    policy = Calculate.config_policy(policy_config)

    Map.merge(guest.schedule_data, %{
      schedule_id: guest.schedule && guest.schedule.id,
      buffer_minutes: policy.buffer_minutes,
      min_advance_hours: policy.min_advance_hours,
      max_advance_booking_days: policy.max_advance_booking_days,
      slot_interval_minutes: 1,
      owner_timezone: guest.timezone
    })
  end

  # Calendar busy times plus the guest's own live Tymeslot bookings, which only
  # reach their calendar once the calendar job has run. The bookings are plain
  # maps with `start_time`/`end_time`, the shape the conflict checks accept.
  defp busy_times(guest, date, fetcher) do
    with {:ok, events} <- fetcher.(guest, date) do
      {from_utc, to_utc} = day_bounds_utc(date)

      hosted =
        guest.user_id
        |> Meetings.list_meetings_in_range_for_organizer(from_utc, to_utc)
        |> Enum.map(&%{start_time: &1.start_time, end_time: &1.end_time})

      {:ok, events ++ hosted}
    end
  end

  # Generous on purpose: a day in the booker's timezone can reach well into the
  # previous or next UTC day, and extra bookings outside it cannot conflict.
  defp day_bounds_utc(date) do
    start_of_day = DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
    {DateTime.add(start_of_day, -1, :day), DateTime.add(start_of_day, 2, :day)}
  end

  defp slot_time(slot), do: TimeSlots.parse_time_slot(slot)
end
