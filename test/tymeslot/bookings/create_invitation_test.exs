defmodule Tymeslot.Bookings.CreateInvitationTest do
  @moduledoc """
  Booking an invitation-only meeting type through `Create.execute/3`: the
  invitation is required, recorded on the meeting, used up by one live
  booking, and freed (or not) by cancelling, as `release_on_cancel` says.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [create_always_bookable_profile: 0]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.MeetingTestHelpers, only: [build_form_data: 0, build_meeting_params: 2]

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Invitations
  alias Tymeslot.MeetingPayments.HeldMeetings
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Meetings.UniqueInvitation
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    %{user: user} = create_always_bookable_profile()

    type =
      insert(:meeting_type,
        user: user,
        invitation_only: true,
        is_active: true,
        duration_minutes: 60
      )

    %{user: user, type: type}
  end

  defp params(ctx, day, overrides \\ %{}) do
    build_meeting_params(
      ctx.user,
      Map.merge(
        %{date: Date.add(Date.utc_today(), day), time: "14:00", meeting_type_id: ctx.type.id},
        overrides
      )
    )
  end

  defp book(ctx, day, invitation_id),
    do: Create.execute(params(ctx, day, %{invitation_id: invitation_id}), build_form_data())

  defp invite(ctx, attrs \\ %{}) do
    {:ok, invitation} = Invitations.create(ctx.user.id, ctx.type, attrs)
    invitation
  end

  defp status_of(ctx, invitation) do
    %{status: status} =
      ctx.user.id
      |> Invitations.list(ctx.type)
      |> Enum.find(&(&1.invitation.id == invitation.id))

    status
  end

  defp meeting_count(user),
    do: Repo.aggregate(from(m in MeetingSchema, where: m.organizer_user_id == ^user.id), :count)

  test "a booking on an invitation-only type without an invitation is refused", ctx do
    assert Create.execute(params(ctx, 3), build_form_data()) == {:error, :invitation_required}
    assert meeting_count(ctx.user) == 0
  end

  test "a booking with a valid invitation records it", ctx do
    invitation = invite(ctx)

    assert {:ok, %MeetingSchema{} = meeting} = book(ctx, 3, invitation.id)
    assert meeting.invitation_id == invitation.id
    assert status_of(ctx, invitation) == :used
  end

  test "a second booking with the same invitation is refused", ctx do
    invitation = invite(ctx)

    assert {:ok, _meeting} = book(ctx, 3, invitation.id)
    assert book(ctx, 4, invitation.id) == {:error, :invitation_unavailable}
    assert meeting_count(ctx.user) == 1
  end

  test "an invitation for another meeting type is refused", ctx do
    other_type = insert(:meeting_type, user: ctx.user, invitation_only: true, is_active: true)
    {:ok, foreign} = Invitations.create(ctx.user.id, other_type, %{})

    assert book(ctx, 3, foreign.id) == {:error, :invitation_unavailable}
    assert meeting_count(ctx.user) == 0
  end

  test "an invitation id on a plain type is ignored", ctx do
    invitation = invite(ctx)
    plain = insert(:meeting_type, user: ctx.user, is_active: true, duration_minutes: 60)

    attrs = %{meeting_type_id: plain.id, invitation_id: invitation.id}

    assert {:ok, meeting} = Create.execute(params(ctx, 3, attrs), build_form_data())
    assert meeting.invitation_id == nil
    assert status_of(ctx, invitation) == :available
  end

  test "cancelling frees the invitation when release_on_cancel", ctx do
    invitation = invite(ctx, %{release_on_cancel: true})

    {:ok, meeting} = book(ctx, 3, invitation.id)
    assert {:ok, _cancelled} = Meetings.cancel_meeting(meeting)

    assert {:ok, rebooked} = book(ctx, 4, invitation.id)
    assert rebooked.invitation_id == invitation.id
  end

  test "cancelling does not free it otherwise", ctx do
    invitation = invite(ctx, %{release_on_cancel: false})

    {:ok, meeting} = book(ctx, 3, invitation.id)
    assert {:ok, _cancelled} = Meetings.cancel_meeting(meeting)

    assert book(ctx, 4, invitation.id) == {:error, :invitation_unavailable}
  end

  test "an update cannot rewrite which invitation a meeting was booked with", ctx do
    invitation = invite(ctx)
    other = invite(ctx)
    {:ok, meeting} = book(ctx, 3, invitation.id)

    assert {:ok, updated} = MeetingQueries.update_meeting(meeting, %{invitation_id: other.id})
    assert updated.invitation_id == invitation.id
    assert Repo.reload!(meeting).invitation_id == invitation.id
  end

  test "a group type is never claimable, as its booking would not record the invitation", ctx do
    group =
      insert(:meeting_type,
        user: ctx.user,
        invitation_only: true,
        max_participants: 3,
        is_active: true,
        duration_minutes: 60
      )

    {:ok, invitation} = Invitations.create(ctx.user.id, group, %{})
    attrs = %{meeting_type_id: group.id, invitation_id: invitation.id}

    assert Create.execute(params(ctx, 3, attrs), build_form_data()) ==
             {:error, :invitation_unavailable}

    assert meeting_count(ctx.user) == 0
  end

  test "an approval-required invitation-only booking holds the invitation, and a decline frees it",
       ctx do
    {:ok, type} =
      ctx.type |> Changeset.change(requires_approval: true) |> Repo.update()

    ctx = %{ctx | type: type}
    invitation = invite(ctx, %{release_on_cancel: false})

    assert {:ok, meeting} = book(ctx, 3, invitation.id)
    assert meeting.status == :awaiting_approval
    assert meeting.invitation_id == invitation.id
    assert status_of(ctx, invitation) == :used

    assert book(ctx, 4, invitation.id) == {:error, :invitation_unavailable}

    assert {:ok, _declined} = Approval.decline(meeting, "Not this time")
    assert status_of(ctx, invitation) == :available
  end

  test "re-enabling invitation-only revives a link left outstanding", ctx do
    invitation = invite(ctx)

    assert {:ok, open} = MeetingTypes.set_invitation_only(ctx.type, false)
    assert Invitations.resolve(invitation.token) == {:error, :not_found}

    assert {:ok, type} = MeetingTypes.set_invitation_only(open, true)
    assert {:ok, %{id: id}} = Invitations.resolve(invitation.token)
    assert id == invitation.id

    assert {:ok, meeting} = book(%{ctx | type: type}, 3, invitation.id)
    assert meeting.invitation_id == invitation.id
    assert status_of(ctx, invitation) == :used
  end

  test "a reschedule keeps the invitation and needs no second use", ctx do
    invitation = invite(ctx)
    {:ok, meeting} = book(ctx, 3, invitation.id)

    new_params = %{
      date: Date.to_string(Date.add(Date.utc_today(), 5)),
      time: "10:00 AM",
      duration: "60min",
      user_timezone: "America/New_York",
      organizer_user_id: ctx.user.id
    }

    assert {:ok, moved} = Meetings.reschedule_meeting(meeting.uid, new_params, ctx.user.id)
    assert moved.id == meeting.id
    assert moved.start_time != meeting.start_time
    assert moved.invitation_id == invitation.id
    assert status_of(ctx, invitation) == :used
    assert meeting_count(ctx.user) == 1
  end

  # A paid meeting that waits for its payment holds its slot, and so its
  # invitation; the expiry that releases the slot releases the invitation too.
  describe "on a paid invitation-only type" do
    setup ctx do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        meeting_payments_enabled: true
      )

      insert(:connect_account,
        user: ctx.user,
        stripe_account_id: "acct_INVITED",
        default_currency: "eur",
        charges_enabled: true
      )

      {:ok, paid} =
        ctx.type
        |> Changeset.change(payment_required: true, price_cents: 5000)
        |> Repo.update()

      %{type: paid}
    end

    test "a paid invitation-only booking holds the invitation while awaiting payment", ctx do
      expect(StripeAdapterMock, :create_checkout_session, fn _params, _opts ->
        {:ok, %{id: "cs_INVITED", url: "https://checkout.stripe.com/cs_INVITED"}}
      end)

      invitation = invite(ctx)

      assert {:ok, :payment_required, %{meeting: meeting}} = book(ctx, 3, invitation.id)
      assert meeting.status == :awaiting_payment
      assert meeting.invitation_id == invitation.id

      assert book(ctx, 4, invitation.id) == {:error, :invitation_unavailable}

      assert {:ok, {:ok, :expired, _expired}} =
               Repo.transaction(fn -> HeldMeetings.expire(meeting.id) end)

      assert status_of(ctx, invitation) == :available
    end
  end

  # A meeting brought back after its invitation was booked again (a late
  # payment completing on an expired booking, the only reinstate path) would
  # make a second live booking on the invitation: the index refuses it as a
  # changeset error.
  test "reinstating an expired meeting whose invitation was rebooked is refused cleanly", ctx do
    invitation = invite(ctx)
    {:ok, first} = book(ctx, 3, invitation.id)
    {:ok, expired} = MeetingQueries.update_meeting_status(first, %{status: :expired})

    assert {:ok, _second} = book(ctx, 4, invitation.id)

    write = fn ->
      case MeetingQueries.update_meeting_status(expired, %{status: :confirmed}) do
        {:ok, meeting} -> meeting
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end

    assert {:error, %Ecto.Changeset{} = changeset} =
             Scheduling.reinstate_with_conflict_check(expired, write)

    assert UniqueInvitation.violation?(changeset)
    assert Repo.reload!(expired).status == :expired
  end
end
