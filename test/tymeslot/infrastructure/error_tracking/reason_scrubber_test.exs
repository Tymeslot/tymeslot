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

  describe "scrub_exception/2" do
    test "renders an exit payload as ErrorTracker would, with its sensitive values masked" do
      payload = {:timeout, %{"access_token" => "tok-secret-123", "owner" => "jane@example.com"}}

      assert {:exit, text} = ReasonScrubber.scrub_exception({:exit, payload}, [])
      assert text =~ "timeout"
      refute text =~ "tok-secret-123"
      refute text =~ "jane@example.com"
      assert text =~ "j***@example.com"
    end

    test "leaves a payload with nothing to mask rendered exactly as ErrorTracker renders it" do
      assert ReasonScrubber.scrub_exception({:throw, {:halt, 3}}, []) == {:throw, "{:halt, 3}"}
      assert ReasonScrubber.scrub_exception({:exit, "plain"}, []) == {:exit, "plain"}
    end

    test "turns an error payload into the exception ErrorTracker would record, scrubbed" do
      assert %ErlangError{} = exception = ReasonScrubber.scrub_exception({:error, :oops}, [])
      assert Exception.message(exception) == "Erlang error: :oops"

      assert %RuntimeError{message: "failed for j***@example.com"} =
               ReasonScrubber.scrub_exception(
                 %RuntimeError{message: "failed for jane@example.com"},
                 []
               )
    end
  end

  describe "rescrub_since/2" do
    defp insert_error(reason, last_seen) do
      Repo.insert!(%Error{
        kind: "Elixir.RuntimeError",
        reason: reason,
        source_line: "lib/example.ex:#{System.unique_integer([:positive])}",
        source_function: "Example.run/0",
        fingerprint: Base.encode16(:crypto.strong_rand_bytes(16)),
        status: :unresolved,
        last_occurrence_at: last_seen
      })
    end

    # Inserted directly, so the telemetry handler never sees them: the state
    # a failed rewrite leaves behind.
    defp insert_occurrence(error, reason, inserted_at) do
      Repo.insert!(%Occurrence{
        error_id: error.id,
        reason: reason,
        context: %{},
        breadcrumbs: [],
        stacktrace: %ErrorTracker.Stacktrace{lines: []},
        inserted_at: inserted_at
      })
    end

    defp hours_ago(hours), do: DateTime.add(DateTime.utc_now(), -hours, :hour)

    defp stored_reason(schema, id), do: Repo.get!(schema, id).reason

    test "masks the unmasked reasons of recent errors and occurrences, across pages" do
      recent = insert_error(@raw, hours_ago(1))
      inside = for hours <- 1..5, do: insert_occurrence(recent, @raw, hours_ago(hours))
      clean = insert_occurrence(recent, "plain failure", hours_ago(1))
      outside = insert_occurrence(recent, @raw, hours_ago(72))

      quiet = insert_error(@raw, hours_ago(72))
      quiet_occurrence = insert_occurrence(quiet, @raw, hours_ago(72))

      # A page of 2 makes both walks turn several pages.
      assert ReasonScrubber.rescrub_since(hours_ago(48), batch_size: 2) == 6

      masked = ReasonScrubber.scrub(@raw)
      assert stored_reason(Error, recent.id) == masked
      assert Enum.reject(inside, &(stored_reason(Occurrence, &1.id) == masked)) == []
      assert stored_reason(Occurrence, clean.id) == "plain failure"
      assert stored_reason(Occurrence, outside.id) == @raw
      assert stored_reason(Error, quiet.id) == @raw
      assert stored_reason(Occurrence, quiet_occurrence.id) == @raw
    end

    test "writes nothing when every reason is already masked" do
      error = insert_error("plain failure", hours_ago(1))
      insert_occurrence(error, ReasonScrubber.scrub(@raw), hours_ago(1))

      assert ReasonScrubber.rescrub_since(hours_ago(48)) == 0
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
