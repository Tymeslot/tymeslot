defmodule Tymeslot.CursorPaginationTestCases do
  @moduledoc false

  @doc """
  Shared cursor pagination test cases reused across Meetings tests.
  """
  @cursor_pagination_tests (quote do
    import Tymeslot.MeetingTestHelpers
    alias Tymeslot.Meetings

    defp seed_cursor_meetings(user) do
      for i <- 1..5 do
        insert_meeting_for_user(user, %{start_offset: 86_400 * i})
      end
    end

    defp fetch_cursor_page(user, opts \\ []) do
      opts = Keyword.put_new(opts, :per_page, 3)
      Meetings.list_user_meetings_cursor_page(user.email, opts)
    end

    test "returns first page of meetings" do
      %{user: user} = create_user_with_profile()

      seed_cursor_meetings(user)

      assert {:ok, page} = fetch_cursor_page(user)

      assert length(page.items) == 3
      assert page.page_size == 3
      assert page.has_more == true
      assert page.next_cursor != nil
    end

    test "returns empty page for user with no meetings" do
      %{user: user} = create_user_with_profile()

      assert {:ok, page} = fetch_cursor_page(user)

      assert page.items == []
      assert page.has_more == false
      assert page.next_cursor == nil
    end

    test "filters by status correctly" do
      %{user: user} = create_user_with_profile()

      insert_meeting_for_user(user)
      insert_meeting_for_user(user, %{status: "cancelled"})

      assert {:ok, page} = fetch_cursor_page(user, status: "confirmed")

      assert length(page.items) == 1
      assert hd(page.items).status == "confirmed"
    end

    test "returns error for invalid cursor" do
      %{user: user} = create_user_with_profile()

      assert {:error, :invalid_cursor} = fetch_cursor_page(user, after: "invalid-cursor")
    end
  end)

  defmacro shared_cursor_pagination_tests do
    @cursor_pagination_tests
  end
end
