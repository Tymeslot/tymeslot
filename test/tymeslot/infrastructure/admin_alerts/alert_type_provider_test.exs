defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypeProviderTest do
  # A deployment's own alert types reach `AlertTypes` through the providers
  # configured under `:admin_alert_type_providers`.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes
  alias Tymeslot.Workers.EmailWorker

  defmodule OverlayAlerts do
    @behaviour Tymeslot.Infrastructure.AdminAlerts.AlertTypeProvider

    alias Tymeslot.Infrastructure.AdminAlerts.AlertTypeProvider
    alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

    @impl AlertTypeProvider
    def registered_types, do: %{overlay_stalled: %{category: "Overlay", severity: :error}}

    # Only its own type: a Core type routed here raises FunctionClauseError.
    @impl AlertTypeProvider
    def format_message(:overlay_stalled, metadata) do
      "Overlay #{Map.get(metadata, :overlay_id)} stalled (#{AlertTypes.reason_text(metadata)})"
    end

    @impl AlertTypeProvider
    def dedup_key(:overlay_stalled, metadata), do: "overlay_stalled:#{metadata.overlay_id}"
  end

  defmodule ClashingAlerts do
    @behaviour Tymeslot.Infrastructure.AdminAlerts.AlertTypeProvider

    alias Tymeslot.Infrastructure.AdminAlerts.AlertTypeProvider

    @impl AlertTypeProvider
    def registered_types, do: %{dispute_created: %{category: "Overlay", severity: :info}}

    @impl AlertTypeProvider
    def format_message(type, _metadata), do: "clash #{type}"

    @impl AlertTypeProvider
    def dedup_key(type, _metadata), do: "clash #{type}"
  end

  defmodule DuplicateOverlayAlerts do
    @behaviour Tymeslot.Infrastructure.AdminAlerts.AlertTypeProvider

    alias Tymeslot.Infrastructure.AdminAlerts.AlertTypeProvider

    @impl AlertTypeProvider
    def registered_types, do: %{overlay_stalled: %{category: "Other", severity: :info}}

    @impl AlertTypeProvider
    def format_message(type, _metadata), do: "duplicate #{type}"

    @impl AlertTypeProvider
    def dedup_key(type, _metadata), do: "duplicate #{type}"
  end

  setup do
    setup_config(:tymeslot, admin_alert_type_providers: [OverlayAlerts])
  end

  describe "a configured provider's type" do
    test "is registered with the provider's category and severity" do
      assert AlertTypes.get(:overlay_stalled) == %{category: "Overlay", severity: :error}
      assert Map.has_key?(AlertTypes.registered_types(), :overlay_stalled)
      assert Map.has_key?(AlertTypes.registered_types(), :dispute_created)
    end

    test "is formatted and keyed by the provider" do
      metadata = %{overlay_id: 7, reason_message: "timeout"}

      assert AlertTypes.format_message(:overlay_stalled, metadata) ==
               "Overlay 7 stalled (timeout)"

      assert AlertTypes.dedup_key(:overlay_stalled, metadata) == "overlay_stalled:7"
    end

    test "is unknown once the provider is no longer configured" do
      with_config(:tymeslot, admin_alert_type_providers: [])

      assert AlertTypes.get(:overlay_stalled) == nil
      assert AlertTypes.format_message(:overlay_stalled, %{}) == "Alert: overlay_stalled"
    end
  end

  test "Core's own types are not routed to a provider" do
    assert AlertTypes.format_message(:dispute_lost, %{dispute_id: "dp_1", user_id: 3}) =~
             "Dispute lost: dp_1 for user 3"

    assert AlertTypes.dedup_key(:new_error, %{error_id: 42}) == "new_error:42"
  end

  describe "sending a provider's alert" do
    setup do
      setup_config(:tymeslot,
        admin_alerts_impl: Tymeslot.Infrastructure.AdminAlerts.EmailNotifier,
        admin_alerts_enabled: true,
        admin_alert_email: "ops@example.com"
      )
    end

    test "emails it with the provider's category, severity and message" do
      assert :ok = AdminAlerts.send_alert(:overlay_stalled, %{overlay_id: 7, reason_code: :down})

      assert [job] = all_enqueued(worker: EmailWorker)
      assert job.args["category"] == "Overlay"
      assert job.args["severity"] == "error"
      assert job.args["message"] == "Overlay 7 stalled (down)"
    end

    test "deduplicates on the provider's key, not the message" do
      assert :ok = AdminAlerts.send_alert(:overlay_stalled, %{overlay_id: 7, reason_code: :down})
      assert :ok = AdminAlerts.send_alert(:overlay_stalled, %{overlay_id: 7, reason_code: :slow})
      assert :ok = AdminAlerts.send_alert(:overlay_stalled, %{overlay_id: 8, reason_code: :down})

      messages = [worker: EmailWorker] |> all_enqueued() |> Enum.map(& &1.args["message"])

      assert Enum.sort(messages) == ["Overlay 7 stalled (down)", "Overlay 8 stalled (down)"]
    end
  end

  describe "validate_providers!/0" do
    test "accepts providers whose types are all new" do
      assert AlertTypes.validate_providers!() == :ok
    end

    test "refuses a provider that redefines one of Core's types" do
      with_config(:tymeslot, admin_alert_type_providers: [OverlayAlerts, ClashingAlerts])

      assert_raise ArgumentError, ~r/ClashingAlerts registers \[:dispute_created\]/, fn ->
        AlertTypes.validate_providers!()
      end
    end

    test "refuses a provider that redefines an earlier provider's type" do
      with_config(:tymeslot, admin_alert_type_providers: [OverlayAlerts, DuplicateOverlayAlerts])

      assert_raise ArgumentError, ~r/DuplicateOverlayAlerts registers \[:overlay_stalled\]/, fn ->
        AlertTypes.validate_providers!()
      end
    end

    test "refuses a module that does not implement the behaviour" do
      with_config(:tymeslot, admin_alert_type_providers: [String])

      assert_raise ArgumentError, ~r/String does not implement/, fn ->
        AlertTypes.validate_providers!()
      end
    end
  end
end
