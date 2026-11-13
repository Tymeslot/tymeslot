defmodule Tymeslot.Meetings.OrganiserVisibilityTest do
  @moduledoc """
  Every surface that shows an organiser their bookings leaves out the ones
  they may not see (`Tymeslot.Meetings.MeetingState.visible_to_organiser?/1`):
  a booking still held for its attendee's email verification or one that
  expired unverified, and a booking that never got past payment, whether its
  checkout is still open or lapsed. A verified or paid booking shows as any
  other. A new organiser-facing surface gets its case here.

  The holds stay taken for the public meanwhile: the offer and the busy
  periods behind the booking page still count them.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :analytics

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Invitations
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.BusyPeriods
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.MeetingTypes.OfferedTimes
  alias Tymeslot.Repo

  @filters ["upcoming", "past", "cancelled", "awaiting_approval", "all"]

  setup do
    user = insert(:user)
    now = DateTime.utc_now(:second)
    start = DateTime.add(now, 2, :day)
    later = DateTime.add(now, -1, :hour)

    book = fn hours, attrs ->
      starts = DateTime.add(start, hours, :hour)

      insert(
        :meeting,
        Keyword.merge(
          [
            organizer_user_id: user.id,
            start_time: starts,
            end_time: DateTime.add(starts, 30, :minute)
          ],
          attrs
        )
      )
    end

    visible = %{
      ungated: book.(0, status: :confirmed),
      verified:
        book.(1,
          status: :confirmed,
          verification_deadline_at: later,
          email_verified_at: DateTime.add(later, -10, :minute)
        ),
      paid: book.(2, status: :confirmed),
      # An approval request that lapsed: `Approval` stamps the resolution.
      lapsed_request:
        book.(3,
          status: :expired,
          approval_requested_at: later,
          approval_resolved_at: now,
          cancelled_at: now
        )
    }

    hidden = %{
      held:
        book.(4,
          status: :awaiting_verification,
          verification_deadline_at: DateTime.add(now, 30, :minute)
        ),
      lapsed_unverified: book.(5, status: :expired, verification_deadline_at: later),
      unpaid: book.(6, status: :awaiting_payment),
      # A paid type that requires approval stamps the request at submission,
      # so only the missing resolution tells this checkout apart.
      lapsed_checkout: book.(7, status: :expired, approval_requested_at: later)
    }

    insert(:booking_payment, meeting_id: visible.paid.id, status: :paid, paid_at: now)
    insert(:booking_payment, meeting_id: hidden.unpaid.id, status: :pending)
    insert(:booking_payment, meeting_id: hidden.lapsed_checkout.id, status: :failed)

    %{
      user: user,
      visible: visible,
      hidden: hidden,
      from: DateTime.add(start, -1, :hour),
      to: DateTime.add(start, 9, :hour)
    }
  end

  defp ids(meetings), do: meetings |> Map.values() |> Enum.map(& &1.id)

  defp listed(user, filter) do
    {:ok, page} = Meetings.list_user_meetings_by_filter(user.id, filter, per_page: 50)
    Enum.map(page.items, & &1.id)
  end

  describe "the bookings list" do
    test "never shows an unverified or unpaid booking", %{
      user: user,
      visible: visible,
      hidden: hidden
    } do
      listed_by_filter = Map.new(@filters, &{&1, listed(user, &1)})

      # Anchors: the list is not empty for the wrong reason.
      assert MapSet.subset?(
               MapSet.new([visible.ungated.id, visible.verified.id, visible.paid.id]),
               MapSet.new(listed_by_filter["upcoming"])
             )

      assert visible.lapsed_request.id in listed_by_filter["all"]

      for {filter, listed_ids} <- listed_by_filter do
        assert Enum.filter(ids(hidden), &(&1 in listed_ids)) == [],
               "#{filter} lists a hidden booking"
      end
    end

    test "the focus card does not open a hidden booking", %{
      user: user,
      visible: visible,
      hidden: hidden
    } do
      for id <- ids(hidden) do
        assert {:ok, %{items: []}} = Meetings.list_user_meeting(user.id, id)
      end

      assert {:ok, %{items: [%{id: id}]}} =
               Meetings.list_user_meeting(user.id, visible.verified.id)

      assert id == visible.verified.id
    end

    test "an unpaid booking shows once it is paid", %{user: user, hidden: hidden} do
      refute hidden.unpaid.id in listed(user, "upcoming")

      hidden.unpaid |> Changeset.change(status: :confirmed) |> Repo.update!()

      assert hidden.unpaid.id in listed(user, "upcoming")
    end
  end

  describe "the calendar grid and the time-off warning" do
    test "leave out held and unpaid bookings by default", ctx do
      in_range =
        ctx.user.id
        |> Meetings.list_meetings_in_range_for_organizer(ctx.from, ctx.to)
        |> Enum.map(& &1.id)

      assert Enum.sort(in_range) ==
               Enum.sort([ctx.visible.ungated.id, ctx.visible.verified.id, ctx.visible.paid.id])

      with_hidden =
        ctx.user.id
        |> Meetings.list_meetings_in_range_for_organizer(ctx.from, ctx.to, include_hidden: true)
        |> Enum.map(& &1.id)

      assert ctx.hidden.held.id in with_hidden
      assert ctx.hidden.unpaid.id in with_hidden
    end
  end

  describe "what the public may still book" do
    test "busy periods keep every hold", ctx do
      starts = [] |> BusyPeriods.merge(ctx.user.id, ctx.from, ctx.to) |> Enum.map(& &1.start_time)

      assert ctx.hidden.held.start_time in starts
      assert ctx.hidden.unpaid.start_time in starts
    end

    test "an offered time stays taken while its booking is held or unpaid", %{
      user: user,
      hidden: hidden
    } do
      type =
        insert(:meeting_type,
          user: user,
          max_participants: 1,
          fixed_dates: true,
          duration_minutes: 30
        )

      {:ok, held_time} = OfferedTimes.add(type, user.id, hidden.held.start_time)
      {:ok, unpaid_time} = OfferedTimes.add(type, user.id, hidden.unpaid.start_time)

      assert OfferedTimes.next_by_type([type]) == %{type.id => nil}

      hidden.held |> Changeset.change(status: :expired) |> Repo.update!()
      assert OfferedTimes.next_by_type([type]) == %{type.id => held_time.starts_at}

      hidden.unpaid |> Changeset.change(status: :expired) |> Repo.update!()
      Repo.delete!(held_time)
      assert OfferedTimes.next_by_type([type]) == %{type.id => unpaid_time.starts_at}
    end
  end

  describe "host fetches" do
    test "answer not found for a hidden booking", %{user: user, hidden: hidden} do
      for meeting <- Map.values(hidden) do
        assert Meetings.get_meeting_for_organizer(meeting.id, user.id) == {:error, :not_found}

        assert Meetings.get_meeting_by_uid_for_organizer(meeting.uid, user.id) ==
                 {:error, :not_found}

        assert {:ok, {:error, :not_found}} =
                 Repo.transaction(fn ->
                   MeetingQueries.lock_meeting_for_organizer(meeting.id, user.id)
                 end)
      end
    end

    test "find a verified or paid booking", %{user: user, visible: visible} do
      for meeting <- [visible.verified, visible.paid] do
        assert {:ok, %{id: id}} = Meetings.get_meeting_for_organizer(meeting.id, user.id)
        assert id == meeting.id
        assert {:ok, %{id: ^id}} = Meetings.get_meeting_by_uid_for_organizer(meeting.uid, user.id)

        assert {:ok, {:ok, %{id: ^id}}} =
                 Repo.transaction(fn ->
                   MeetingQueries.lock_meeting_for_organizer(meeting.id, user.id)
                 end)
      end
    end
  end

  describe "analytics" do
    test "count only the bookings the organiser may see", %{user: user} do
      now = DateTime.utc_now()

      assert Meetings.count_bookings(
               user.id,
               DateTime.add(now, -1, :hour),
               DateTime.add(now, 1, :hour)
             ) == 4
    end

    test "a host whose only booking is hidden has had no real booking" do
      host = insert(:user)
      insert(:meeting, organizer_user_id: host.id, status: :awaiting_payment)
      insert(:awaiting_verification_meeting, organizer_user_id: host.id)

      assert Meetings.organisers_with_real_booking([host.id]) == []

      starts = DateTime.add(DateTime.utc_now(:second), 5, :day)

      insert(:meeting,
        organizer_user_id: host.id,
        status: :confirmed,
        start_time: starts,
        end_time: DateTime.add(starts, 30, :minute)
      )

      assert Meetings.organisers_with_real_booking([host.id]) == [host.id]
    end
  end

  describe "the invitations list" do
    setup %{user: user} do
      %{type: insert(:meeting_type, user: user, invitation_only: true)}
    end

    test "shows an invitation as available while its booking awaits verification", %{
      user: user,
      type: type
    } do
      {:ok, invitation} = Invitations.create(user.id, type, %{})

      held =
        insert(:awaiting_verification_meeting,
          organizer_user_id: user.id,
          invitation_id: invitation.id
        )

      assert [%{status: :available, meeting: nil}] = Invitations.list(user.id, type)

      held
      |> Changeset.change(status: :confirmed, email_verified_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert [%{status: :used, meeting: %{id: id}}] = Invitations.list(user.id, type)
      assert id == held.id
    end

    test "shows an invitation as available while its booking awaits payment", %{
      user: user,
      type: type
    } do
      {:ok, invitation} = Invitations.create(user.id, type, %{})

      unpaid =
        insert(:meeting,
          organizer_user_id: user.id,
          invitation_id: invitation.id,
          status: :awaiting_payment
        )

      assert [%{status: :available, meeting: nil}] = Invitations.list(user.id, type)

      unpaid |> Changeset.change(status: :confirmed) |> Repo.update!()

      assert [%{status: :used}] = Invitations.list(user.id, type)
    end
  end
end
