defmodule Tymeslot.MeetingTypes.OneOffEventsTest do
  @moduledoc """
  One-off events created in one step: a fixed-date group type with a single
  planned session, stored together or not at all.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :meeting_types

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.OneOffEvents
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup do
    TestMocks.setup_all_mocks()
    user = insert(:user)
    insert(:profile, user: user, timezone: "Etc/UTC")
    insert(:calendar_integration, user: user, is_active: true)
    venue = insert(:venue, user: user, name: "Main Hall")
    %{user: user, venue: venue}
  end

  defp starts_at(days \\ 10),
    do: Date.utc_today() |> Date.add(days) |> DateTime.new!(~T[18:00:00], "Etc/UTC")

  defp params(ctx, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: ctx.user.id,
        name: "Introduction to X",
        starts_at: starts_at(),
        duration_minutes: 90,
        max_participants: 20,
        location: {:venue, ctx.venue.id},
        registration_closes_at: DateTime.add(starts_at(), -86_400)
      },
      overrides
    )
  end

  test "creates a one-off fixed-date group type with its one session", ctx do
    assert {:ok, %{meeting_type: type, session: session}} = OneOffEvents.create(params(ctx))

    assert %MeetingTypeSchema{
             one_off: true,
             fixed_dates: true,
             max_participants: 20,
             duration_minutes: 90,
             is_active: true,
             slug: "introduction-to-x"
           } = type

    assert [%{kind: :in_person, venue_ids: [venue_id]}] = type.locations
    assert venue_id == ctx.venue.id

    assert session.planned
    assert session.meeting_type_id == type.id
    assert session.start_time == starts_at()
    assert session.registration_closes_at == DateTime.add(starts_at(), -86_400)
    assert [_one] = PlannedSessions.list(type)
  end

  test "names a repeat of an existing title by its date, with a link of its own", ctx do
    {:ok, %{meeting_type: first}} = OneOffEvents.create(params(ctx))

    assert {:ok, %{meeting_type: second}} =
             OneOffEvents.create(params(ctx, %{starts_at: starts_at(40)}))

    assert second.name == "Introduction to X · #{Date.to_iso8601(Date.add(Date.utc_today(), 40))}"
    assert second.slug != first.slug
  end

  test "numbers a title repeated on the same date, and keeps a long title within the limit",
       ctx do
    morning = DateTime.new!(Date.add(Date.utc_today(), 40), ~T[09:00:00], "Etc/UTC")
    evening = DateTime.new!(Date.add(Date.utc_today(), 40), ~T[18:00:00], "Etc/UTC")
    date = Date.to_iso8601(DateTime.to_date(morning))
    long = String.duplicate("a", 100)

    {:ok, _first} = OneOffEvents.create(params(ctx, %{name: long, registration_closes_at: nil}))

    assert {:ok, %{meeting_type: second}} =
             OneOffEvents.create(
               params(ctx, %{name: long, starts_at: morning, registration_closes_at: nil})
             )

    assert {:ok, %{meeting_type: third}} =
             OneOffEvents.create(
               params(ctx, %{name: long, starts_at: evening, registration_closes_at: nil})
             )

    assert String.ends_with?(second.name, " · #{date}")
    assert String.ends_with?(third.name, " · #{date} (2)")
    assert String.length(second.name) == 100
    assert String.length(third.name) == 100
  end

  test "stores nothing when the session cannot be planned", ctx do
    past = DateTime.add(DateTime.utc_now(), -3600)

    assert {:error, :start_in_past} =
             OneOffEvents.create(params(ctx, %{starts_at: past, registration_closes_at: nil}))

    assert Repo.all(MeetingTypeSchema) == []
    assert Repo.all(MeetingSchema) == []
  end

  test "refuses a host without a calendar people can book through", ctx do
    Repo.delete_all(CalendarIntegrationSchema)

    assert {:error, :no_calendar} = OneOffEvents.create(params(ctx))
    assert Repo.all(MeetingTypeSchema) == []
  end

  test "refuses a venue of another host", ctx do
    other_venue = insert(:venue, user: insert(:user))

    assert {:error, _reason} =
             OneOffEvents.create(params(ctx, %{location: {:venue, other_venue.id}}))

    assert Repo.all(MeetingTypeSchema) == []
  end

  test "the booking page lists the regular types first, then the events by date", ctx do
    regular = insert(:meeting_type, user: ctx.user, name: "Strategy Session", sort_order: 5)

    {:ok, %{meeting_type: later}} =
      OneOffEvents.create(
        params(ctx, %{name: "Later event", starts_at: starts_at(30), registration_closes_at: nil})
      )

    {:ok, %{meeting_type: sooner}} =
      OneOffEvents.create(
        params(ctx, %{name: "Sooner event", starts_at: starts_at(5), registration_closes_at: nil})
      )

    listed = ctx.user.id |> MeetingTypes.get_public_meeting_types() |> Enum.map(& &1.id)

    assert Enum.take(listed, -3) == [regular.id, sooner.id, later.id]
  end
end
