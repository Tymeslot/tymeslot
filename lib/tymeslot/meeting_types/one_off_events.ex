defmodule Tymeslot.MeetingTypes.OneOffEvents do
  @moduledoc """
  One-off events: a training, a webinar or a talk that takes place once, set
  up from Quick Add in a single step.

  Underneath, an event is a fixed-date group meeting type
  (`Tymeslot.MeetingTypes.FixedDates`) with exactly one planned session
  (`Tymeslot.Meetings.PlannedSessions`), flagged `one_off` so the dashboard
  lists it under events rather than among the host's regular meeting types.
  Everything else is what such a type already does: people sign up through
  its link until registration closes, the session is on the host's calendar
  from the start, and once it is over the type drops off the booking page.

  The type is checked like one saved from the meeting-type form
  (`FormValidation.check/3`: group-bookings access, ownership of the venue,
  video integration and calendar), and the type and its session are stored
  together or not at all.
  """

  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.{FormValidation, MeetingTypeQueries, Slugs}
  alias Tymeslot.Repo

  @type location :: {:venue, pos_integer()} | {:video, pos_integer()}

  @type params :: %{
          required(:user_id) => pos_integer(),
          required(:name) => String.t(),
          required(:starts_at) => DateTime.t(),
          required(:duration_minutes) => pos_integer(),
          required(:max_participants) => pos_integer(),
          required(:location) => location(),
          optional(:description) => String.t() | nil,
          optional(:registration_closes_at) => DateTime.t() | nil,
          optional(:calendar_integration_id) => pos_integer() | nil,
          optional(:target_calendar_id) => String.t() | nil
        }

  @doc """
  Creates the event's meeting type and plans its session, returning both.

  The name is the event's title. When the host already has a meeting type
  of that name (a monthly workshop planned again), the date is added to it,
  since names are unique per host. The link is derived from the name too,
  and made random only when that one is taken.
  """
  @spec create(params()) ::
          {:ok, %{meeting_type: map(), session: map()}}
          | {:error, atom() | Ecto.Changeset.t() | term()}
  def create(%{user_id: user_id} = params) do
    attrs = type_attrs(params, MeetingTypeQueries.list_all_meeting_types(user_id))

    with :ok <- FormValidation.check(user_id, attrs) do
      Repo.transaction(fn ->
        with {:ok, meeting_type} <- MeetingTypes.create_meeting_type(attrs),
             {:ok, session} <-
               PlannedSessions.add(meeting_type, params.starts_at,
                 registration_closes_at: Map.get(params, :registration_closes_at)
               ) do
          %{meeting_type: meeting_type, session: session}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  `meeting_types` as the booking page lists them: the host's regular types
  first, in their own order, then the one-off events by the date they take
  place, soonest first. An event has no place in the order the host drags
  the regular types into, so it would otherwise land wherever its default
  position falls.
  """
  @spec order_for_listing([map()]) :: [map()]
  def order_for_listing(meeting_types) do
    {events, regular} = Enum.split_with(meeting_types, &one_off?/1)
    regular ++ Enum.sort_by(events, &first_start/1, &sooner?/2)
  end

  defp first_start(meeting_type) do
    case PlannedSessions.upcoming(meeting_type) do
      [session | _later] -> session.start_time
      [] -> nil
    end
  end

  defp sooner?(nil, _other), do: false
  defp sooner?(_start, nil), do: true
  defp sooner?(left, right), do: DateTime.compare(left, right) != :gt

  @doc "Whether `meeting_type` was created as a one-off event."
  @spec one_off?(map() | nil) :: boolean()
  def one_off?(%{one_off: true}), do: true
  def one_off?(_meeting_type), do: false

  defp type_attrs(params, existing) do
    name = unique_name(String.trim(params.name), params.starts_at, existing)

    %{
      user_id: params.user_id,
      name: name,
      description: Map.get(params, :description),
      duration_minutes: params.duration_minutes,
      max_participants: params.max_participants,
      fixed_dates: true,
      one_off: true,
      is_active: true,
      slug: unique_slug(name, params.user_id, existing),
      locations: [location(params.location)],
      calendar_integration_id: Map.get(params, :calendar_integration_id),
      target_calendar_id: Map.get(params, :target_calendar_id)
    }
  end

  defp unique_name(name, starts_at, existing) do
    if Enum.any?(existing, &(&1.name == name)),
      do: "#{name} · #{Date.to_iso8601(DateTime.to_date(starts_at))}",
      else: name
  end

  # The name-derived slug the schema would accept, or a random one when it is
  # taken, too long, empty or reserved (`30min`, `poll`).
  defp unique_slug(name, user_id, existing) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    taken = MapSet.new(existing, &Slugs.effective_slug/1)

    if slug == "" or String.length(slug) > 80 or slug == "poll" or
         Regex.match?(~r/^\d+min$/, slug) or MapSet.member?(taken, slug),
       do: Slugs.generate_random_slug(user_id),
       else: slug
  end

  # The labels are the English defaults, which `LocationSelection` shows in
  # the reader's language.
  defp location({:venue, venue_id}),
    do: %{kind: "in_person", label: "In person", venue_ids: [venue_id], position: 0}

  defp location({:video, integration_id}),
    do: %{
      kind: "video",
      label: "Video call",
      video_integration_ids: [integration_id],
      position: 0
    }
end
