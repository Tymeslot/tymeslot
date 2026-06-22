defmodule Tymeslot.Analytics.ReconciliationTest do
  use Tymeslot.DataCase, async: false

  @moduletag :analytics
  @moduletag :database

  import Tymeslot.Factory
  import Tymeslot.AdminAlertsCaptureHelpers

  alias Tymeslot.Analytics.EventQueries
  alias Tymeslot.Analytics.Reconciliation

  setup :capture_admin_alerts

  describe "detect_anomalies/1" do
    test "returns no anomalies for healthy totals" do
      totals = %{
        visits: 100,
        unique_visitors: 80,
        converting_visitors: 20,
        untracked_converting_visitors: 1
      }

      assert [] = Reconciliation.detect_anomalies(totals)
    end

    test "flags unique visitors exceeding total visits as an integrity error" do
      totals = %{
        visits: 5,
        unique_visitors: 6,
        converting_visitors: 0,
        untracked_converting_visitors: 0
      }

      assert [%{kind: :unique_exceeds_visits, severity: :error}] =
               Reconciliation.detect_anomalies(totals)
    end

    test "flags converting visitors exceeding unique visitors" do
      totals = %{
        visits: 10,
        unique_visitors: 3,
        converting_visitors: 5,
        untracked_converting_visitors: 0
      }

      kinds = totals |> Reconciliation.detect_anomalies() |> Enum.map(& &1.kind)
      assert :converting_exceeds_unique in kinds
    end

    test "flags a high untracked ratio once the sample is large enough" do
      totals = %{
        visits: 100,
        unique_visitors: 100,
        converting_visitors: 20,
        untracked_converting_visitors: 15
      }

      assert [%{kind: :high_untracked_ratio}] = Reconciliation.detect_anomalies(totals)
    end

    test "ignores a high untracked ratio on a small sample" do
      totals = %{
        visits: 100,
        unique_visitors: 100,
        converting_visitors: 3,
        untracked_converting_visitors: 3
      }

      assert [] = Reconciliation.detect_anomalies(totals)
    end
  end

  describe "run/0" do
    test "is a no-op when booking analytics is disabled" do
      Application.put_env(:tymeslot, :booking_analytics_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :booking_analytics_enabled, true) end)

      assert {:ok, :disabled} = Reconciliation.run()
      refute_receive {:send_alert, :analytics_tracking_anomaly, _payload}
    end

    test "logs and raises an admin alert when bookings outnumber tracked visitors" do
      # One distinct viewer, two distinct bookers → converting (2) > unique (1).
      {:ok, _event} =
        EventQueries.insert(%{
          event_type: "booking_page_view",
          path: "/alice/intro",
          visitor_hash: "v1"
        })

      user = insert(:user)
      base = DateTime.truncate(DateTime.utc_now(), :second)

      for {hash, i} <- Enum.with_index(["v1", "v2"], 1) do
        insert(:meeting,
          organizer_user_id: user.id,
          start_time: DateTime.add(base, i * 60, :minute),
          end_time: DateTime.add(base, i * 60 + 30, :minute),
          visitor_hash: hash
        )
      end

      assert {:ok, %{anomalies: anomalies}} = Reconciliation.run()
      assert Enum.any?(anomalies, &(&1.kind == :converting_exceeds_unique))

      assert_receive {:send_alert, :analytics_tracking_anomaly, payload}
      assert payload.kind == :converting_exceeds_unique
    end
  end
end
