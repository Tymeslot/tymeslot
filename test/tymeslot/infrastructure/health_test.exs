defmodule Tymeslot.Infrastructure.HealthTest do
  # async: false: the degraded and unhealthy tests replace `Oban` and
  # `HealthQueries` globally with :meck.
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.{Health, HealthQueries}

  defp with_mock(module, fun, impl, body) do
    :meck.new(module, [:passthrough])
    :meck.expect(module, fun, impl)

    try do
      body.()
    after
      :meck.unload(module)
    end
  end

  describe "check/0" do
    test "is :ok when the database answers and no queue is paused" do
      assert Health.check() == %{status: :ok, checks: %{database: :ok, oban: :ok}}
    end

    test "is :degraded, not :unhealthy, when an Oban queue is paused" do
      report =
        with_mock(
          Oban,
          :check_all_queues,
          fn -> [%{queue: "default", paused: false}, %{queue: "mailers", paused: true}] end,
          &Health.check/0
        )

      assert report == %{status: :degraded, checks: %{database: :ok, oban: :paused}}
    end

    test "is :unhealthy when the database is unreachable" do
      report =
        with_mock(HealthQueries, :ping, fn -> {:error, :timeout} end, &Health.check/0)

      assert report == %{status: :unhealthy, checks: %{database: :unavailable, oban: :ok}}
    end

    test "is :unhealthy when the Oban probe raises" do
      {report, log} =
        with_log(fn ->
          with_mock(
            Oban,
            :check_all_queues,
            fn -> raise RuntimeError, "no oban instance" end,
            &Health.check/0
          )
        end)

      assert report == %{status: :unhealthy, checks: %{database: :ok, oban: :unavailable}}
      assert log =~ "Healthcheck Oban probe raised"
    end

    test "an unavailable check outranks a paused one" do
      report =
        with_mock(HealthQueries, :ping, fn -> {:error, :timeout} end, fn ->
          with_mock(
            Oban,
            :check_all_queues,
            fn -> [%{queue: "default", paused: true}] end,
            &Health.check/0
          )
        end)

      assert report == %{status: :unhealthy, checks: %{database: :unavailable, oban: :paused}}
    end
  end
end
