defmodule Tymeslot.Integrations.Calendar.Outlook.SyncCycleTest do
  @moduledoc """
  One Outlook refresh, run without Oban: which read it takes, and the
  outcome it hands its caller. Flagging for reconnection and the retry
  ladder are the worker's, so none of it happens here.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.SyncCycle
  alias Tymeslot.Security.Encryption

  # DeltaSync reaches the HTTP client through a process boundary.
  setup :set_mox_global
  setup :verify_on_exit!

  @old_link "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=old"

  defp integration(attrs) do
    inserted =
      insert(
        :calendar_integration,
        Keyword.merge(
          [
            provider: "outlook",
            is_active: true,
            needs_reauth: false,
            access_token_encrypted: Encryption.encrypt("test-access-token"),
            refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
            token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
            last_full_sync_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)
          ],
          attrs
        )
      )

    {:ok, loaded} = CalendarIntegrationQueries.get(inserted.id)
    loaded
  end

  defp expect_delta_answer(status, body) do
    expect(Tymeslot.HTTPClientMock, :request, fn :get, url, _body, _headers, _opts ->
      assert url =~ "$deltatoken=old"
      {:ok, %{status: status, body: body}}
    end)
  end

  defp fresh_delta_page do
    Jason.encode!(%{
      "value" => [],
      "@odata.deltaLink" =>
        "https://graph.microsoft.com/v1.0/me/calendarView/delta?$deltatoken=fresh"
    })
  end

  describe "without a delta link" do
    setup do
      %{integration: integration(graph_delta_link: nil)}
    end

    test "bootstraps and registers a subscription", %{integration: integration} do
      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn received ->
        {:ok, %{received | graph_delta_link: "fresh"}}
      end)

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _updated -> :ok end)

      assert :ok = SyncCycle.run(integration)
    end

    test "a refused credential is :unauthorized, with nothing flagged", %{
      integration: integration
    } do
      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :unauthorized, "401"}
      end)

      assert {:error, :unauthorized} = SyncCycle.run(integration)
      assert {:ok, %{needs_reauth: false}} = CalendarIntegrationQueries.get(integration.id)
    end

    test "a passing remote failure is a transient bootstrap failure", %{
      integration: integration
    } do
      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn _integration -> {:error, :timeout} end)

      assert {:error, {:bootstrap_failed, :transient}} = SyncCycle.run(integration)
    end

    test "a failure no retry can help is a hard bootstrap failure", %{integration: integration} do
      expect(OutlookCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:error, :token_expired}
      end)

      assert {:error, {:bootstrap_failed, :hard}} = SyncCycle.run(integration)
    end
  end

  test "a failed delta read keeps its stage" do
    integration = integration(graph_delta_link: @old_link)
    expect_delta_answer(500, "boom")

    assert {:error, {:delta_sync_failed, _class}} = SyncCycle.run(integration)
  end

  test "a re-bootstrap that fails after the old link was followed keeps that result" do
    integration = integration(graph_delta_link: @old_link, last_full_sync_at: nil)
    expect_delta_answer(200, fresh_delta_page())

    expect(OutlookCalendarAPIMock, :bootstrap_sync, fn _integration -> {:error, :timeout} end)

    assert :ok = SyncCycle.run(integration)

    {:ok, reloaded} = CalendarIntegrationQueries.get(integration.id)
    assert reloaded.graph_delta_link =~ "$deltatoken=fresh"
  end
end
