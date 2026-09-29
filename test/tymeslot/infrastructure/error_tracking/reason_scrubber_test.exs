defmodule Tymeslot.Infrastructure.ErrorTracking.ReasonScrubberTest do
  # async: false: ErrorTracker's `enabled` switch is global application env,
  # and the scrubber is a global telemetry handler.
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias Tymeslot.Infrastructure.ErrorTracking.ReasonScrubber

  @raw "sync failed for jane.doe@example.com with token=s3cr3tT0ken"

  setup do
    with_config(:error_tracker, enabled: true)
    :ok
  end

  defp raise_and_capture(message) do
    raise message
  rescue
    exception -> {exception, __STACKTRACE__}
  end

  # One call site, so both reports are occurrences of one error.
  defp report(message) do
    {exception, stacktrace} = raise_and_capture(message)
    ErrorTracker.report(exception, stacktrace, %{})
  end

  describe "an exception whose message holds an email and a token" do
    test "is stored with both masked, on the error and on the occurrence" do
      report(@raw)

      assert [%Error{reason: error_reason}] = Repo.all(Error)
      assert [%Occurrence{reason: occurrence_reason}] = Repo.all(Occurrence)

      for reason <- [error_reason, occurrence_reason] do
        refute reason =~ "jane.doe@example.com"
        refute reason =~ "s3cr3tT0ken"
        assert reason =~ "j***@example.com"
        assert reason =~ "token=[REDACTED]"
      end
    end

    test "is masked on every later occurrence too" do
      for _occurrence <- 1..2, do: report(@raw)

      assert [%Error{}] = Repo.all(Error)
      occurrence_reasons = Occurrence |> Repo.all() |> Enum.map(& &1.reason)
      assert length(occurrence_reasons) == 2
      assert Enum.reject(occurrence_reasons, &(&1 =~ "token=[REDACTED]")) == []
    end
  end

  test "a message with nothing to mask is stored as it was" do
    report("plain failure")

    assert [%Error{reason: "plain failure"}] = Repo.all(Error)
    assert [%Occurrence{reason: "plain failure"}] = Repo.all(Occurrence)
  end

  describe "scrub/1" do
    test "masks emails and credentials in text" do
      assert ReasonScrubber.scrub(@raw) ==
               "sync failed for j***@example.com with token=[REDACTED]"
    end
  end

  describe "handle_event/4" do
    test "never raises on metadata it does not recognise" do
      assert ReasonScrubber.handle_event([:error_tracker, :occurrence, :new], %{}, %{}, nil) ==
               :ok

      assert ReasonScrubber.handle_event(
               [:error_tracker, :occurrence, :new],
               %{},
               %{occurrence: :not_an_occurrence, error: nil},
               nil
             ) == :ok
    end
  end
end
