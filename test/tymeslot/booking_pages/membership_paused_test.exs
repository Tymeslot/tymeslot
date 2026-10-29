defmodule Tymeslot.BookingPages.MembershipPausedTest do
  # Not async: the feature checker is application config.
  use Tymeslot.DataCase, async: false

  @moduletag :profiles
  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.BookingPages

  defmodule DenyGroupBookingsChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour

    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :group_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user)
    page = insert(:booking_page, profile: profile)
    %{user: user, page: page}
  end

  describe "once the host has lost access to group bookings" do
    setup do
      setup_config(:tymeslot, :feature_access_checker, DenyGroupBookingsChecker)
    end

    test "a paused group type ticked onto a page is left out, a one-to-one type stays", ctx do
      group = insert(:meeting_type, user: ctx.user, name: "Workshop", max_participants: 3)
      solo = insert(:meeting_type, user: ctx.user, name: "Solo")

      :ok = BookingPages.set_meeting_type(ctx.page, group.id, true)
      :ok = BookingPages.set_meeting_type(ctx.page, solo.id, true)

      assert ctx.page |> BookingPages.list_meeting_types() |> Enum.map(& &1.name) == ["Solo"]
    end
  end
end
