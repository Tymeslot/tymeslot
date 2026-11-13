defmodule Tymeslot.MeetingTypes.FormValidationSeriesTest do
  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes.FormValidation

  defmodule DenyChecker do
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :recurring_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  defmodule FailingChecker do
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :recurring_bookings_allowed), do: raise("down")
    def check_access(_user_id, _feature), do: :ok
  end

  setup do
    setup_config(:tymeslot, feature_access_checker: DenyChecker)
    %{user: insert(:user)}
  end

  test "enabling a series without access is refused", %{user: user} do
    assert {:error, :recurring_bookings_not_allowed} =
             FormValidation.check(user.id, %{series_mode: :flexible}, 1, nil)

    assert {:error, :recurring_bookings_not_allowed} =
             FormValidation.check(user.id, %{series_mode: :recurring})
  end

  test "editing an enabled series without access is allowed", %{user: user} do
    assert :ok = FormValidation.check(user.id, %{series_mode: :recurring}, 1, :flexible)
  end

  test "disabling a series without access is allowed", %{user: user} do
    assert :ok = FormValidation.check(user.id, %{series_mode: nil}, 1, :recurring)
  end

  test "a write that does not touch the series is allowed", %{user: user} do
    assert :ok = FormValidation.check(user.id, %{name: "Intro"})
  end

  test "a checker failure passes through", %{user: user} do
    setup_config(:tymeslot, feature_access_checker: FailingChecker)

    assert {:error, :feature_access_checker_failed} =
             FormValidation.check(user.id, %{series_mode: :flexible})
  end
end
