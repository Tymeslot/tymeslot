defmodule Tymeslot.Analytics.ContractTest do
  use ExUnit.Case, async: true
  @moduletag :infrastructure

  import ExUnit.CaptureLog

  alias Tymeslot.Analytics.Contract

  test "event names are snake_case and prop keys are atoms" do
    for {name, keys} <- Contract.registry() do
      assert name =~ ~r/^[a-z][a-z0-9_]*$/, "bad event name: #{name}"
      assert Enum.all?(keys, &is_atom/1), "non-atom prop key on #{name}"
    end
  end

  test "no declared prop key is on the PII denylist" do
    for {name, keys} <- Contract.registry(), key <- keys do
      refute key in Contract.pii_denylist(), "event #{name} declares PII key #{key}"
    end
  end

  test "validate! rejects unknown events, undeclared keys, and non-categorical values" do
    assert_raise ArgumentError, fn -> Contract.validate!("nope", %{}) end

    assert_raise ArgumentError, fn ->
      Contract.validate!("onboarding_step_completed", %{user_id: 1})
    end

    assert_raise ArgumentError, fn ->
      Contract.validate!("onboarding_step_completed", %{step: %{}})
    end

    assert :ok = Contract.validate!("onboarding_step_completed", %{step: "profile"})

    assert :ok =
             Contract.validate!("onboarding_step_completed", %{
               step: "connect_calendar",
               skipped: true
             })
  end

  describe "non-strict mode (analytics_strict: false)" do
    setup do
      prior = Application.get_env(:tymeslot, :analytics_strict, true)
      Application.put_env(:tymeslot, :analytics_strict, false)
      on_exit(fn -> Application.put_env(:tymeslot, :analytics_strict, prior) end)
    end

    test "returns {:error, _} and logs a warning for an undeclared prop — does not raise" do
      log =
        capture_log(fn ->
          assert {:error, _reason} =
                   Contract.validate!("onboarding_step_completed", %{user_id: 99})
        end)

      assert log =~ "analytics event dropped"
      assert log =~ "onboarding_step_completed"
      # Prop values must not appear in the log — only the key name
      refute log =~ "99"
    end

    test "returns {:error, _} for an unknown event — does not raise" do
      log =
        capture_log(fn ->
          assert {:error, _reason} = Contract.validate!("unknown_event", %{})
        end)

      assert log =~ "analytics event dropped"
    end

    test "returns :ok for a valid event — no warning logged" do
      log =
        capture_log(fn ->
          assert :ok = Contract.validate!("onboarding_step_completed", %{step: "profile"})
        end)

      refute log =~ "analytics event dropped"
    end
  end
end
