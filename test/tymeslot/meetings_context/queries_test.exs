defmodule Tymeslot.MeetingsContext.QueriesTest do
  @moduledoc """
  Behaviour tests for the Meetings context covering read paths:
  upcoming/past/cancelled listings and cursor pagination.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  import Mox
  import Bitwise, only: [bxor: 2]

  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Listing
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.TestMocks
  import Tymeslot.MeetingTestHelpers
  import Tymeslot.CursorPaginationTestCases

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    :ok
  end

  describe "when viewing upcoming meetings" do
    test "returns only future confirmed meetings" do
      %{user: user} = create_user_with_profile()

      upcoming = insert_meeting_for_user(user)

      _past =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -86_400,
          duration: 3_600
        })

      meetings = Meetings.list_upcoming_meetings_for_user(user.email)

      assert length(meetings) == 1
      assert hd(meetings).id == upcoming.id
    end

    test "returns empty list when user has no upcoming meetings" do
      %{user: user} = create_user_with_profile()

      meetings = Meetings.list_upcoming_meetings_for_user(user.email)

      assert meetings == []
    end
  end

  describe "when viewing past meetings" do
    test "returns only past meetings" do
      %{user: user} = create_user_with_profile()

      past =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -86_400,
          duration: 3_600
        })

      _upcoming = insert_meeting_for_user(user)

      meetings = MeetingListQueries.list_past_meetings_for_user(user.email)

      assert length(meetings) == 1
      assert hd(meetings).id == past.id
    end
  end

  describe "when viewing cancelled meetings" do
    test "returns only cancelled meetings" do
      %{user: user} = create_user_with_profile()

      cancelled =
        insert_meeting_for_user(user, %{
          status: "cancelled"
        })

      _confirmed = insert_meeting_for_user(user)

      meetings = MeetingListQueries.list_cancelled_meetings_for_user(user.email, [])

      assert length(meetings) == 1
      assert hd(meetings).id == cancelled.id
    end
  end

  describe "when paginating meetings with cursor" do
    shared_cursor_pagination_tests()

    test "returns subsequent pages using cursor" do
      %{user: user} = create_user_with_profile()

      for i <- 1..5 do
        insert_meeting_for_user(user, %{start_offset: 86_400 * i})
      end

      {:ok, page1} = Listing.list_user_meetings_cursor_page(user.email, per_page: 3)

      {:ok, page2} =
        Listing.list_user_meetings_cursor_page(user.email,
          per_page: 3,
          after: page1.next_cursor
        )

      assert length(page2.items) == 2
      assert page2.has_more == false

      page1_ids = Enum.map(page1.items, & &1.id)
      page2_ids = Enum.map(page2.items, & &1.id)
      assert Enum.all?(page2_ids, fn id -> id not in page1_ids end)
    end

    # The cursor's after_id is embedded in the signed payload — a cursor
    # generated for user A and replayed against user B's scope must still
    # return only user B's rows. The scope filter is the primary guard,
    # but if someone ever forged an after_id the same property must hold.
    test "a cursor minted for one user does not leak rows from another" do
      %{user: user_a} = create_user_with_profile()
      %{user: user_b} = create_user_with_profile()

      for i <- 1..5 do
        insert_meeting_for_user(user_a, %{start_offset: 86_400 * i})
        insert_meeting_for_user(user_b, %{start_offset: 86_400 * i})
      end

      {:ok, page_a} = Listing.list_user_meetings_cursor_page(user_a.email, per_page: 3)
      assert page_a.next_cursor

      {:ok, page_b_with_a_cursor} =
        Listing.list_user_meetings_cursor_page(user_b.email,
          per_page: 3,
          after: page_a.next_cursor
        )

      assert Enum.all?(page_b_with_a_cursor.items, &(&1.organizer_email == user_b.email))
    end

    test "a tampered cursor returns {:error, :invalid_cursor}" do
      %{user: user} = create_user_with_profile()
      insert_meeting_for_user(user)

      {:ok, page} = Listing.list_user_meetings_cursor_page(user.email, per_page: 1)
      assert page.next_cursor

      # Flip a bit inside the payload segment of the signed token. Last-byte
      # mutations in base64url can decode to the same bytes; mid-segment
      # mutation guarantees the HMAC verify will fail.
      [header, payload, sig] = String.split(page.next_cursor, ".")
      <<first, rest::binary>> = payload
      tampered = Enum.join([header, <<bxor(first, 0xFF), rest::binary>>, sig], ".")

      assert {:error, :invalid_cursor} =
               Listing.list_user_meetings_cursor_page(user.email,
                 per_page: 1,
                 after: tampered
               )
    end
  end
end
