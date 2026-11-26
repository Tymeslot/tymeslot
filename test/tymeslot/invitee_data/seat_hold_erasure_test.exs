defmodule Tymeslot.InviteeData.SeatHoldErasureTest do
  @moduledoc """
  Erasure of what a booker gave while paying for a seat (`seat_holds`): an
  open checkout refuses the erasure, a settled hold naming the person, as
  booker or guest, is deleted.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.GroupCancellationTestHelpers
  alias Tymeslot.InviteeData
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.Repo

  @email "ada@example.com"

  setup do
    GroupCancellationTestHelpers.host_and_session()
  end

  test "an open seat checkout blocks erasure", ctx do
    GroupCancellationTestHelpers.open_hold(ctx, "Ada@Example.com")

    assert {:error, {:upcoming_meetings, [uid]}} = InviteeData.erase(@email)
    assert uid == ctx.session.uid
  end

  test "an open checkout naming the email as a guest blocks erasure", %{session: session} do
    insert(:seat_hold,
      meeting: session,
      email: "bob@example.com",
      seats: 2,
      status: :held,
      guests: [%{"name" => nil, "email" => "ADA@example.com"}]
    )

    assert {:error, {:upcoming_meetings, [uid]}} = InviteeData.erase(@email)
    assert uid == session.uid
  end

  describe "a hold still held past its window" do
    # Past its `expires_at` and the sweeper's grace: its payment outcome
    # never reached it, and the sweeper keeps leaving it held.
    setup do
      %{overdue: DateTime.add(DateTime.utc_now(:second), -6, :minute)}
    end

    test "no longer blocks erasure, and keeps its seats with the booker cleared", ctx do
      hold =
        insert(:seat_hold,
          meeting: ctx.session,
          email: "Ada@Example.com",
          name: "Ada Lovelace",
          phone: "+44 20 7946 0000",
          message: "See you there",
          custom_field_answers: %{"role" => "Engineer"},
          seats: 2,
          guests: [%{"name" => nil, "email" => "guest@example.com"}],
          expires_at: ctx.overdue
        )

      assert {:ok, %{seat_holds: 1}} = InviteeData.erase(@email)

      scrubbed = Repo.get!(SeatHoldSchema, hold.id)
      assert %{status: :held, seats: 2, name: "", phone: nil, message: nil} = scrubbed
      assert scrubbed.email == "erased-#{hold.id}@erased.invalid"
      assert scrubbed.custom_field_answers == %{}
      assert scrubbed.guests == [%{"name" => nil, "email" => "guest@example.com"}]
    end

    test "clears only the erased guest's address on it", ctx do
      hold =
        insert(:seat_hold,
          meeting: ctx.session,
          email: "bob@example.com",
          seats: 3,
          guests: [
            %{"name" => nil, "email" => "carol@example.com"},
            %{"name" => "Ada", "email" => "ADA@example.com"}
          ],
          expires_at: ctx.overdue
        )

      assert {:ok, %{seat_holds: 1}} = InviteeData.erase(@email)

      assert %{email: "bob@example.com", seats: 3, guests: guests} =
               Repo.get!(SeatHoldSchema, hold.id)

      assert guests == [
               %{"name" => nil, "email" => "carol@example.com"},
               %{"name" => nil, "email" => "erased-#{hold.id}-2@erased.invalid"}
             ]
    end

    test "still blocks erasure inside the sweeper's grace", ctx do
      insert(:seat_hold,
        meeting: ctx.session,
        email: @email,
        expires_at: DateTime.add(DateTime.utc_now(:second), -1, :minute)
      )

      assert {:error, {:upcoming_meetings, [uid]}} = InviteeData.erase(@email)
      assert uid == ctx.session.uid
    end
  end

  test "an open checkout on a slot held for another booker's confirmation blocks erasure", ctx do
    ctx.session
    |> Changeset.change(
      status: :awaiting_verification,
      verification_deadline_at: DateTime.add(DateTime.utc_now(:second), 30, :minute)
    )
    |> Repo.update!()

    GroupCancellationTestHelpers.open_hold(ctx, @email)

    assert {:error, {:upcoming_meetings, [uid]}} = InviteeData.erase(@email)
    assert uid == ctx.session.uid
  end

  test "erasure deletes the booker's settled holds", %{session: session} do
    hold =
      insert(:seat_hold,
        meeting: session,
        email: "Ada@Example.com",
        status: :released,
        released_reason: :expired
      )

    other = insert(:seat_hold, meeting: session, email: "bob@example.com", status: :converted)

    assert {:ok, %{seat_holds: 1}} = InviteeData.erase(@email)

    refute Repo.get(SeatHoldSchema, hold.id)
    assert Repo.get(SeatHoldSchema, other.id)
  end

  test "erasure deletes a hold that only names the email as a guest", %{session: session} do
    hold =
      insert(:seat_hold,
        meeting: session,
        email: "bob@example.com",
        seats: 2,
        status: :converted,
        guests: [%{"name" => "Ada", "email" => "ADA@example.com"}]
      )

    no_guests =
      insert(:seat_hold, meeting: session, email: "carol@example.com", status: :converted)

    assert {:ok, %{seat_holds: 1}} = InviteeData.erase(@email)

    refute Repo.get(SeatHoldSchema, hold.id)
    assert Repo.get(SeatHoldSchema, no_guests.id)
  end

  test "host-scoped erasure leaves other hosts' holds", %{host: host, session: session} do
    mine = insert(:seat_hold, meeting: session, email: @email, status: :converted)
    other_session = insert(:group_meeting, organizer_user: insert(:user))
    theirs = insert(:seat_hold, meeting: other_session, email: @email, status: :converted)

    assert {:ok, %{seat_holds: 1}} = InviteeData.erase_for_host(host.id, @email)

    refute Repo.get(SeatHoldSchema, mine.id)
    assert Repo.get(SeatHoldSchema, theirs.id)
  end
end
