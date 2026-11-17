defmodule Tymeslot.MeetingTypes.FormValidationTest do
  @moduledoc """
  A paid group type needs both plan gates, each checked on its own: group
  bookings (`:group_bookings_allowed`) and meeting payments
  (`:meeting_payments`).
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes.FormValidation

  defmodule NoGroupChecker do
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :group_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  defmodule NoPaymentsChecker do
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :meeting_payments), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  @paid_group %{max_participants: 8, payment_required: true, price_cents: 2500}

  test "a paid group type needs the group gate" do
    setup_config(:tymeslot, feature_access_checker: NoGroupChecker)

    assert {:error, :group_bookings_not_allowed} =
             FormValidation.check(insert(:user).id, @paid_group)
  end

  test "a paid group type needs the payments gate" do
    setup_config(:tymeslot, feature_access_checker: NoPaymentsChecker)

    assert {:error, :insufficient_plan} = FormValidation.check(insert(:user).id, @paid_group)
  end
end
